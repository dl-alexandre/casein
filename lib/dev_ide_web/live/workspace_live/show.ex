defmodule DevIdeWeb.WorkspaceLive.Show do
  use DevIdeWeb, :live_view

  alias DevIDE.Workspaces
  alias DevIDE.Terminals.Tmux
  alias DevIDE.Logs
  alias DevIDE.Files
  alias DevIDE.Git
  alias DevIDE.Commands
  alias DevIDE.Elixir, as: ElixirNav
  alias DevIDE.Search
  alias DevIDE.Palette
  alias DevIDE.Agents
  alias DevIDE.Export.WorkspaceStatus
  alias DevIDE.Proposals
  alias DevIDE.Policy
  alias DevIDE.Audit
  alias DevIDE.Runs.Ledger
  alias DevIDE.Runs.Status
  alias DevIdeWeb.Plugs.AssignCurrentUser
  alias DevIdeWeb.ChannelAuth

  @max_log_lines 500

  @impl true
  def mount(params, session, socket) do
    %{"id" => id} = params
    user = AssignCurrentUser.from_session(session)
    host_id = Map.get(params, "host", "local")

    # Host gate: the cockpit is host-aware (product.md §9.1, FP-4), but
    # cross-host workspace resolution is not yet wired through the
    # runtime. Refuse non-local hosts politely — §11 "hide rather than
    # mock". The picker only links to hosts whose workspaces are listed,
    # so this path is defensive against direct-URL navigation.
    with :ok <- ensure_local_host(host_id),
         {:ok, ws} <- Workspaces.get(id) do
      path_result = Workspaces.safe_host_path(ws)
      sid = "u-" <> user.id
      tmux_session = Tmux.session_name(ws.name || ws.id, sid)
      socket_token = ChannelAuth.sign_user_token(user.id)

      socket =
        socket
        |> assign(:page_title, ws.name)
        |> assign(:current_user, user)
        |> assign(:workspace, ws)
        |> assign(:host_id, host_id)
        |> assign(:host_path, path_result)
        |> assign(:tmux_session, tmux_session)
        |> assign(:terminal_sid, sid)
        |> assign(:terminal_mode, :governed)
        |> assign(:socket_token, socket_token)
        |> assign(:tab, "terminal")
        |> assign(:log_service, default_service(ws))
        |> assign(:log_lines, [])
        |> assign(:log_ref, nil)
        |> assign(:tree, %{})
        |> assign(:open_file, nil)
        |> assign(:file_error, nil)
        |> assign(:save_error, nil)
        |> assign(:git_status, [])
        |> assign(:file_diff, nil)
        |> assign(:active_run, nil)
        |> assign(:run_ledger, [])
        |> assign(:selected_run_id, nil)
        |> assign(:selected_run_summary, nil)
        |> assign(:selected_run_timeline, [])
        |> assign(:selected_run_artifacts, [])
        |> assign(:selected_run_failure_reason, nil)
        |> assign(:selected_run_can_retry, false)
        |> assign(:selected_dir, "")
        |> assign(:new_input, nil)
        |> assign(:delete_confirm, nil)
        |> assign(:rename_input, nil)
        |> assign(:tree_error, nil)
        |> assign(:agent_caps, [])
        |> assign(:agent_transcripts, [])
        |> assign(:agent_review_cmds, [])
        |> assign(:agent_run, nil)
        |> assign(:agent_run_error, nil)
        |> assign(:proposals, [])
        |> assign(:selected_proposal, nil)
        |> assign(:proposal_analysis, nil)
        |> assign_workspace_mode(ws.id)
        |> assign(:last_decision, nil)
        |> assign(:audit_events, [])
        |> assign(:audit_drawer_open, false)
        |> assign(:db_isolation, %DevIDE.Workspaces.DbIsolation{})
        |> assign(:project_meta, nil)
        |> assign(:tooling, nil)
        |> assign(:search_query, "")
        |> assign(:search_results, [])
        |> assign(:search_state, :idle)
        |> assign(:palette_open, false)
        |> assign(:palette_query, "")
        |> assign(:palette_items, [])
        |> load_tree("")
        |> refresh_git_status()
        |> attach_existing_run()
        |> refresh_run_ledger()
        |> load_agents()
        |> refresh_isolation(audit: true)
        |> load_project_meta()

      {:ok, socket}
    else
      {:error, :cross_host_not_configured} ->
        {:ok,
         socket
         |> put_flash(
           :error,
           "Cross-host attach is not yet configured. " <>
             "The cockpit is host-aware but the runtime resolver only honors \"local\" today."
         )
         |> push_navigate(to: ~p"/workspaces")}

      {:error, reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Manager error: #{inspect(reason)}")
         |> push_navigate(to: ~p"/workspaces")}
    end
  end

  # Until cross-host workspace resolution is wired (audit punch-list
  # item #4 follow-up), only the local runtime authority is reachable.
  # Refusing here keeps §11 honest: surfaces that cannot tell the truth
  # are hidden rather than mocked.
  defp ensure_local_host("local"), do: :ok
  defp ensure_local_host(""), do: :ok
  defp ensure_local_host(nil), do: :ok
  defp ensure_local_host(_), do: {:error, :cross_host_not_configured}

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    socket = assign(socket, :tab, tab)
    socket = if tab == "logs", do: start_log_stream(socket), else: socket

    socket =
      if tab == "run" do
        socket
        |> attach_existing_run()
        |> refresh_run_ledger()
      else
        socket
      end

    socket = if tab == "agents", do: load_agents(socket), else: socket
    {:noreply, socket}
  end

  def handle_event("terminal:set_mode", %{"mode" => "governed"}, socket) do
    {:noreply, assign(socket, :terminal_mode, :governed)}
  end

  def handle_event("terminal:set_mode", %{"mode" => "raw"}, socket) do
    if raw_terminal_allowed?(socket.assigns.workspace_mode, socket.assigns.host_id) do
      {:noreply, assign(socket, :terminal_mode, :raw)}
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "Raw shell requires manual workspace mode on the local host."
       )}
    end
  end

  def handle_event("agents:refresh", _, socket), do: {:noreply, load_agents(socket)}

  def handle_event("isolation:refresh", _, socket),
    do: {:noreply, refresh_isolation(socket, audit: true)}

  def handle_event("workspace:set_mode", %{"mode" => mode_str}, socket) do
    mode = string_to_mode(mode_str)
    ws_id = socket.assigns.workspace.id

    cond do
      not can_set_mode?(socket.assigns.workspace_mode_source) ->
        {:noreply,
         put_flash(socket, :error, "Mode is set via config override and cannot be changed in UI.")}

      mode == nil ->
        {:noreply, socket}

      true ->
        {_, _} = DevIDE.Workspaces.State.set_mode(ws_id, mode)

        DevIDE.Audit.emit!(%{
          action: "workspace.mode_changed",
          workspace_id: ws_id,
          actor_id: (socket.assigns[:current_user] || %{}) |> Map.get(:id),
          target_type: "workspace",
          target_ref: ws_id,
          metadata: %{"mode" => Atom.to_string(mode)}
        })

        {:noreply,
         socket
         |> assign_workspace_mode(ws_id)
         |> maybe_reset_terminal_mode()
         |> assign(:audit_events, refreshed_audit(socket))}
    end
  end

  def handle_event("proposal:select", %{"path" => path}, socket) do
    {_decision, socket} =
      gate(socket, fn -> Policy.can_view_proposal?(policy_ctx(socket)) end, %{
        action: "proposal.viewed",
        target_type: "proposal",
        target_ref: path
      })

    case host_path(socket) do
      {:ok, root} ->
        case Proposals.parse(root, path) do
          {:ok, p} ->
            analysis = DevIDE.Proposals.ConflictAnalyzer.analyze(root, p)

            Audit.emit!(%{
              action: "proposal.analyzed",
              workspace_id: socket.assigns.workspace.id,
              actor_id: (socket.assigns[:current_user] || %{}) |> Map.get(:id),
              target_type: "proposal",
              target_ref: path,
              metadata: %{
                "proposal_path" => path,
                "risk" => Atom.to_string(analysis.risk),
                "files_count" => analysis.files_count,
                "overlapping_files_count" => length(analysis.overlapping_files)
              }
            })

            {:noreply,
             socket
             |> assign(:selected_proposal, p)
             |> assign(:proposal_analysis, analysis)
             |> assign(:audit_events, refreshed_audit(socket))}

          _ ->
            {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("proposal:clear", _, socket),
    do: {:noreply, socket |> assign(:selected_proposal, nil) |> assign(:proposal_analysis, nil)}

  def handle_event("agent_run:start", %{"id" => id}, socket) do
    caps = socket.assigns.agent_caps

    {decision, socket} =
      gate(
        socket,
        fn ->
          Policy.can_start_review_agent?(policy_ctx(socket, %{agent_run_id: id, caps: caps}))
        end,
        %{action: "agent.review_started", target_type: "agent_run", target_ref: id}
      )

    with true <- DevIDE.Policy.Decision.allow?(decision),
         {:ok, root} <- host_path(socket),
         {:ok, pid} <-
           DevIDE.Agents.Run.start(socket.assigns.workspace.id, root, id, caps),
         {:ok, snap} <- DevIDE.Agents.Run.subscribe(pid) do
      {:noreply, socket |> assign(:agent_run, snap) |> assign(:agent_run_error, nil)}
    else
      {:error, :already_running} ->
        {:noreply, attach_existing_agent_run(socket)}

      {:error, reason} ->
        {:noreply, assign(socket, :agent_run_error, "Run failed: #{inspect(reason)}")}

      _ ->
        {:noreply, assign(socket, :agent_run_error, "Run not allowed.")}
    end
  end

  def handle_event("agent_run:cancel", _, socket) do
    case DevIDE.Agents.Run.whereis(socket.assigns.workspace.id) do
      {:ok, pid} -> DevIDE.Agents.Run.cancel(pid)
      _ -> :ok
    end

    {:noreply, socket}
  end

  def handle_event("run:start", %{"id" => id}, socket) do
    decision = Policy.can_run_command?(policy_ctx(socket, %{command_id: id}))
    run_id = Ledger.new_run_id()
    _ = ledger_command_decision(decision, socket, id, run_id)

    socket =
      assign(socket,
        last_decision: decision,
        audit_events: refreshed_audit(socket)
      )
      |> refresh_run_ledger(run_id)

    with true <- DevIDE.Policy.Decision.allow?(decision),
         {:ok, root} <- host_path(socket),
         {:ok, pid} <-
           Commands.Run.start(socket.assigns.workspace.id, root, id,
             run_id: run_id,
             actor_id: current_actor_id(socket),
             metadata: %{
               source: "ui",
               trigger: "manual"
             }
           ),
         {:ok, snap} <- Commands.Run.subscribe(pid) do
      {:noreply, assign(socket, :active_run, snap)}
    else
      {:error, :already_running} ->
        {:noreply, attach_existing_run(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Run failed: #{inspect(reason)}")}

      _ ->
        {:noreply, put_flash(socket, :error, "Run not allowed.")}
    end
  end

  def handle_event("run_ledger:select", %{"id" => id}, socket) do
    {:noreply, refresh_run_ledger(socket, id)}
  end

  def handle_event("run_ledger:open", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:tab, "run")
     |> assign(:audit_drawer_open, false)
     |> attach_existing_run()
     |> refresh_run_ledger(id)}
  end

  def handle_event("palette:open", _, socket) do
    items = palette_query(socket, "")

    {:noreply,
     socket
     |> assign(:palette_open, true)
     |> assign(:palette_query, "")
     |> assign(:palette_items, items)}
  end

  # Evidence drawer — single time-ordered audit stream per product.md §9.4.
  # Defaults closed; refresh fetches the latest from the audit adapter on open.
  def handle_event("audit_drawer:toggle", _, socket) do
    open? = not socket.assigns.audit_drawer_open

    socket =
      socket
      |> assign(:audit_drawer_open, open?)
      |> then(fn s -> if open?, do: assign(s, :audit_events, refreshed_audit(s)), else: s end)

    {:noreply, socket}
  end

  def handle_event("audit_drawer:close", _, socket),
    do: {:noreply, assign(socket, :audit_drawer_open, false)}

  def handle_event("audit_drawer:refresh", _, socket),
    do: {:noreply, assign(socket, :audit_events, refreshed_audit(socket))}

  def handle_event("palette:close", _, socket) do
    {:noreply, assign(socket, :palette_open, false)}
  end

  def handle_event("palette:query", %{"query" => q}, socket) do
    {:noreply,
     socket
     |> assign(:palette_query, q)
     |> assign(:palette_items, palette_query(socket, q))}
  end

  def handle_event("palette:execute", %{"_top_id" => id}, socket),
    do: handle_event("palette:execute", %{"id" => id}, socket)

  def handle_event("palette:execute", %{"id" => id}, socket) do
    root =
      case host_path(socket) do
        {:ok, r} -> r
        _ -> nil
      end

    case Palette.resolve(root, id) do
      {:ok, %{event: event, params: params}} ->
        socket = assign(socket, :palette_open, false)
        __MODULE__.handle_event(event, params, socket)

      :error ->
        {:noreply, assign(socket, :palette_open, false)}
    end
  end

  def handle_event("search:run", %{"query" => query}, socket) do
    case host_path(socket) do
      {:ok, root} ->
        case Search.search(root, String.trim(query)) do
          {:ok, results} ->
            state = if results == [], do: :empty, else: :ok

            {:noreply,
             socket
             |> assign(:search_query, query)
             |> assign(:search_results, results)
             |> assign(:search_state, state)}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:search_query, query)
             |> assign(:search_results, [])
             |> assign(:search_state, {:error, reason})}
        end

      _ ->
        {:noreply, assign(socket, :search_state, {:error, :no_root})}
    end
  end

  def handle_event("annotation:open", %{"path" => path} = params, socket) do
    line = parse_line(params["line"])

    case host_path(socket) do
      {:ok, root} ->
        case Files.read_text(root, path) do
          {:ok, file} ->
            payload = %{path: file.path, content: file.content, version: file.version}
            payload = if line, do: Map.put(payload, :line, line), else: payload

            {:noreply,
             socket
             |> assign(:tab, "files")
             |> assign(:open_file, file)
             |> assign(:file_error, nil)
             |> assign(:save_error, nil)
             |> load_diff(file.path)
             |> push_event("file:loaded", payload)}

          {:error, reason} ->
            {:noreply, assign(socket, :file_error, format_file_error(reason))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("run:cancel", _, socket) do
    case Commands.Run.whereis(socket.assigns.workspace.id) do
      {:ok, pid} -> Commands.Run.cancel(pid)
      _ -> :ok
    end

    {:noreply, socket}
  end

  def handle_event("set_log_service", %{"service" => service}, socket) do
    socket = socket |> assign(:log_service, service) |> assign(:log_lines, [])
    {:noreply, start_log_stream(socket)}
  end

  def handle_event("tree:toggle", %{"path" => path}, socket) do
    case Map.get(socket.assigns.tree, path) do
      {:expanded, _} ->
        {:noreply, update(socket, :tree, &Map.put(&1, path, {:collapsed, []}))}

      _ ->
        {:noreply, load_tree(socket, path)}
    end
  end

  def handle_event("tree:select_dir", %{"path" => path}, socket) do
    {:noreply, assign(socket, :selected_dir, path)}
  end

  def handle_event("tree:new_form", %{"kind" => kind}, socket) when kind in ["file", "dir"] do
    {:noreply,
     assign(socket, :new_input, {String.to_existing_atom(kind), socket.assigns.selected_dir})}
  end

  def handle_event("tree:cancel_new", _, socket), do: {:noreply, assign(socket, :new_input, nil)}

  def handle_event("tree:create", %{"name" => name}, socket) do
    {decision, socket} =
      gate(socket, fn -> Policy.can_edit_file?(policy_ctx(socket)) end, %{
        action: "file.create",
        target_type: "tree_node",
        target_ref: String.trim(name)
      })

    with true <- DevIDE.Policy.Decision.allow?(decision),
         {kind, dir} when kind in [:file, :dir] <- socket.assigns.new_input,
         {:ok, root} <- host_path(socket),
         rel = Path.join(dir, String.trim(name)),
         :ok <- do_create(kind, root, rel) do
      {:noreply,
       socket
       |> assign(:new_input, nil)
       |> assign(:tree_error, nil)
       |> refresh_tree()
       |> refresh_git_status()}
    else
      {:error, reason} ->
        {:noreply, assign(socket, :tree_error, "Create failed: #{inspect(reason)}")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("tree:refresh", _, socket) do
    {:noreply, socket |> refresh_tree() |> refresh_git_status()}
  end

  def handle_event("file:rename_form", _, socket) do
    case socket.assigns.open_file do
      %{path: path} -> {:noreply, assign(socket, :rename_input, path)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("file:rename_cancel", _, socket),
    do: {:noreply, assign(socket, :rename_input, nil)}

  def handle_event("file:rename_submit", %{"new_path" => new_path}, socket) do
    new_path = String.trim(new_path)

    {decision, socket} =
      gate(socket, fn -> Policy.can_edit_file?(policy_ctx(socket)) end, %{
        action: "file.renamed",
        target_type: "file",
        target_ref: new_path
      })

    with true <- DevIDE.Policy.Decision.allow?(decision),
         {:ok, root} <- host_path(socket),
         %{path: from} = _open <- socket.assigns.open_file,
         :ok <- Files.rename(root, from, new_path) do
      case Files.read_text(root, new_path) do
        {:ok, file} ->
          {:noreply,
           socket
           |> assign(:open_file, file)
           |> assign(:rename_input, nil)
           |> refresh_tree()
           |> refresh_git_status()
           |> push_event("file:loaded", %{
             path: file.path,
             content: file.content,
             version: file.version
           })}

        _ ->
          {:noreply,
           socket
           |> assign(:open_file, nil)
           |> assign(:rename_input, nil)
           |> refresh_tree()
           |> push_event("file:cleared", %{})}
      end
    else
      {:error, reason} ->
        {:noreply, assign(socket, :save_error, format_file_error(reason))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("file:delete_request", _, socket) do
    case socket.assigns.open_file do
      %{path: path} -> {:noreply, assign(socket, :delete_confirm, path)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("file:delete_cancel", _, socket),
    do: {:noreply, assign(socket, :delete_confirm, nil)}

  def handle_event("file:delete_confirm", _, socket) do
    {decision, socket} =
      gate(socket, fn -> Policy.can_edit_file?(policy_ctx(socket)) end, %{
        action: "file.deleted",
        target_type: "file",
        target_ref: socket.assigns.delete_confirm
      })

    with true <- DevIDE.Policy.Decision.allow?(decision),
         rel when is_binary(rel) <- socket.assigns.delete_confirm,
         {:ok, root} <- host_path(socket),
         :ok <- Files.delete(root, rel) do
      {:noreply,
       socket
       |> assign(:open_file, nil)
       |> assign(:delete_confirm, nil)
       |> assign(:file_diff, nil)
       |> refresh_tree()
       |> refresh_git_status()
       |> push_event("file:cleared", %{})}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:save_error, "Delete failed: #{inspect(reason)}")
         |> assign(:delete_confirm, nil)}

      _ ->
        {:noreply, assign(socket, :delete_confirm, nil)}
    end
  end

  def handle_event("file:refresh", _, socket) do
    case {socket.assigns.open_file, host_path(socket)} do
      {%{path: path}, {:ok, root}} ->
        case Files.read_text(root, path) do
          {:ok, file} ->
            {:noreply,
             socket
             |> assign(:open_file, file)
             |> push_event("file:loaded", %{
               path: file.path,
               content: file.content,
               version: file.version
             })}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:open_file, nil)
             |> assign(:file_error, format_file_error(reason))
             |> push_event("file:cleared", %{})}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("tree:open", %{"path" => path}, socket) do
    case host_path(socket) do
      {:ok, root} ->
        case Files.read_text(root, path) do
          {:ok, file} ->
            {:noreply,
             socket
             |> assign(:open_file, file)
             |> assign(:file_error, nil)
             |> assign(:save_error, nil)
             |> load_diff(file.path)
             |> push_event("file:loaded", %{
               path: file.path,
               content: file.content,
               version: file.version
             })}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:open_file, nil)
             |> assign(:file_error, format_file_error(reason))
             |> assign(:file_diff, nil)
             |> push_event("file:cleared", %{})}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "file:save",
        %{"path" => path, "content" => content, "version" => version},
        socket
      ) do
    {decision, socket} =
      gate(socket, fn -> Policy.can_edit_file?(policy_ctx(socket)) end, %{
        action: "file.save",
        target_type: "file",
        target_ref: path
      })

    with true <- DevIDE.Policy.Decision.allow?(decision),
         {:ok, root} <- host_path(socket),
         %{path: ^path, version: ^version} = open <- socket.assigns.open_file,
         {:ok, %{version: new_version}} <- Files.write_text(root, path, content, open.version) do
      updated = %{open | content: content, size: byte_size(content), version: new_version}

      {:noreply,
       socket
       |> assign(:open_file, updated)
       |> assign(:save_error, nil)
       |> refresh_git_status()
       |> load_diff(path)
       |> push_event("save:ok", %{version: new_version})}
    else
      {:error, :conflict} ->
        {:noreply,
         assign(socket, :save_error, "Conflict: file changed on disk. Reopen to reload.")}

      {:error, reason} ->
        {:noreply, assign(socket, :save_error, format_file_error(reason))}

      _ ->
        {:noreply, assign(socket, :save_error, "Save aborted: open file changed.")}
    end
  end

  @impl true
  def handle_info({:devbox_log, ref, line}, %{assigns: %{log_ref: ref}} = socket) do
    lines = [line | socket.assigns.log_lines] |> Enum.take(@max_log_lines)
    {:noreply, assign(socket, :log_lines, lines)}
  end

  def handle_info({:devbox_log, _ref, _line}, socket), do: {:noreply, socket}
  def handle_info({:devbox_log_done, _ref}, socket), do: {:noreply, socket}

  def handle_info(
        {:run_data, ws_id, _stream, bin},
        %{assigns: %{workspace: %{id: ws_id}, active_run: %{} = run}} = socket
      ) do
    updated = Map.update!(run, :buffer, fn b -> cap_buffer(b <> bin) end)
    {:noreply, assign(socket, :active_run, updated)}
  end

  def handle_info(
        {:run_exit, ws_id, code, status},
        %{assigns: %{workspace: %{id: ws_id}, active_run: %{} = run}} = socket
      ) do
    updated = %{run | exit_code: code, status: status, finished_at: DateTime.utc_now()}

    {:noreply,
     socket
     |> assign(:active_run, updated)
     |> refresh_run_ledger(run.run_id)}
  end

  def handle_info({:run_data, _, _, _}, socket), do: {:noreply, socket}
  def handle_info({:run_exit, _, _, _}, socket), do: {:noreply, socket}

  def handle_info(
        {:agent_run_data, ws_id, _stream, bin},
        %{assigns: %{workspace: %{id: ws_id}, agent_run: %{} = run}} = socket
      ) do
    updated = Map.update!(run, :buffer, fn b -> cap_buffer(b <> bin) end)
    {:noreply, assign(socket, :agent_run, updated)}
  end

  def handle_info(
        {:agent_run_exit, ws_id, code, status},
        %{assigns: %{workspace: %{id: ws_id}, agent_run: %{} = run}} = socket
      ) do
    updated = %{run | exit_code: code, status: status, finished_at: DateTime.utc_now()}
    {:noreply, socket |> assign(:agent_run, updated) |> load_agents()}
  end

  def handle_info({:agent_run_data, _, _, _}, socket), do: {:noreply, socket}
  def handle_info({:agent_run_exit, _, _, _}, socket), do: {:noreply, socket}

  ## Helpers

  defp host_path(%{assigns: %{host_path: {:ok, root}}}), do: {:ok, root}
  defp host_path(_), do: :error

  defp assign_workspace_mode(socket, ws_id) do
    {mode, source} = DevIDE.Workspaces.State.mode_for(ws_id)

    socket
    |> assign(:workspace_mode, mode)
    |> assign(:workspace_mode_source, source)
    |> assign(:workspace_record, load_record(ws_id))
  end

  defp load_record(ws_id) do
    case DevIDE.Workspaces.State.get(ws_id) do
      {:ok, r} -> r
      _ -> nil
    end
  end

  defp policy_ctx(socket, extra \\ %{}) do
    base = %{
      workspace_id: socket.assigns.workspace.id,
      actor_id: (socket.assigns[:current_user] || %{}) |> Map.get(:id),
      db_isolation: (socket.assigns[:db_isolation] || %{}) |> Map.get(:isolation)
    }

    Map.merge(base, extra)
  end

  defp refresh_isolation(socket, opts) do
    iso =
      case host_path(socket) do
        {:ok, root} -> DevIDE.Workspaces.Isolation.detect(socket.assigns.workspace, root)
        _ -> %DevIDE.Workspaces.DbIsolation{detected_at: DateTime.utc_now()}
      end

    _ = DevIDE.Workspaces.State.persist_isolation(socket.assigns.workspace.id, iso)

    if Keyword.get(opts, :audit, false) do
      DevIDE.Audit.emit!(%{
        action: "workspace.db_isolation_detected",
        workspace_id: socket.assigns.workspace.id,
        actor_id: (socket.assigns[:current_user] || %{}) |> Map.get(:id),
        target_type: "workspace",
        target_ref: socket.assigns.workspace.id,
        metadata: %{
          "isolation" => Atom.to_string(iso.isolation),
          "source" => Atom.to_string(iso.source),
          "redacted_summary" => iso.summary
        }
      })
    end

    socket
    |> assign(:db_isolation, iso)
    |> assign(:workspace_record, load_record(socket.assigns.workspace.id))
    |> assign(:audit_events, refreshed_audit(socket))
  end

  defp can_set_mode?(:config_override), do: false
  defp can_set_mode?(_), do: true

  defp string_to_mode("manual"), do: :manual
  defp string_to_mode("review"), do: :review
  defp string_to_mode("agent_write_locked"), do: :agent_write_locked
  defp string_to_mode("shared_stage_guarded"), do: :shared_stage_guarded
  defp string_to_mode(_), do: nil

  defp gate(socket, decision_fun, audit_attrs) do
    decision = decision_fun.()
    event = Audit.emit_decision(decision, audit_attrs)

    {decision, assign(socket, last_decision: decision, audit_events: refreshed_audit(socket))}
    |> tap(fn _ -> _ = event end)
  end

  defp refreshed_audit(socket) do
    Audit.recent_for(socket.assigns.workspace.id, 50)
  end

  defp refresh_run_ledger(socket, selected_run_id \\ nil) do
    ws_id = socket.assigns.workspace.id
    summaries = Ledger.recent_runs_for(ws_id, 20)

    selected_run_id =
      selected_run_id || socket.assigns[:selected_run_id] || first_run_id(summaries)

    timeline =
      case selected_run_id do
        id when is_binary(id) -> Ledger.timeline_for(ws_id, id)
        _ -> []
      end

    summary =
      case selected_run_id do
        id when is_binary(id) -> Enum.find(summaries, &(&1.id == id))
        _ -> nil
      end

    failure_reason = Status.failure_reason(summary, timeline)

    socket
    |> assign(:run_ledger, summaries)
    |> assign(:selected_run_id, selected_run_id)
    |> assign(:selected_run_summary, summary)
    |> assign(:selected_run_timeline, timeline)
    |> assign(:selected_run_artifacts, WorkspaceStatus.run_artifacts(summary || %{}))
    |> assign(:selected_run_failure_reason, failure_reason)
    |> assign(
      :selected_run_can_retry,
      Status.retryable?(summary, &decision_for_command(socket, &1))
    )
  end

  defp first_run_id([%{id: id} | _]) when is_binary(id), do: id
  defp first_run_id(_), do: nil

  defp ledger_command_decision(decision, socket, command_id, run_id) do
    attrs = %{
      workspace_id: socket.assigns.workspace.id,
      actor_id: current_actor_id(socket),
      command_id: command_id,
      run_id: run_id,
      plane: "safe_action",
      metadata: %{
        source: "ui",
        trigger: "manual",
        protocol: "devide.immediate.v1",
        command_id: command_id,
        safe_action_id: "command:" <> command_id,
        db_isolation: (socket.assigns[:db_isolation] || %{}) |> Map.get(:isolation)
      }
    }

    if DevIDE.Policy.Decision.allow?(decision) do
      Ledger.command_requested(attrs)
    else
      Ledger.command_denied(decision, attrs)
    end
  end

  defp current_actor_id(socket),
    do: (socket.assigns[:current_user] || %{}) |> Map.get(:id)

  defp load_tree(socket, path) do
    with {:ok, root} <- host_path(socket),
         {:ok, entries} <- Files.list(root, path) do
      assign(socket, :tree, Map.put(socket.assigns.tree, path, {:expanded, entries}))
    else
      _ -> socket
    end
  end

  defp start_log_stream(socket) do
    case Logs.Adapter.start_stream(
           socket.assigns.workspace.id,
           socket.assigns.log_service,
           self()
         ) do
      {:ok, ref} -> assign(socket, :log_ref, ref)
      {:error, _reason} -> assign(socket, :log_ref, nil)
    end
  end

  defp default_service(%{type: :v3}), do: "milc-platform-server"
  defp default_service(_), do: "app"

  defp format_file_error(:too_large), do: "File too large."
  defp format_file_error(:binary), do: "Binary content — refused."
  defp format_file_error(:not_a_file), do: "Not a regular file."
  defp format_file_error(:outside_root), do: "Path outside workspace root."
  defp format_file_error(:symlink_escape), do: "Symlink escapes workspace root."
  defp format_file_error(:conflict), do: "Conflict: file changed on disk."
  defp format_file_error(other), do: "Error: #{inspect(other)}"

  defp refresh_git_status(socket) do
    case host_path(socket) do
      {:ok, root} ->
        case Git.status_short(root) do
          {:ok, entries} -> assign(socket, :git_status, entries)
          _ -> assign(socket, :git_status, [])
        end

      _ ->
        assign(socket, :git_status, [])
    end
  end

  defp do_create(:file, root, rel) do
    case Files.create_file(root, rel) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp do_create(:dir, root, rel), do: Files.create_dir(root, rel)

  defp refresh_tree(socket) do
    expanded =
      socket.assigns.tree
      |> Enum.filter(fn {_, {state, _}} -> state == :expanded end)
      |> Enum.map(fn {p, _} -> p end)

    Enum.reduce(expanded, assign(socket, :tree, %{}), fn p, acc -> load_tree(acc, p) end)
  end

  defp load_agents(socket) do
    case host_path(socket) do
      {:ok, root} ->
        caps = Agents.detect(root, socket.assigns.workspace)

        socket
        |> assign(:agent_caps, caps)
        |> assign(:agent_transcripts, Agents.transcripts(root))
        |> assign(:agent_review_cmds, Agents.review_commands(caps))
        |> assign(:proposals, Proposals.discover(root))
        |> attach_existing_agent_run()

      _ ->
        socket
        |> assign(:agent_caps, [])
        |> assign(:agent_transcripts, [])
        |> assign(:agent_review_cmds, [])
        |> assign(:proposals, [])
    end
  end

  defp attach_existing_agent_run(socket) do
    case DevIDE.Agents.Run.whereis(socket.assigns.workspace.id) do
      {:ok, pid} ->
        case DevIDE.Agents.Run.subscribe(pid) do
          {:ok, snap} -> assign(socket, :agent_run, snap)
          _ -> socket
        end

      _ ->
        socket
    end
  end

  defp attach_existing_run(socket) do
    case Commands.Run.whereis(socket.assigns.workspace.id) do
      {:ok, pid} ->
        case Commands.Run.subscribe(pid) do
          {:ok, snap} -> assign(socket, :active_run, snap)
          _ -> socket
        end

      _ ->
        socket
    end
  end

  @run_buffer_cap 256 * 1024
  defp cap_buffer(b) when byte_size(b) <= @run_buffer_cap, do: b

  defp cap_buffer(b) do
    drop = byte_size(b) - @run_buffer_cap
    <<_::binary-size(drop), tail::binary>> = b
    "[…truncated]\n" <> tail
  end

  defp load_diff(socket, path) do
    case host_path(socket) do
      {:ok, root} ->
        case Git.diff(root, path) do
          {:ok, ""} -> assign(socket, :file_diff, nil)
          {:ok, diff} -> assign(socket, :file_diff, diff)
          _ -> assign(socket, :file_diff, nil)
        end

      _ ->
        assign(socket, :file_diff, nil)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="palette-anchor" phx-hook="PaletteHook" class="hidden"></div>
    {render_palette(assigns)}
    <div class="mx-auto max-w-6xl p-6 space-y-4">
      <header class="flex items-center justify-between">
        <div>
          <.link navigate={~p"/workspaces"} class="text-sm text-blue-700 hover:underline">
            ← Workspaces
          </.link>
          <h1 class="text-2xl font-semibold">{@workspace.name}</h1>
          <p class="text-xs text-zinc-500 font-mono">
            {@workspace.status} · {@workspace.branch} · {render_path(@host_path)}
          </p>
        </div>
        <nav class="flex gap-2 text-sm">
          <button phx-click="switch_tab" phx-value-tab="terminal" class={tab_class(@tab, "terminal")}>
            Terminal
          </button>
          <button phx-click="switch_tab" phx-value-tab="files" class={tab_class(@tab, "files")}>
            Files
          </button>
          <button phx-click="switch_tab" phx-value-tab="search" class={tab_class(@tab, "search")}>
            Search
          </button>
          <button phx-click="switch_tab" phx-value-tab="diff" class={tab_class(@tab, "diff")}>
            Diff
          </button>
          <button phx-click="switch_tab" phx-value-tab="run" class={tab_class(@tab, "run")}>
            Run
          </button>
          <button phx-click="switch_tab" phx-value-tab="agents" class={tab_class(@tab, "agents")}>
            Agents
          </button>
          <button phx-click="switch_tab" phx-value-tab="logs" class={tab_class(@tab, "logs")}>
            Logs
          </button>
          <button
            phx-click="audit_drawer:toggle"
            class="text-sm border rounded px-2 py-0.5 ml-2 hover:bg-zinc-50"
            title="evidence drawer — audit, denials, mode changes"
          >
            Evidence
            <%= if (denies = deny_count(@audit_events)) > 0 do %>
              <span class="ml-1 text-[10px] font-mono text-red-700 align-middle">
                ● {denies}
              </span>
            <% end %>
          </button>
        </nav>
      </header>

      {if @tab == "terminal", do: render_terminal(assigns)}
      {if @tab == "files", do: render_files(assigns)}
      {if @tab == "search", do: render_search(assigns)}
      {if @tab == "diff", do: render_diff(assigns)}
      {if @tab == "run", do: render_run(assigns)}
      {if @tab == "agents", do: render_agents(assigns)}
      {if @tab == "logs", do: render_logs(assigns)}
    </div>
    {render_audit_drawer(assigns)}
    """
  end

  # Evidence drawer — product.md §9.4.
  # One time-ordered stream of governed events (allow, deny, mode change,
  # workspace events). Default closed; reachable, not advertised.
  defp render_audit_drawer(assigns) do
    ~H"""
    <div
      :if={@audit_drawer_open}
      class="fixed inset-0 z-40 pointer-events-none"
      aria-hidden={if @audit_drawer_open, do: "false", else: "true"}
    >
      <div
        class="absolute inset-0 bg-black/20 pointer-events-auto"
        phx-click="audit_drawer:close"
      >
      </div>
      <aside
        class="absolute right-0 top-0 bottom-0 w-[380px] bg-white border-l shadow-xl pointer-events-auto flex flex-col"
        role="complementary"
        aria-label="Evidence drawer"
      >
        <header class="flex items-center justify-between px-4 py-3 border-b">
          <div>
            <h2 class="text-sm font-semibold tracking-tight">Evidence</h2>
            <p class="text-[11px] text-zinc-500 font-mono">
              {length(@audit_events)} events · {ledger_event_count(@audit_events)} ledger · workspace {@workspace.name}
            </p>
          </div>
          <div class="flex items-center gap-1">
            <button
              phx-click="audit_drawer:refresh"
              class="text-[11px] border rounded px-2 py-0.5 hover:bg-zinc-50"
              title="refresh audit"
            >
              ↻
            </button>
            <button
              phx-click="audit_drawer:close"
              class="text-[11px] border rounded px-2 py-0.5 hover:bg-zinc-50"
              title="close (esc)"
            >
              ×
            </button>
          </div>
        </header>
        <div class="flex-1 overflow-auto px-3 py-2 font-mono text-[11px] leading-relaxed">
          <%= if @audit_events == [] do %>
            <p class="text-zinc-400 italic">no events recorded yet</p>
          <% else %>
            <ol class="space-y-1.5">
              <%= for e <- @audit_events do %>
                <li class="flex gap-2 items-baseline">
                  <span class={"inline-block w-1.5 h-1.5 rounded-full mt-1.5 shrink-0 " <> audit_dot_class(e)}>
                  </span>
                  <span class="text-zinc-400 shrink-0">
                    {Calendar.strftime(e.inserted_at, "%H:%M:%S")}
                  </span>
                  <span class={"shrink-0 font-medium " <> audit_verb_class(e)}>
                    {audit_verb(e)}
                  </span>
                  <span class="text-zinc-700 break-all">
                    {audit_detail(e)}
                  </span>
                  <%= if run_id = audit_run_id(e) do %>
                    <button
                      id={"audit-open-run-#{dom_fragment(run_id)}-#{dom_fragment(e.id)}"}
                      phx-click="run_ledger:open"
                      phx-value-id={run_id}
                      class="ml-auto shrink-0 rounded border px-1 py-0.5 text-[10px] text-zinc-600 hover:bg-zinc-50"
                      title="open run timeline"
                    >
                      run
                    </button>
                  <% end %>
                </li>
              <% end %>
            </ol>
          <% end %>
        </div>
        <footer class="px-3 py-2 border-t text-[10px] text-zinc-500 font-mono">
          newest first · capped at 50 · time-ordered stream (product.md §9.4)
        </footer>
      </aside>
    </div>
    """
  end

  defp deny_count(events) when is_list(events),
    do: Enum.count(events, fn e -> e.decision == :deny end)

  defp deny_count(_), do: 0

  defp ledger_event_count(events) when is_list(events),
    do: Enum.count(events, &Ledger.ledger_event?/1)

  defp ledger_event_count(_), do: 0

  defp audit_dot_class(%{decision: :deny}), do: "bg-red-600"
  defp audit_dot_class(%{decision: :allow}), do: "bg-green-600"
  defp audit_dot_class(%{action: "workspace.mode_set"}), do: "bg-amber-500"
  defp audit_dot_class(_), do: "bg-zinc-400"

  defp audit_verb_class(%{decision: :deny}), do: "text-red-700"
  defp audit_verb_class(%{decision: :allow}), do: "text-green-700"
  defp audit_verb_class(%{action: "workspace.mode_set"}), do: "text-amber-700"
  defp audit_verb_class(_), do: "text-zinc-600"

  defp audit_verb(%{decision: :deny}), do: "deny"
  defp audit_verb(%{decision: :allow}), do: "allow"
  defp audit_verb(%{action: "workspace.mode_set"}), do: "mode"
  defp audit_verb(%{action: action}), do: action |> String.split(".") |> List.last()

  defp audit_detail(%{action: action, target_ref: ref, reason: reason}) do
    base = action

    base =
      cond do
        ref && ref != "" -> "#{base} · #{ref}"
        true -> base
      end

    cond do
      reason -> "#{base} · #{Atom.to_string(reason)}"
      true -> base
    end
  end

  defp ledger_event_noun(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "noun") || "event"
  end

  defp ledger_event_noun(_), do: "event"

  defp audit_run_id(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "run_id") || Map.get(metadata, :run_id)
  end

  defp audit_run_id(_), do: nil

  defp artifact_events(artifact) do
    artifact
    |> Map.get(:report_events, [])
    |> Enum.join(", ")
    |> case do
      "" -> "none"
      value -> value
    end
  end

  defp artifact_report_refs(artifact) do
    artifact
    |> Map.get(:report_ids, [])
    |> Enum.join(", ")
    |> case do
      "" -> "none"
      value -> value
    end
  end

  defp dom_fragment(value) when is_binary(value),
    do: String.replace(value, ~r/[^a-zA-Z0-9_-]/, "-")

  defp dom_fragment(value), do: value |> to_string() |> dom_fragment()

  defp render_terminal(assigns) do
    ~H"""
    <section class="space-y-2">
      <%= case @host_path do %>
        <% {:ok, cwd} -> %>
          <div class="flex flex-wrap items-center justify-between gap-2 text-xs text-zinc-500">
            <p>
              <span class="font-mono">{@terminal_mode}</span>
              · cwd <span class="font-mono">{cwd}</span>
              <%= if @terminal_mode == :raw do %>
                · tmux <span class="font-mono">{@tmux_session}</span>
              <% end %>
            </p>
            <div class="flex items-center gap-1">
              <button
                id="terminal-mode-governed"
                type="button"
                phx-click="terminal:set_mode"
                phx-value-mode="governed"
                class={terminal_mode_class(@terminal_mode, :governed)}
              >
                Governed
              </button>
              <%= if raw_terminal_allowed?(@workspace_mode, @host_id) do %>
                <button
                  id="terminal-mode-raw"
                  type="button"
                  phx-click="terminal:set_mode"
                  phx-value-mode="raw"
                  class={terminal_mode_class(@terminal_mode, :raw)}
                >
                  Raw shell
                </button>
              <% end %>
            </div>
          </div>
          <div
            id={"terminal-" <> @workspace.id <> "-" <> Atom.to_string(@terminal_mode)}
            phx-hook="TerminalHook"
            phx-update="ignore"
            data-workspace-id={@workspace.id}
            data-sid={@terminal_sid}
            data-terminal-mode={Atom.to_string(@terminal_mode)}
            data-host-id={@host_id}
            data-socket-token={@socket_token}
            class="bg-black rounded h-[70vh] p-2"
          >
          </div>
        <% {:error, :missing_path} -> %>
          <p class="text-sm text-red-700">
            Workspace has no host path. The manager has not finished provisioning, or this is a remote workspace.
          </p>
        <% {:error, :outside_root} -> %>
          <p class="text-sm text-red-700">
            Refusing to open terminal: workspace path is outside the allowed roots ({inspect(
              Workspaces.allowed_roots()
            )}).
          </p>
      <% end %>
    </section>
    """
  end

  defp render_files(assigns) do
    ~H"""
    <section class="grid grid-cols-[300px_1fr] gap-4 h-[75vh]">
      <div class="border rounded p-2 overflow-auto bg-zinc-50 space-y-2">
        <%= case @host_path do %>
          <% {:ok, _root} -> %>
            <div class="flex flex-wrap gap-1 text-xs">
              <span class="px-1 text-zinc-500">in:</span>
              <span class="font-mono text-zinc-700">
                {if @selected_dir == "", do: "/", else: @selected_dir}
              </span>
              <button
                phx-click="tree:new_form"
                phx-value-kind="file"
                class="ml-auto rounded border px-1.5"
              >
                +File
              </button>
              <button phx-click="tree:new_form" phx-value-kind="dir" class="rounded border px-1.5">
                +Dir
              </button>
              <button phx-click="tree:refresh" class="rounded border px-1.5">↻</button>
            </div>
            <%= if @new_input do %>
              <.form for={%{}} phx-submit="tree:create" class="flex gap-1 text-xs">
                <input
                  name="name"
                  autofocus
                  placeholder={if elem(@new_input, 0) == :file, do: "filename", else: "dir name"}
                  class="flex-1 border rounded px-1 py-0.5 font-mono"
                />
                <button class="rounded bg-zinc-900 text-white px-2 py-0.5">create</button>
                <button type="button" phx-click="tree:cancel_new" class="rounded border px-2 py-0.5">
                  x
                </button>
              </.form>
            <% end %>
            <%= if @tree_error do %>
              <p class="text-xs text-red-700">{@tree_error}</p>
            <% end %>
            {render_tree_node(assigns, "")}
            {render_project_card(assigns)}
            {render_symbols_panel(assigns)}
          <% _ -> %>
            <p class="text-xs text-red-700">No host path; cannot list files.</p>
        <% end %>
      </div>
      <div class="border rounded flex flex-col">
        <%= if @open_file do %>
          <div class="px-3 py-1.5 border-b bg-zinc-50 text-xs font-mono flex flex-wrap justify-between items-center gap-2">
            <%= if @rename_input do %>
              <.form for={%{}} phx-submit="file:rename_submit" class="flex gap-1 flex-1">
                <input name="new_path" value={@rename_input} class="flex-1 border rounded px-1" />
                <button class="rounded bg-zinc-900 text-white px-2">rename</button>
                <button type="button" phx-click="file:rename_cancel" class="rounded border px-2">
                  x
                </button>
              </.form>
            <% else %>
              <span class="truncate">{@open_file.path}</span>
            <% end %>
            <span class="flex items-center gap-2 text-zinc-500">
              <span id="dirty-indicator" data-dirty="false" class="text-amber-700"></span>
              <span>{@open_file.size}b</span>
              <button
                type="button"
                phx-click={Phoenix.LiveView.JS.dispatch("devide:save", to: "#file-viewer")}
                class="rounded bg-zinc-900 text-white px-2 py-0.5"
              >
                Save
              </button>
              <button type="button" phx-click="file:refresh" class="rounded border px-2 py-0.5">
                Refresh
              </button>
              <button type="button" phx-click="file:rename_form" class="rounded border px-2 py-0.5">
                Rename
              </button>
              <button
                type="button"
                phx-click="file:delete_request"
                class="rounded border px-2 py-0.5 text-red-700"
              >
                Delete
              </button>
            </span>
          </div>
          <%= if @delete_confirm do %>
            <div class="px-3 py-1 border-b bg-red-50 text-xs flex justify-between items-center">
              <span>Delete <span class="font-mono">{@delete_confirm}</span>?</span>
              <span class="flex gap-1">
                <button
                  phx-click="file:delete_confirm"
                  class="rounded bg-red-700 text-white px-2 py-0.5"
                >
                  confirm
                </button>
                <button phx-click="file:delete_cancel" class="rounded border px-2 py-0.5">
                  cancel
                </button>
              </span>
            </div>
          <% end %>
          <%= if @save_error do %>
            <div class="px-3 py-1 border-b bg-red-50 text-xs text-red-800">{@save_error}</div>
          <% end %>
        <% else %>
          <div class="px-3 py-1.5 border-b bg-zinc-50 text-xs text-zinc-500">
            {@file_error || "Select a file to view."}
          </div>
        <% end %>
        <div
          id="file-viewer"
          phx-hook="FileViewerHook"
          phx-update="ignore"
          class="flex-1 overflow-auto"
        >
        </div>
      </div>
    </section>
    """
  end

  defp render_tree_node(assigns, path) do
    state = Map.get(assigns.tree, path, {:collapsed, []})
    assigns = Map.put(assigns, :node, %{path: path, state: state})

    ~H"""
    <%= case @node.state do %>
      <% {:expanded, entries} -> %>
        <ul class="text-sm">
          <%= for e <- entries do %>
            <li class="pl-3">
              <%= case e.kind do %>
                <% :dir -> %>
                  <div class="flex items-center group">
                    <button
                      phx-click="tree:toggle"
                      phx-value-path={e.rel_path}
                      class="hover:underline text-left flex-1"
                    >
                      <span class="font-mono text-amber-700">▸</span> {e.name}/
                    </button>
                    <button
                      phx-click="tree:select_dir"
                      phx-value-path={e.rel_path}
                      title="select for new file/dir"
                      class={"text-[10px] px-1 opacity-0 group-hover:opacity-100 " <> if @selected_dir == e.rel_path, do: "opacity-100 text-blue-700", else: ""}
                    >
                      sel
                    </button>
                  </div>
                  <%= if match?({:expanded, _}, Map.get(@tree, e.rel_path)) do %>
                    {render_tree_node(assigns, e.rel_path)}
                  <% end %>
                <% _ -> %>
                  <button
                    phx-click="tree:open"
                    phx-value-path={e.rel_path}
                    class="hover:underline text-left w-full"
                  >
                    <span class="font-mono text-zinc-400">·</span> {e.name}
                  </button>
              <% end %>
            </li>
          <% end %>
        </ul>
      <% _ -> %>
        <p class="text-xs text-zinc-400">(loading…)</p>
    <% end %>
    """
  end

  defp render_search(assigns) do
    grouped =
      assigns.search_results
      |> Enum.group_by(& &1.path)
      |> Enum.sort_by(fn {p, _} -> p end)

    assigns = Map.put(assigns, :grouped_results, grouped)

    ~H"""
    <section class="space-y-3">
      <.form for={%{}} phx-submit="search:run" class="flex gap-2 items-center">
        <input
          name="query"
          value={@search_query}
          placeholder="search workspace…"
          autocomplete="off"
          class="flex-1 border rounded px-2 py-1 text-sm font-mono"
        />
        <button class="rounded bg-zinc-900 text-white px-3 py-1 text-sm">Search</button>
        <span class="text-xs text-zinc-500">
          rg: {if Search.available?(), do: "available", else: "missing"}
        </span>
      </.form>
      {render_search_state(assigns)}
    </section>
    """
  end

  defp render_search_state(assigns) do
    case assigns.search_state do
      :idle ->
        ~H"""
        <p class="text-xs text-zinc-500">
          Type {Search.min_query()}+ chars and press Enter. Searches the workspace via <code>rg</code>; results are PathSafety-checked.
        </p>
        """

      :empty ->
        ~H"""
        <p class="text-xs text-zinc-500">No matches.</p>
        """

      :ok ->
        ~H"""
        <p class="text-xs text-zinc-500">
          {length(@search_results)} match(es) in {length(@grouped_results)} file(s)
          (cap {Search.result_cap()}).
        </p>
        <ul class="text-xs space-y-2">
          <%= for {path, items} <- @grouped_results do %>
            <li>
              <div class="font-mono text-zinc-700">{path} ({length(items)})</div>
              <ul class="ml-3 space-y-0.5">
                <%= for r <- items do %>
                  <li>
                    <button
                      phx-click="annotation:open"
                      phx-value-path={r.path}
                      phx-value-line={r.line}
                      class="font-mono hover:underline text-left"
                    >
                      :{r.line}{if r.column, do: ":" <> Integer.to_string(r.column)}
                    </button>
                    <span class="text-zinc-600 font-mono">— {r.preview}</span>
                  </li>
                <% end %>
              </ul>
            </li>
          <% end %>
        </ul>
        """

      {:error, reason} ->
        assigns = Map.put(assigns, :reason, reason)

        ~H"""
        <p class="text-xs text-red-700">{search_error_text(@reason)}</p>
        """
    end
  end

  defp search_error_text(:rg_missing),
    do: "ripgrep (rg) is not installed on the host; install it to enable search."

  defp search_error_text(:timeout), do: "search timed out; try a more specific query."

  defp search_error_text(:too_short),
    do: "query must be at least #{DevIDE.Search.min_query()} characters."

  defp search_error_text(:too_long),
    do: "query must be at most #{DevIDE.Search.max_query()} characters."

  defp search_error_text(:no_root), do: "workspace path unavailable."
  defp search_error_text(other), do: "search failed: #{inspect(other)}"

  defp render_diff(assigns) do
    ~H"""
    <section class="space-y-2">
      <%= if @git_status == [] do %>
        <p class="text-sm text-zinc-500">No changes.</p>
      <% else %>
        <ul class="text-sm">
          <%= for e <- @git_status do %>
            <li class="font-mono">
              <span class="text-amber-700">{e.x}{e.y}</span> {e.path}
            </li>
          <% end %>
        </ul>
      <% end %>
    </section>
    """
  end

  defp render_run(assigns) do
    ~H"""
    <section class="space-y-2">
      <%= case @host_path do %>
        <% {:ok, _} -> %>
          <div class="flex gap-2 items-center text-sm">
            <%= for {id, _argv} <- Enum.sort(Commands.allowlist()) do %>
              <button
                phx-click="run:start"
                phx-value-id={id}
                disabled={@active_run && @active_run.status == :running}
                class="rounded border px-3 py-1 disabled:opacity-50"
              >
                mix {id}
              </button>
            <% end %>
            <%= if @active_run && @active_run.status == :running do %>
              <button phx-click="run:cancel" class="ml-2 rounded border px-3 py-1 text-red-700">
                cancel
              </button>
            <% end %>
          </div>
          <%= if @active_run do %>
            <div class="text-xs text-zinc-500 font-mono flex gap-3">
              <span>{Enum.join(@active_run.argv, " ")}</span>
              <span class={run_status_class(@active_run.status)}>{@active_run.status}</span>
              <%= if @active_run.exit_code != nil do %>
                <span>exit={inspect(@active_run.exit_code)}</span>
              <% end %>
              <%= if @active_run.started_at do %>
                <span>started {DateTime.to_string(@active_run.started_at)}</span>
              <% end %>
              <%= if @active_run.finished_at do %>
                <span>finished {DateTime.to_string(@active_run.finished_at)}</span>
              <% end %>
            </div>
            <pre class="bg-zinc-950 text-zinc-100 text-xs p-3 rounded h-[60vh] overflow-auto whitespace-pre-wrap">{@active_run.buffer}</pre>
          <% else %>
            <p class="text-xs text-zinc-500">No runs yet.</p>
          <% end %>

          <div
            id="run-ledger"
            class="border-t pt-3 mt-3 grid gap-3 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)]"
          >
            <section>
              <div class="flex items-center justify-between mb-2">
                <h3 class="text-xs font-medium text-zinc-700">Run ledger</h3>
                <span class="text-[10px] font-mono text-zinc-400">
                  {length(@run_ledger)} runs
                </span>
              </div>
              <%= if @run_ledger == [] do %>
                <p id="run-ledger-empty" class="text-xs text-zinc-500">
                  No governed runs recorded.
                </p>
              <% else %>
                <ol class="space-y-1">
                  <%= for r <- @run_ledger do %>
                    <li>
                      <button
                        id={"run-ledger-run-#{dom_fragment(r.id)}"}
                        phx-click="run_ledger:select"
                        phx-value-id={r.id}
                        class={[
                          "w-full rounded border px-2 py-1.5 text-left text-xs transition hover:bg-zinc-50",
                          @selected_run_id == r.id && "border-zinc-900 bg-zinc-50"
                        ]}
                      >
                        <div class="flex items-center gap-2">
                          <span class="font-mono">
                            {Map.get(r, :command_id) || Map.get(r, :safe_action_id) || r.id}
                          </span>
                          <span class={run_status_class(Status.status_class(Map.get(r, :status)))}>
                            {Map.get(r, :status, "unknown")}
                          </span>
                        </div>
                        <div class="mt-1 flex flex-wrap gap-2 font-mono text-[10px] text-zinc-500">
                          <span>{Map.get(r, :protocol, "ledger")}</span>
                          <%= if Map.get(r, :assignment_id) do %>
                            <span>assignment={Map.get(r, :assignment_id)}</span>
                          <% end %>
                          <%= if Map.get(r, :finished_at) do %>
                            <span>{Map.get(r, :finished_at)}</span>
                          <% end %>
                        </div>
                      </button>
                    </li>
                  <% end %>
                </ol>
              <% end %>
            </section>

            <section>
              <div class="flex items-center justify-between mb-2">
                <h3 class="text-xs font-medium text-zinc-700">Timeline</h3>
                <%= if @selected_run_id do %>
                  <span class="text-[10px] font-mono text-zinc-400">
                    {@selected_run_id}
                  </span>
                <% end %>
              </div>
              <%= if @selected_run_timeline == [] do %>
                <p id="run-ledger-timeline-empty" class="text-xs text-zinc-500">
                  Select a run to inspect its canonical events.
                </p>
              <% else %>
                <%= if @selected_run_summary do %>
                  <dl
                    id="run-ledger-summary"
                    class="mb-2 grid grid-cols-[auto_1fr] gap-x-2 gap-y-0.5 rounded border bg-zinc-50 px-2 py-1.5 text-[10px]"
                  >
                    <dt class="text-zinc-500">status</dt>
                    <dd class="font-mono">{Map.get(@selected_run_summary, :status, "unknown")}</dd>
                    <dt class="text-zinc-500">command</dt>
                    <dd class="font-mono">
                      {Map.get(@selected_run_summary, :command_id) ||
                        Map.get(@selected_run_summary, :safe_action_id) || "unknown"}
                    </dd>
                    <%= if Map.get(@selected_run_summary, :assignment_id) do %>
                      <dt class="text-zinc-500">assignment</dt>
                      <dd class="font-mono">{Map.get(@selected_run_summary, :assignment_id)}</dd>
                    <% end %>
                  </dl>
                  <%= if Status.failed?(@selected_run_summary.status) do %>
                    <div
                      id="run-failure-surface"
                      class="rounded border bg-red-50 px-2 py-1.5 text-xs space-y-1 mb-2"
                    >
                      <div class="flex items-center gap-2">
                        <span class="text-red-700 font-medium">Failed</span>
                        <%= if @selected_run_failure_reason do %>
                          <span class="font-mono text-zinc-600">{@selected_run_failure_reason}</span>
                        <% end %>
                      </div>
                      <%= if @selected_run_can_retry do %>
                        <button
                          id="run-retry-btn"
                          phx-click="run:start"
                          phx-value-id={@selected_run_summary.command_id}
                          class="rounded border px-2 py-0.5 bg-white hover:bg-zinc-50"
                        >
                          Retry
                        </button>
                      <% end %>
                    </div>
                  <% end %>
                <% end %>
                <ol id="run-ledger-timeline" class="space-y-1.5">
                  <%= for e <- @selected_run_timeline do %>
                    <li
                      id={"run-ledger-event-#{dom_fragment(e.id)}"}
                      class="rounded border px-2 py-1.5 text-xs"
                    >
                      <div class="flex flex-wrap items-baseline gap-2">
                        <span class={"inline-block w-1.5 h-1.5 rounded-full " <> audit_dot_class(e)}>
                        </span>
                        <span class="font-mono text-zinc-400">
                          {Calendar.strftime(e.inserted_at, "%H:%M:%S")}
                        </span>
                        <span class={"font-medium " <> audit_verb_class(e)}>
                          {e.action}
                        </span>
                        <span class="font-mono text-[10px] text-zinc-500">
                          {ledger_event_noun(e)}
                        </span>
                      </div>
                      <p class="mt-1 font-mono text-[10px] text-zinc-600 break-all">
                        {audit_detail(e)}
                      </p>
                    </li>
                  <% end %>
                </ol>
                <div id="run-ledger-artifacts" class="mt-3 space-y-2">
                  <h3 class="text-xs font-medium text-zinc-700">Artifacts</h3>
                  <%= if @selected_run_artifacts == [] do %>
                    <p class="text-xs text-zinc-500">No artifacts recorded for this run.</p>
                  <% else %>
                    <%= for artifact <- @selected_run_artifacts do %>
                      {render_run_artifact(assigns, artifact)}
                    <% end %>
                  <% end %>
                </div>
              <% end %>
            </section>
          </div>
        <% _ -> %>
          <p class="text-sm text-red-700">Cannot run commands: workspace path unavailable.</p>
      <% end %>
    </section>
    """
  end

  defp render_run_artifact(assigns, artifact) do
    assigns = assign(assigns, :artifact, artifact)

    case Map.get(artifact, :type) do
      "command_output" ->
        ~H"""
        <section id="run-artifact-command-output" class="rounded border text-xs">
          <header class="flex flex-wrap items-center gap-2 border-b px-2 py-1 font-mono text-[10px] text-zinc-500">
            <span>command output</span>
            <span>{Map.get(@artifact, :command_id)}</span>
            <span>{Map.get(@artifact, :status)}</span>
            <%= if Map.get(@artifact, :exit_code) do %>
              <span>exit={Map.get(@artifact, :exit_code)}</span>
            <% end %>
            <%= if Map.get(@artifact, :output_truncated) do %>
              <span class="text-amber-700">truncated</span>
            <% end %>
          </header>
          <pre class="max-h-72 overflow-auto whitespace-pre-wrap bg-zinc-950 p-2 text-[11px] text-zinc-100">{Map.get(@artifact, :output, "")}</pre>
        </section>
        """

      "runner_assignment" ->
        ~H"""
        <section id="run-artifact-runner-assignment" class="rounded border px-2 py-1.5 text-xs">
          <div class="flex flex-wrap items-center gap-2 font-mono text-[10px] text-zinc-600">
            <span>runner assignment</span>
            <span>{Map.get(@artifact, :assignment_id)}</span>
            <span>{Map.get(@artifact, :status)}</span>
            <%= if Map.get(@artifact, :safe_action_id) do %>
              <span>{Map.get(@artifact, :safe_action_id)}</span>
            <% end %>
          </div>
          <dl class="mt-1 grid grid-cols-[auto_1fr] gap-x-2 gap-y-0.5 text-[10px]">
            <dt class="text-zinc-500">reports</dt>
            <dd class="font-mono">{Map.get(@artifact, :reports_count, 0)}</dd>
            <dt class="text-zinc-500">events</dt>
            <dd class="font-mono">{artifact_events(@artifact)}</dd>
            <dt class="text-zinc-500">refs</dt>
            <dd class="font-mono break-all">{artifact_report_refs(@artifact)}</dd>
            <%= if Map.get(@artifact, :failure_reason) do %>
              <dt class="text-zinc-500">failure</dt>
              <dd class="font-mono text-red-700">{Map.get(@artifact, :failure_reason)}</dd>
            <% end %>
            <%= if Map.get(@artifact, :failure_class) do %>
              <dt class="text-zinc-500">class</dt>
              <dd class="font-mono">{Map.get(@artifact, :failure_class)}</dd>
            <% end %>
          </dl>
        </section>
        """

      _ ->
        ~H"""
        <section class="rounded border px-2 py-1.5 text-xs text-zinc-500">
          Unknown artifact.
        </section>
        """
    end
  end

  defp render_project_card(assigns) do
    ~H"""
    <%= if @project_meta do %>
      <details class="border-t pt-1 mt-2 text-[11px]">
        <summary class="cursor-pointer text-zinc-700">Project</summary>
        <ul class="mt-1 space-y-0.5">
          <li>Mix: {yes_no(@project_meta.mix?)}</li>
          <li>Umbrella: {yes_no(@project_meta.umbrella?)}</li>
          <li>Phoenix: {yes_no(@project_meta.phoenix?)}</li>
          <li>LiveView: {yes_no(@project_meta.live_view?)}</li>
          <li>Ecto: {yes_no(@project_meta.ecto?)}</li>
          <li>Formatter: {yes_no(@project_meta.formatter?)}</li>
          <%= if @tooling do %>
            <li>
              Lexical: {detected_or_missing(@tooling.lexical? or @tooling.mix_lock_lexical?)}
            </li>
            <li>
              ElixirLS: {detected_or_missing(@tooling.elixir_ls? or @tooling.mix_lock_elixir_ls?)}
            </li>
          <% end %>
        </ul>
      </details>
    <% end %>
    """
  end

  defp render_symbols_panel(assigns) do
    case assigns.open_file do
      %{path: path, content: content} ->
        symbols = ElixirNav.symbols(content, path)
        assigns = Map.put(assigns, :file_symbols, symbols) |> Map.put(:file_path, path)

        ~H"""
        <details class="border-t pt-1 mt-2 text-[11px]" open>
          <summary class="cursor-pointer text-zinc-700">
            Symbols ({length(@file_symbols)})
          </summary>
          <%= cond do %>
            <% String.ends_with?(@file_path, ".heex") -> %>
              <p class="text-zinc-500">HEEx symbols not supported yet.</p>
            <% @file_symbols == [] -> %>
              <p class="text-zinc-500">No symbols.</p>
            <% true -> %>
              <ul class="font-mono space-y-0.5 mt-1">
                <%= for s <- @file_symbols do %>
                  <li>
                    <button
                      phx-click="annotation:open"
                      phx-value-path={@file_path}
                      phx-value-line={s.line}
                      class={"hover:underline text-left " <> symbol_color(s)}
                    >
                      <span class="text-zinc-400">{symbol_glyph(s.kind)}</span>
                      {s.name}
                      <%= if s.visibility == :private do %>
                        <span class="text-zinc-400">priv</span>
                      <% end %>
                      <span class="text-zinc-400">:{s.line}</span>
                    </button>
                  </li>
                <% end %>
              </ul>
          <% end %>
        </details>
        """

      _ ->
        ~H""
    end
  end

  defp yes_no(true), do: "yes"
  defp yes_no(_), do: "no"
  defp detected_or_missing(true), do: "detected"
  defp detected_or_missing(_), do: "missing"

  defp symbol_glyph(:module), do: "M"
  defp symbol_glyph(:function), do: "f"
  defp symbol_glyph(:macro), do: "ƒ"
  defp symbol_glyph(:guard), do: "g"
  defp symbol_glyph(:delegate), do: "→"
  defp symbol_glyph(:test), do: "t"
  defp symbol_glyph(:describe), do: "d"
  defp symbol_glyph(_), do: "?"

  defp symbol_color(%{kind: :module}), do: "text-blue-700"
  defp symbol_color(%{visibility: :private}), do: "text-zinc-500"
  defp symbol_color(%{kind: :test}), do: "text-purple-700"
  defp symbol_color(%{kind: :describe}), do: "text-purple-700"
  defp symbol_color(_), do: "text-zinc-800"

  defp parse_line(nil), do: nil
  defp parse_line(""), do: nil

  defp parse_line(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_line(_), do: nil

  defp palette_query(socket, q) do
    root =
      case host_path(socket) do
        {:ok, r} -> r
        _ -> nil
      end

    Palette.query(root, q)
  end

  defp render_palette(assigns) do
    ~H"""
    <%= if @palette_open do %>
      <div
        class="fixed inset-0 bg-black/40 z-50 flex items-start justify-center pt-24"
        phx-click="palette:close"
      >
        <div class="bg-white rounded shadow-lg w-[640px] max-w-[90vw]" phx-click-away="palette:close">
          <.form
            for={%{}}
            phx-change="palette:query"
            phx-submit="palette:execute"
            class="p-2 border-b"
          >
            <input
              name="query"
              value={@palette_query}
              autofocus
              autocomplete="off"
              placeholder="Type to search files / actions…"
              class="w-full text-sm px-2 py-1.5 outline-none"
            />
            <input type="hidden" name="_top_id" value={top_palette_id(@palette_items)} />
          </.form>
          <ul class="max-h-[60vh] overflow-auto text-sm">
            <%= if @palette_items == [] do %>
              <li class="px-3 py-2 text-zinc-500 text-xs">No matches.</li>
            <% else %>
              <%= for {item, idx} <- Enum.with_index(@palette_items) do %>
                <li
                  class={"flex items-center gap-2 px-3 py-1.5 border-b last:border-b-0 cursor-pointer hover:bg-zinc-50 " <> if(idx == 0, do: "bg-zinc-100", else: "")}
                  phx-click="palette:execute"
                  phx-value-id={item.id}
                >
                  <span class="text-[10px] uppercase text-zinc-500 w-14">{item.kind}</span>
                  <span class="font-mono truncate flex-1">{item.label}</span>
                  <%= if item.detail do %>
                    <span class="text-xs text-zinc-500 truncate">{item.detail}</span>
                  <% end %>
                </li>
              <% end %>
            <% end %>
          </ul>
          <div class="px-3 py-1.5 text-[10px] text-zinc-500 border-t flex justify-between">
            <span>Cmd/Ctrl+K toggle · Enter runs top match · Esc closes</span>
            <span>{length(@palette_items)} item(s)</span>
          </div>
        </div>
      </div>
    <% else %>
      <div id="palette-modal-empty" class="hidden"></div>
    <% end %>
    """
  end

  defp top_palette_id([%{id: id} | _]), do: id
  defp top_palette_id(_), do: ""

  defp load_project_meta(socket) do
    case host_path(socket) do
      {:ok, root} ->
        socket
        |> assign(:project_meta, ElixirNav.project(root))
        |> assign(:tooling, ElixirNav.tooling(root))

      _ ->
        socket
    end
  end

  defp run_status_class(status) do
    case Status.status_class(status) do
      :running -> "text-amber-700"
      :succeeded -> "text-green-700"
      :failed -> "text-red-700"
      :timed_out -> "text-purple-700"
      _ -> "text-zinc-500"
    end
  end

  defp render_agents(assigns) do
    ~H"""
    <section class="space-y-3">
      {render_safety_card(assigns)}
      <div class="rounded border border-amber-300 bg-amber-50 p-3 text-xs text-amber-900">
        <strong>Write mode: disabled.</strong>
        Agent attach is read-only. Phoenix does not start agents, send prompts, or grant write access.
      </div>
      <div class="flex justify-end">
        <button phx-click="agents:refresh" class="text-xs rounded border px-2 py-1">↻ refresh</button>
      </div>
      <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
        <%= for cap <- @agent_caps do %>
          <div class="border rounded p-3">
            <div class="flex justify-between items-baseline">
              <h3 class="font-medium">{cap_label(cap.kind)}</h3>
              <span class={cap_status_class(cap.status)}>{cap.status}</span>
            </div>
            <%= if cap.status == :detected do %>
              <dl class="text-xs text-zinc-600 space-y-0.5 mt-1">
                <div>source: {cap.source}</div>
                <%= if cap.path do %>
                  <div class="font-mono">path: {cap.path}</div>
                <% end %>
                <%= if cap.url do %>
                  <div class="font-mono">url: {cap.url}</div>
                <% end %>
                <%= if cap.mtime do %>
                  <div>updated: {NaiveDateTime.to_string(cap.mtime)}</div>
                <% end %>
                <%= if cap.details != %{} do %>
                  <div class="font-mono text-zinc-400">{inspect(cap.details)}</div>
                <% end %>
              </dl>
            <% else %>
              <p class="text-xs text-zinc-500 mt-1">not detected</p>
            <% end %>
          </div>
        <% end %>
      </div>

      <div class="border rounded p-3 space-y-2">
        <h3 class="font-medium">Agent Runs (review mode)</h3>
        <p class="text-xs text-zinc-500">
          Phoenix may start an allowlisted, write-free command and observe its output.
          No prompts, no patches, no Apply path.
        </p>
        <%= if @agent_run_error do %>
          <p class="text-xs text-red-700">{@agent_run_error}</p>
        <% end %>
        <%= if @agent_review_cmds == [] do %>
          <p class="text-xs text-zinc-500">
            No review commands available — required capabilities not detected.
          </p>
        <% else %>
          <div class="flex flex-wrap gap-2">
            <%= for cmd <- @agent_review_cmds do %>
              <button
                phx-click="agent_run:start"
                phx-value-id={cmd.id}
                disabled={@agent_run && @agent_run.status == :running}
                title={cmd.description}
                class="text-xs rounded border px-2 py-1 disabled:opacity-50"
              >
                ▶ {cmd.id}
              </button>
            <% end %>
            <%= if @agent_run && @agent_run.status == :running do %>
              <button
                phx-click="agent_run:cancel"
                class="text-xs rounded border px-2 py-1 text-red-700"
              >
                cancel
              </button>
            <% end %>
          </div>
        <% end %>
        <%= if @agent_run do %>
          <div class="text-xs font-mono text-zinc-500 flex flex-wrap gap-3">
            <span>{Enum.join(@agent_run.argv, " ")}</span>
            <span class={cap_status_class(@agent_run.status)}>{@agent_run.status}</span>
            <%= if @agent_run.exit_code != nil do %>
              <span>exit={inspect(@agent_run.exit_code)}</span>
            <% end %>
            <%= if @agent_run.started_at do %>
              <span>started {DateTime.to_string(@agent_run.started_at)}</span>
            <% end %>
            <%= if @agent_run.finished_at do %>
              <span>finished {DateTime.to_string(@agent_run.finished_at)}</span>
            <% end %>
          </div>
          <pre class="bg-zinc-950 text-zinc-100 text-xs p-3 rounded max-h-72 overflow-auto whitespace-pre-wrap">{@agent_run.buffer}</pre>
        <% end %>
      </div>

      {render_proposals(assigns)}

      <div class="border rounded p-3">
        <h3 class="font-medium mb-2">Recent agent transcripts (read-only)</h3>
        <%= if @agent_transcripts == [] do %>
          <p class="text-xs text-zinc-500">No transcripts found.</p>
        <% else %>
          <ul class="text-xs space-y-1">
            <%= for a <- @agent_transcripts do %>
              <li class="font-mono flex justify-between">
                <button
                  phx-click="tree:open"
                  phx-value-path={a.rel_path}
                  class="hover:underline text-left flex-1 truncate"
                >
                  {a.rel_path}
                </button>
                <span class="text-zinc-500 ml-2">
                  {a.size}b {if a.mtime, do: "· " <> NaiveDateTime.to_string(a.mtime)}
                </span>
              </li>
            <% end %>
          </ul>
        <% end %>
      </div>
    </section>
    """
  end

  defp render_proposals(assigns) do
    ~H"""
    <div class="border rounded p-3 space-y-2">
      <h3 class="font-medium">Proposal Review</h3>
      <p class="text-xs text-zinc-500">
        Review only. To apply a proposal, copy it or use terminal/git manually.
      </p>
      <%= if @proposals == [] do %>
        <p class="text-xs text-zinc-500">No proposals discovered.</p>
      <% else %>
        <div class="grid grid-cols-1 md:grid-cols-[260px_1fr] gap-3">
          <ul class="text-xs space-y-1 max-h-72 overflow-auto">
            <%= for p <- @proposals do %>
              <li>
                <button
                  phx-click="proposal:select"
                  phx-value-path={p.rel_path}
                  class={"w-full text-left rounded px-1 py-0.5 hover:bg-zinc-100 " <> if @selected_proposal && @selected_proposal.rel_path == p.rel_path, do: "bg-zinc-200", else: ""}
                >
                  <span class="font-mono truncate block">{p.rel_path}</span>
                  <span class="text-zinc-500">
                    {p.size}b {if p.mtime, do: "· " <> NaiveDateTime.to_string(p.mtime)}
                  </span>
                </button>
              </li>
            <% end %>
          </ul>
          <div class="border rounded p-2 min-h-[12rem]">
            <%= if @selected_proposal do %>
              {render_proposal_detail(assigns, @selected_proposal)}
            <% else %>
              <p class="text-xs text-zinc-500">Select a proposal to preview.</p>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_proposal_detail(assigns, proposal) do
    _ = assigns.proposal_analysis
    git_paths = MapSet.new(assigns.git_status, & &1.path)
    proposal_paths = MapSet.new(proposal.changes, & &1.path)

    in_both = MapSet.intersection(git_paths, proposal_paths) |> MapSet.to_list() |> Enum.sort()

    only_proposal =
      MapSet.difference(proposal_paths, git_paths) |> MapSet.to_list() |> Enum.sort()

    only_workspace =
      MapSet.difference(git_paths, proposal_paths) |> MapSet.to_list() |> Enum.sort()

    assigns =
      assigns
      |> Map.put(:p, proposal)
      |> Map.put(:in_both, in_both)
      |> Map.put(:only_proposal, only_proposal)
      |> Map.put(:only_workspace, only_workspace)

    ~H"""
    <div class="space-y-2 text-xs">
      <div class="flex justify-between font-mono">
        <span class="truncate">{@p.rel_path}</span>
        <button phx-click="proposal:clear" class="rounded border px-1.5">close</button>
      </div>
      <dl class="text-zinc-600 space-y-0.5">
        <div>parser: {@p.parser}</div>
        <div>
          status: <span class={proposal_status_class(@p.status)}>{@p.status}</span>
          <%= if @p.truncated do %>
            · (preview truncated)
          <% end %>
        </div>
        <%= if @p.size > 0 do %>
          <div>size: {@p.size}b</div>
        <% end %>
        <%= if @p.mtime do %>
          <div>mtime: {NaiveDateTime.to_string(@p.mtime)}</div>
        <% end %>
        <%= if @p.error do %>
          <div class="text-red-700">error: {@p.error}</div>
        <% end %>
      </dl>

      <%= if @proposal_analysis do %>
        <div class="border rounded p-2 bg-zinc-50 space-y-1">
          <div class="flex items-center gap-2">
            <strong>Conflict analysis:</strong>
            <span class={analysis_class(@proposal_analysis.risk)}>
              {@proposal_analysis.risk}
            </span>
            <span class="text-zinc-500">— {@proposal_analysis.reason}</span>
          </div>
          <%= if @proposal_analysis.overlapping_files != [] do %>
            <div>
              <span class="text-zinc-500">overlapping files:</span>
              <ul class="font-mono ml-3 list-disc">
                <%= for f <- @proposal_analysis.files,
                        f.status in [:overlap, :conflict] do %>
                  <li>
                    {f.status} · {f.path}
                    <%= if f.hunks != [] do %>
                      <ul class="text-zinc-500 ml-3 list-square">
                        <%= for o <- f.hunks do %>
                          <li>
                            proposal hunk @{elem(o.proposal.old_range, 0)},{elem(
                              o.proposal.old_range,
                              1
                            )} ↔ workspace @{elem(o.workspace.old_range, 0)},{elem(
                              o.workspace.old_range,
                              1
                            )}
                          </li>
                        <% end %>
                      </ul>
                    <% end %>
                  </li>
                <% end %>
              </ul>
            </div>
          <% end %>
        </div>
      <% end %>

      <%= if @p.status == :parsed do %>
        <div>
          <strong>Changed files in proposal:</strong>
          <ul class="font-mono ml-3 list-disc">
            <%= for c <- @p.changes do %>
              <li>{c.kind} · {c.path}</li>
            <% end %>
          </ul>
        </div>

        <div class="grid grid-cols-3 gap-2">
          <div>
            <strong class="block">In both</strong>
            <%= if @in_both == [] do %>
              <p class="text-zinc-400">—</p>
            <% else %>
              <ul class="font-mono">
                <%= for p <- @in_both do %>
                  <li class="truncate">{p}</li>
                <% end %>
              </ul>
            <% end %>
          </div>
          <div>
            <strong class="block">Proposal only</strong>
            <%= if @only_proposal == [] do %>
              <p class="text-zinc-400">—</p>
            <% else %>
              <ul class="font-mono">
                <%= for p <- @only_proposal do %>
                  <li class="truncate">{p}</li>
                <% end %>
              </ul>
            <% end %>
          </div>
          <div>
            <strong class="block">Workspace only</strong>
            <%= if @only_workspace == [] do %>
              <p class="text-zinc-400">—</p>
            <% else %>
              <ul class="font-mono">
                <%= for p <- @only_workspace do %>
                  <li class="truncate">{p}</li>
                <% end %>
              </ul>
            <% end %>
          </div>
        </div>

        <%= if @p.diff do %>
          <details>
            <summary class="cursor-pointer">unified diff preview</summary>
            <pre class="bg-zinc-950 text-zinc-100 p-2 rounded mt-1 overflow-auto max-h-72 whitespace-pre-wrap">{@p.diff}</pre>
          </details>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp analysis_class(:clean), do: "text-green-700"
  defp analysis_class(:overlap), do: "text-amber-700"
  defp analysis_class(:conflict), do: "text-red-700"
  defp analysis_class(_), do: "text-zinc-500"

  defp proposal_status_class(:parsed), do: "text-green-700"
  defp proposal_status_class(:invalid), do: "text-red-700"
  defp proposal_status_class(:too_large), do: "text-amber-700"
  defp proposal_status_class(_), do: "text-zinc-500"

  defp render_safety_card(assigns) do
    ~H"""
    <div class="border rounded p-3 bg-zinc-50">
      <h3 class="font-medium mb-2">Workspace safety</h3>
      <dl class="grid grid-cols-2 gap-y-1 text-xs">
        <dt class="text-zinc-500">mode</dt>
        <dd class="flex items-center gap-2">
          <span class="font-mono">{@workspace_mode}</span>
          <span class="text-zinc-500">({@workspace_mode_source})</span>
          <%= if can_set_mode?(@workspace_mode_source) do %>
            <.form for={%{}} phx-change="workspace:set_mode" class="inline-flex">
              <select name="mode" class="border rounded px-1 py-0 text-xs">
                <%= for m <- DevIDE.Policy.WorkspaceMode.valid_modes() do %>
                  <option value={Atom.to_string(m)} selected={m == @workspace_mode}>
                    {m}
                  </option>
                <% end %>
              </select>
            </.form>
          <% end %>
        </dd>
        <%= if @workspace_record && @workspace_record.last_seen_at do %>
          <dt class="text-zinc-500">last sync</dt>
          <dd class="font-mono text-[10px]">{DateTime.to_iso8601(@workspace_record.last_seen_at)}</dd>
        <% end %>
        <dt class="text-zinc-500">db isolation</dt>
        <dd>
          <span class={isolation_class(@db_isolation.isolation)}>{@db_isolation.isolation}</span>
          <%= if @db_isolation.source != :none do %>
            <span class="text-zinc-500">· {@db_isolation.source}</span>
          <% end %>
          <%= if @db_isolation.summary do %>
            <span class="font-mono text-zinc-700">· {@db_isolation.summary}</span>
          <% end %>
          <button phx-click="isolation:refresh" class="text-[10px] rounded border px-1 ml-1">
            ↻
          </button>
          <%= if @db_isolation.detected_at do %>
            <div class="text-[10px] text-zinc-400">
              at {DateTime.to_iso8601(@db_isolation.detected_at)}
            </div>
          <% end %>
        </dd>
        <dt class="text-zinc-500">agent write</dt>
        <dd>
          <span class="text-red-700">disabled</span>
          <span class="text-zinc-500">
            — {agent_write_reason_full(@workspace_mode, @db_isolation.isolation)}
          </span>
        </dd>
        <dt class="text-zinc-500">proposal apply</dt>
        <dd>
          <span class="text-red-700">disabled</span>
          <span class="text-zinc-500">— not implemented</span>
        </dd>
        <%= if @last_decision do %>
          <dt class="text-zinc-500">last decision</dt>
          <dd class="font-mono text-zinc-700">
            {@last_decision.action} · {@last_decision.verdict}
            {if @last_decision.reason, do: "· " <> Atom.to_string(@last_decision.reason)}
          </dd>
        <% end %>
      </dl>
      <%= if @audit_events != [] do %>
        <p class="text-[11px] text-zinc-500 mt-2">
          {length(@audit_events)} audit events ·
          <button phx-click="audit_drawer:toggle" class="underline hover:text-zinc-800">
            open evidence
          </button>
        </p>
      <% end %>
    </div>
    """
  end

  defp agent_write_reason_full(_mode, :shared_stage), do: "shared Stage DB; refused by policy"
  defp agent_write_reason_full(_mode, :unsafe), do: "DB target looks unsafe; refused by policy"
  defp agent_write_reason_full(:shared_stage_guarded, _), do: "shared Stage DB; refused by policy"
  defp agent_write_reason_full(_, _), do: "agent write locked"

  defp isolation_class(:shared_stage), do: "text-red-700 font-mono"
  defp isolation_class(:unsafe), do: "text-red-700 font-mono"
  defp isolation_class(:ephemeral), do: "text-green-700 font-mono"
  defp isolation_class(:local), do: "text-amber-700 font-mono"
  defp isolation_class(_), do: "text-zinc-500 font-mono"

  defp cap_label(:opencode), do: "OpenCode"
  defp cap_label(:tidewave), do: "Tidewave MCP"
  defp cap_label(:fff), do: "FFF MCP"
  defp cap_label(:browser_artifacts), do: "Browser artifacts"
  defp cap_label(:transcripts), do: "Transcripts"
  defp cap_label(other), do: to_string(other)

  defp cap_status_class(:detected), do: "text-green-700 text-xs"
  defp cap_status_class(:missing), do: "text-zinc-400 text-xs"

  defp render_logs(assigns) do
    ~H"""
    <section class="space-y-2">
      <.form for={%{}} phx-change="set_log_service" class="flex gap-2 items-center">
        <label class="text-sm">Service</label>
        <input name="service" value={@log_service} class="border rounded px-2 py-1 text-sm font-mono" />
      </.form>
      <%= if is_nil(@log_ref) do %>
        <p class="text-xs text-amber-700">
          Log stream unavailable (manager unreachable or service not started).
        </p>
      <% end %>
      <pre class="bg-zinc-950 text-zinc-100 text-xs p-3 rounded h-[60vh] overflow-auto"><%=
        @log_lines |> Enum.reverse() |> Enum.join("\n")
      %></pre>
    </section>
    """
  end

  defp render_path({:ok, cwd}), do: cwd
  defp render_path({:error, :missing_path}), do: "(no host path)"
  defp render_path({:error, :outside_root}), do: "(path outside allowed roots)"

  defp tab_class(current, current), do: "px-3 py-1.5 rounded bg-zinc-900 text-white"
  defp tab_class(_, _), do: "px-3 py-1.5 rounded border"

  defp terminal_mode_class(current, current),
    do: "rounded bg-zinc-900 text-white px-2 py-0.5 border border-zinc-900"

  defp terminal_mode_class(_, _),
    do: "rounded border border-zinc-300 px-2 py-0.5 hover:bg-zinc-50"

  defp raw_terminal_allowed?(:manual, host_id), do: host_id in ["local", "localhost"]
  defp raw_terminal_allowed?(_, _), do: false

  defp maybe_reset_terminal_mode(
         %{assigns: %{terminal_mode: :raw, workspace_mode: mode, host_id: host_id}} = socket
       ) do
    if raw_terminal_allowed?(mode, host_id),
      do: socket,
      else: assign(socket, :terminal_mode, :governed)
  end

  defp maybe_reset_terminal_mode(socket), do: socket

  defp decision_for_command(socket, command_id) do
    ctx = policy_ctx(socket, %{command_id: command_id})
    Policy.can_run_command?(ctx)
  end
end
