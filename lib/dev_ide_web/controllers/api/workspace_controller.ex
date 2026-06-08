defmodule DevIdeWeb.API.WorkspaceController do
  use DevIdeWeb, :controller

  alias DevIDE.Audit
  alias DevIDE.Commands.Rerun
  alias DevIDE.Export
  alias DevIDE.Files.PathSafety
  alias DevIDE.Runners
  alias DevIDE.Terminals.SessionTemplate
  alias DevIDE.Terminals.Templates
  alias DevIDE.Terminals.Tmux
  alias DevIDE.Terminals.TmuxTopology
  alias DevIDE.Workspaces.State

  def index(conn, _params), do: json(conn, Export.list_summary())

  def status(conn, %{"id" => id}) do
    case Export.status(id) do
      {:ok, payload} -> json(conn, payload)
      :error -> not_found(conn)
    end
  end

  def runs(conn, %{"id" => id}) do
    case Export.runs(id) do
      {:ok, list} -> json(conn, list)
      :error -> not_found(conn)
    end
  end

  def topology(conn, %{"id" => id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn) do
      json(conn, topology_payload(id, session))
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def templates(conn, %{"id" => id}) do
    case Export.status(id) do
      {:ok, _status} ->
        built_in = Enum.map(SessionTemplate.list(), &built_in_template_payload/1)
        saved = Enum.map(Templates.list_for_workspace(id), &saved_template_list_payload/1)

        json(conn, built_in ++ saved)

      :error ->
        not_found(conn)
    end
  end

  def export_template(conn, %{"id" => id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn),
         topology <- TmuxTopology.snapshot(session, tmux: tmux_adapter()),
         {:ok, template} <-
           SessionTemplate.export_topology(topology,
             workspace_root: workspace_root_for_export(id),
             name: param(conn, "name")
           ) do
      json(conn, %{
        workspace_id: id,
        session: session,
        template: template,
        yaml: DevIDE.Terminals.SessionTemplate.Export.to_yaml(template)
      })
    else
      :error -> not_found(conn)
      {:error, :empty_topology} -> rejected(conn, :unprocessable_entity, "empty_topology")
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def save_template(conn, %{"id" => id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn),
         topology <- TmuxTopology.snapshot(session, tmux: tmux_adapter()),
         {:ok, template} <-
           SessionTemplate.export_topology(topology,
             workspace_root: workspace_root_for_export(id),
             name: param(conn, "name")
           ) do
      save_template_response(conn, id, session, topology, template)
    else
      :error -> not_found(conn)
      {:error, :empty_topology} -> rejected(conn, :unprocessable_entity, "empty_topology")
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def apply_template(conn, %{"id" => id, "template_id" => template_id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn) do
      apply_template_mutation(conn, id, session, template_id)
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def delete_template(conn, %{"id" => id, "template_id" => template_id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, saved} <- Templates.get(id, template_id),
         :ok <- Templates.delete(id, template_id) do
      emit_tmux_template_deleted_audit(id, saved)

      json(conn, %{
        action: "template_deleted",
        workspace_id: id,
        template_id: template_id
      })
    else
      :error -> not_found(conn)
      {:error, :not_found} -> rejected(conn, :not_found, "template_not_found")
    end
  end

  def create_window(conn, %{"id" => id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn),
         {:ok, opts} <- window_create_opts(conn, id) do
      mutate_window(conn, id, session, "window_created", fn ->
        tmux_adapter().new_window(session, opts)
      end)
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def select_window(conn, %{"id" => id, "window_id" => window_id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn) do
      mutate_window(conn, id, session, "window_selected", fn ->
        case find_window(session, window_id) do
          nil -> {:error, :window_not_found}
          _window -> tmux_adapter().select_window(session, window_id)
        end
      end)
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def rename_window(conn, %{"id" => id, "window_id" => window_id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn),
         {:ok, name} <- required_trimmed_param(conn, "name", "name_required") do
      mutate_window(conn, id, session, "window_renamed", fn ->
        case find_window(session, window_id) do
          nil -> {:error, :window_not_found}
          %{name: ^name} -> :ok
          _window -> tmux_adapter().rename_window(session, window_id, name)
        end
      end)
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def kill_window(conn, %{"id" => id, "window_id" => window_id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn) do
      mutate_window(conn, id, session, "window_killed", fn ->
        case find_window(session, window_id) do
          nil -> {:error, :window_not_found}
          _window -> tmux_adapter().kill_window(session, window_id)
        end
      end)
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def create_pane(conn, %{"id" => id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn),
         {:ok, pane_id} <- pane_target_param(conn),
         {:ok, direction} <- pane_split_direction(conn) do
      split_pane_mutation(conn, id, session, pane_id, direction)
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def select_pane(conn, %{"id" => id, "pane_id" => pane_id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn) do
      mutate_pane(conn, id, session, "pane_selected", fn ->
        case find_pane(session, pane_id) do
          nil -> {:error, :pane_not_found}
          %{active: true} -> :ok
          _pane -> tmux_adapter().select_pane(session, pane_id)
        end
      end)
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def split_pane(conn, %{"id" => id, "pane_id" => pane_id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn),
         {:ok, direction} <- pane_split_direction(conn) do
      split_pane_mutation(conn, id, session, pane_id, direction)
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def resize_pane(conn, %{"id" => id, "pane_id" => pane_id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn),
         {:ok, direction} <- pane_resize_direction(conn),
         {:ok, amount} <- pane_resize_amount(conn) do
      mutate_pane(conn, id, session, "pane_resized", fn ->
        case find_pane(session, pane_id) do
          nil -> {:error, :pane_not_found}
          _pane -> tmux_adapter().resize_pane(session, pane_id, direction, amount)
        end
      end)
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def kill_pane(conn, %{"id" => id, "pane_id" => pane_id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn) do
      mutate_pane(conn, id, session, "pane_killed", fn ->
        case find_pane(session, pane_id) do
          nil -> {:error, :pane_not_found}
          _pane -> tmux_adapter().kill_pane(session, pane_id)
        end
      end)
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def run(conn, %{"id" => id, "run_id" => run_id}) do
    case Export.run(id, run_id) do
      {:ok, payload} -> json(conn, payload)
      :error -> not_found(conn)
    end
  end

  def create_run(conn, %{"id" => id, "command_id" => command_id}) when is_binary(command_id) do
    if Map.get(conn.params, "execution_protocol") == Runners.protocol() do
      create_runner_assignment(conn, id, command_id)
    else
      create_immediate_run(conn, id, command_id)
    end
  end

  def create_run(conn, _params), do: rejected(conn, :bad_request, "command_id_required")

  defp create_immediate_run(conn, id, command_id) do
    case Rerun.start(id, command_id, correlation_id: correlation_id(conn)) do
      {:ok, run} -> conn |> put_status(:created) |> json(run)
      {:error, :not_found} -> not_found(conn)
      {:error, :not_allowed} -> rejected(conn, :bad_request, "command_not_allowed")
      {:error, :shared_stage_guarded} -> rejected(conn, :forbidden, "unsafe_db_isolation")
      {:error, :unsafe_db} -> rejected(conn, :forbidden, "unsafe_db_isolation")
      {:error, :no_root} -> rejected(conn, :unprocessable_entity, "workspace_root_unavailable")
      {:error, :already_running} -> rejected(conn, :conflict, "command_already_running")
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  defp create_runner_assignment(conn, id, command_id) do
    with {:ok, metadata} <- validated_runner_metadata(conn, id, command_id),
         {:ok, assignment} <-
           Runners.enqueue_command(id, command_id,
             requested_by: "jx",
             metadata: metadata
           ) do
      conn
      |> put_status(:created)
      |> json(%{
        protocol: Runners.protocol(),
        assignment: Runners.assignment_payload(assignment)
      })
    else
      {:error, :not_found} ->
        not_found(conn)

      {:error, :safe_action_not_allowed} ->
        rejected(conn, :bad_request, "command_not_allowed")

      {:error, :shared_stage_guarded} ->
        rejected(conn, :forbidden, "unsafe_db_isolation")

      {:error, :unsafe_db} ->
        rejected(conn, :forbidden, "unsafe_db_isolation")

      {:error, reason} ->
        rejected(conn, :unprocessable_entity, reason)
    end
  end

  defp validated_runner_metadata(conn, workspace_id, command_id) do
    with {:ok, runtime} <- safe_runtime_request(workspace_id, runtime_request(conn)),
         {:ok, routing} <- safe_routing_requirements(workspace_id, routing_requirements(conn)) do
      {:ok, runner_assignment_metadata(conn, command_id, runtime, routing)}
    end
  end

  defp runner_assignment_metadata(conn, command_id, runtime, routing) do
    %{
      source: "api",
      trigger: "jx",
      protocol: Runners.protocol(),
      command_id: command_id,
      correlation_id: correlation_id(conn),
      jx_assignment_id: param(conn, "jx_assignment_id"),
      jx_action_id: param(conn, "jx_action_id"),
      jx_safe_action_kind: param(conn, "jx_safe_action_kind"),
      runtime: runtime,
      routing: routing
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", %{}] end)
    |> Map.new()
  end

  defp safe_runtime_request(workspace_id, request) do
    safe_path_fields(workspace_id, request, ["runtime_path", "worktree_path"])
  end

  defp safe_routing_requirements(workspace_id, requirements) do
    safe_path_fields(workspace_id, requirements, ["runtime_path"])
  end

  defp safe_path_fields(workspace_id, map, keys) do
    Enum.reduce_while(keys, {:ok, map}, fn key, {:ok, acc} ->
      case Map.get(acc, key) do
        nil ->
          {:cont, {:ok, acc}}

        "" ->
          {:cont, {:ok, acc}}

        path ->
          case resolve_workspace_path(workspace_id, path) do
            {:ok, resolved} -> {:cont, {:ok, Map.put(acc, key, resolved)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp routing_requirements(conn) do
    requirements =
      case Map.get(conn.params, "runner_requirements") do
        map when is_map(map) -> map
        _ -> %{}
      end

    %{
      "host" => string_param(requirements, "host"),
      "os" => string_param(requirements, "os"),
      "repo" => string_param(requirements, "repo"),
      "branch_isolation" => string_param(requirements, "branch_isolation"),
      "runtime_id" => string_param(requirements, "runtime_id"),
      "runtime_path" => string_param(requirements, "runtime_path"),
      "tools" => string_list_param(requirements, "tools")
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  defp runtime_request(conn) do
    request =
      case Map.get(conn.params, "runtime") || Map.get(conn.params, "runtime_request") do
        map when is_map(map) -> map
        _ -> %{}
      end

    %{
      "runtime_id" => string_param(request, "runtime_id"),
      "runtime_path" => string_param(request, "runtime_path"),
      "worktree_path" => string_param(request, "worktree_path"),
      "host" => string_param(request, "host"),
      "host_id" => string_param(request, "host_id"),
      "os" => string_param(request, "os"),
      "repo" => string_param(request, "repo"),
      "branch" => string_param(request, "branch"),
      "branch_isolation" => string_param(request, "branch_isolation"),
      "isolation_mode" => string_param(request, "isolation_mode"),
      "tmux_session_id" => string_param(request, "tmux_session_id"),
      "session_id" => string_param(request, "session_id"),
      "tools" => string_list_param(request, "tools"),
      "capabilities" => string_list_param(request, "capabilities"),
      "concurrency_limit" => int_param(request, "concurrency_limit")
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp correlation_id(conn) do
    conn
    |> Plug.Conn.get_req_header("x-jx-correlation-id")
    |> List.first()
    |> case do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp param(conn, key) do
    case Map.get(conn.params, key) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp string_param(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp topology_session(conn) do
    case param(conn, "session") || param(conn, "tmux_session") do
      nil -> {:error, "session_required"}
      "" -> {:error, "session_required"}
      session -> {:ok, session}
    end
  end

  defp mutate_window(conn, workspace_id, session, action, fun) do
    if dry_run?(conn) do
      json(conn, %{
        action: action,
        dry_run: true,
        topology: topology_payload(workspace_id, session)
      })
    else
      case fun.() do
        :ok ->
          json(conn, mutation_payload(conn, workspace_id, session, action))

        {:ok, window_id} ->
          json(
            conn,
            mutation_payload(conn, workspace_id, session, action, %{window_id: window_id})
          )

        {:error, :window_not_found} ->
          rejected(conn, :not_found, "window_not_found")

        {:error, reason} ->
          rejected(conn, :unprocessable_entity, reason)
      end
    end
  end

  defp mutate_pane(conn, workspace_id, session, action, fun) do
    if dry_run?(conn) do
      json(conn, %{
        action: action,
        dry_run: true,
        topology: topology_payload(workspace_id, session)
      })
    else
      case fun.() do
        :ok ->
          json(conn, pane_mutation_payload(conn, workspace_id, session, action))

        {:ok, pane_id} ->
          json(
            conn,
            pane_mutation_payload(conn, workspace_id, session, action, %{pane_id: pane_id})
          )

        {:error, :pane_not_found} ->
          rejected(conn, :not_found, "pane_not_found")

        {:error, reason} ->
          rejected(conn, :unprocessable_entity, reason)
      end
    end
  end

  defp split_pane_mutation(conn, workspace_id, session, pane_id, direction) do
    mutate_pane(conn, workspace_id, session, "pane_split", fn ->
      case find_pane(session, pane_id) do
        nil -> {:error, :pane_not_found}
        _pane -> tmux_adapter().split_pane(session, pane_id, direction)
      end
    end)
  end

  defp apply_template_mutation(conn, workspace_id, session, template_id) do
    if dry_run?(conn) do
      case dry_run_template(workspace_id, template_id) do
        {:ok, result} ->
          json(conn, %{
            action: "template_applied",
            dry_run: true,
            result: result,
            topology: topology_payload(workspace_id, session)
          })

        {:error, :template_not_found} ->
          rejected(conn, :not_found, "template_not_found")

        {:error, reason} ->
          rejected(conn, :unprocessable_entity, reason)
      end
    else
      with {:ok, root} <- workspace_root(workspace_id),
           {:ok, result} <-
             execute_template(workspace_id, session, template_id, root) do
        json(conn, template_mutation_payload(conn, workspace_id, session, template_id, result))
      else
        {:error, :template_not_found} ->
          rejected(conn, :not_found, "template_not_found")

        {:error, {reason, step, partial}} ->
          template_step_error(conn, reason, step, partial)

        {:error, reason} ->
          rejected(conn, :unprocessable_entity, reason)
      end
    end
  end

  defp dry_run_template(workspace_id, template_id) do
    case SessionTemplate.dry_run(template_id) do
      {:ok, result} ->
        {:ok, result}

      {:error, :template_not_found} ->
        Templates.dry_run(workspace_id, template_id)

      {:error, _reason} = error ->
        error
    end
  end

  defp execute_template(workspace_id, session, template_id, root) do
    opts = [tmux: tmux_adapter(), workspace_root: root]

    case SessionTemplate.execute(session, template_id, opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, :template_not_found} ->
        Templates.execute(workspace_id, session, template_id, opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp mutation_payload(conn, workspace_id, session, action, result \\ %{}) do
    _ = TmuxTopology.configure(session, workspace_id: workspace_id)
    _ = TmuxTopology.refresh(session)
    topology = topology_payload(workspace_id, session)
    emit_tmux_window_audit(conn, workspace_id, session, action, result, topology)

    %{
      action: action,
      dry_run: false,
      result: result,
      topology: topology
    }
  end

  defp pane_mutation_payload(conn, workspace_id, session, action, result \\ %{}) do
    _ = TmuxTopology.configure(session, workspace_id: workspace_id)
    _ = TmuxTopology.refresh(session)
    topology = topology_payload(workspace_id, session)
    emit_tmux_pane_audit(conn, workspace_id, session, action, result, topology)

    %{
      action: action,
      dry_run: false,
      result: result,
      topology: topology
    }
  end

  defp template_mutation_payload(conn, workspace_id, session, template_id, result) do
    _ = TmuxTopology.configure(session, workspace_id: workspace_id)
    _ = TmuxTopology.refresh(session)
    topology = topology_payload(workspace_id, session)
    emit_tmux_template_audit(conn, workspace_id, session, template_id, result, topology)

    %{
      action: "template_applied",
      dry_run: false,
      result: result,
      topology: topology
    }
  end

  defp save_template_response(conn, workspace_id, session, topology, template) do
    yaml = DevIDE.Terminals.SessionTemplate.Export.to_yaml(template)

    if dry_run?(conn) do
      json(conn, %{
        action: "template_exported",
        dry_run: true,
        workspace_id: workspace_id,
        session: session,
        template: template,
        yaml: yaml,
        topology: topology_payload(workspace_id, session)
      })
    else
      case Templates.save(%{
             workspace_id: workspace_id,
             name: template["name"],
             description: param(conn, "description"),
             body: template,
             source_session: session,
             schema_version: template["version"] || 2
           }) do
        {:ok, saved} ->
          saved_payload = saved_template_detail_payload(saved)
          emit_tmux_template_exported_audit(conn, workspace_id, session, saved, topology)

          conn
          |> put_status(:created)
          |> json(%{
            action: "template_exported",
            dry_run: false,
            workspace_id: workspace_id,
            session: session,
            result: saved_payload,
            saved_template: saved_payload,
            template: template,
            yaml: yaml,
            topology: topology_payload(workspace_id, session)
          })

        {:error, %Ecto.Changeset{} = changeset} ->
          rejected(conn, :unprocessable_entity, changeset_error(changeset))

        {:error, reason} ->
          rejected(conn, :unprocessable_entity, reason)
      end
    end
  end

  defp topology_payload(workspace_id, session) do
    topology = TmuxTopology.snapshot(session, tmux: tmux_adapter())

    %{
      workspace_id: workspace_id,
      session: topology.session,
      active_window_id: topology.active_window_id,
      active_pane_id: topology.active_pane_id,
      version: topology.version,
      windows: topology.windows,
      panes: topology.panes
    }
  end

  defp find_window(session, window_id) do
    session
    |> TmuxTopology.snapshot(tmux: tmux_adapter())
    |> Map.fetch!(:windows)
    |> Enum.find(&(&1.id == window_id or to_string(&1.index) == window_id))
  end

  defp find_pane(session, pane_id) do
    session
    |> TmuxTopology.snapshot(tmux: tmux_adapter())
    |> Map.fetch!(:panes)
    |> Enum.find(&(&1.id == pane_id or to_string(&1.index) == pane_id))
  end

  defp window_create_opts(conn, workspace_id) do
    with {:ok, cwd} <- resolve_window_cwd(workspace_id, param(conn, "cwd")) do
      {:ok,
       []
       |> maybe_put_opt(:name, param(conn, "name"))
       |> maybe_put_opt(:cwd, cwd)}
    end
  end

  defp resolve_window_cwd(workspace_id, cwd), do: resolve_workspace_path(workspace_id, cwd)

  defp resolve_workspace_path(_workspace_id, nil), do: {:ok, nil}
  defp resolve_workspace_path(_workspace_id, ""), do: {:ok, nil}

  defp resolve_workspace_path(workspace_id, path) do
    with {:ok, %{host_path: root}} when is_binary(root) <- State.get(workspace_id),
         {:ok, resolved} <- PathSafety.resolve(root, path) do
      {:ok, resolved}
    else
      :error -> {:error, :workspace_root_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp workspace_root(workspace_id) do
    case State.get(workspace_id) do
      {:ok, %{host_path: root}} when is_binary(root) -> {:ok, root}
      {:ok, _} -> {:error, :workspace_root_unavailable}
      :error -> {:error, :workspace_root_unavailable}
    end
  end

  defp workspace_root_for_export(workspace_id) do
    case workspace_root(workspace_id) do
      {:ok, root} -> root
      {:error, _reason} -> nil
    end
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, _key, ""), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp required_trimmed_param(conn, key, error) do
    case param(conn, key) do
      nil -> {:error, error}
      "" -> {:error, error}
      value -> {:ok, value}
    end
  end

  defp pane_target_param(conn) do
    case param(conn, "pane_id") || param(conn, "target_pane_id") do
      nil -> {:error, "pane_id_required"}
      "" -> {:error, "pane_id_required"}
      value -> {:ok, value}
    end
  end

  defp pane_split_direction(conn) do
    case param(conn, "direction") do
      direction when direction in ["h", "v"] -> {:ok, direction}
      _ -> {:error, :invalid_direction}
    end
  end

  defp pane_resize_direction(conn) do
    case param(conn, "direction") do
      direction when direction in ["left", "right", "up", "down"] -> {:ok, direction}
      _ -> {:error, :invalid_direction}
    end
  end

  defp pane_resize_amount(conn) do
    case Map.get(conn.params, "amount") do
      nil -> {:ok, Tmux.resize_amount_default()}
      value -> parse_resize_amount(value)
    end
  end

  defp parse_resize_amount(value) when is_integer(value), do: validate_resize_amount(value)

  defp parse_resize_amount(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {amount, ""} -> validate_resize_amount(amount)
      _ -> {:error, :invalid_amount}
    end
  end

  defp parse_resize_amount(_), do: {:error, :invalid_amount}

  defp validate_resize_amount(value) when is_integer(value) and value > 0 do
    if value <= Tmux.resize_amount_max() do
      {:ok, value}
    else
      {:error, :invalid_amount}
    end
  end

  defp validate_resize_amount(_), do: {:error, :invalid_amount}

  defp dry_run?(conn) do
    Map.get(conn.params, "dry_run") in [true, "true", "1"]
  end

  defp emit_tmux_window_audit(conn, workspace_id, session, action, result, topology) do
    window_id =
      Map.get(result, :window_id) ||
        Map.get(result, "window_id") ||
        param(conn, "window_id") ||
        topology.active_window_id

    Audit.emit!(%{
      action: "tmux." <> action,
      workspace_id: workspace_id,
      actor_id: "api",
      target_type: "tmux_window",
      target_ref: window_id,
      metadata: %{
        session: session,
        window_id: window_id,
        active_window_id: topology.active_window_id,
        active_pane_id: topology.active_pane_id,
        topology_version: topology.version,
        dry_run: false
      }
    })
  end

  defp emit_tmux_pane_audit(conn, workspace_id, session, action, result, topology) do
    pane_id =
      Map.get(result, :pane_id) ||
        Map.get(result, "pane_id") ||
        param(conn, "pane_id") ||
        topology.active_pane_id

    Audit.emit!(%{
      action: "tmux." <> action,
      workspace_id: workspace_id,
      actor_id: "api",
      target_type: "tmux_pane",
      target_ref: pane_id,
      metadata: %{
        session: session,
        pane_id: pane_id,
        active_window_id: topology.active_window_id,
        active_pane_id: topology.active_pane_id,
        topology_version: topology.version,
        dry_run: false
      }
    })
  end

  defp emit_tmux_template_audit(_conn, workspace_id, session, template_id, result, topology) do
    template = Map.get(result, :template, %{})

    Audit.emit!(%{
      action: "tmux.template_applied",
      workspace_id: workspace_id,
      actor_id: "api",
      target_type: "tmux_template",
      target_ref: template_id,
      metadata: %{
        session: session,
        template_id: template_id,
        template_source: template_source(template),
        schema_version: template_schema_version(template),
        step_count: result.step_count,
        refs: result.refs,
        active_window_id: topology.active_window_id,
        active_pane_id: topology.active_pane_id,
        topology_version: topology.version,
        dry_run: false
      }
    })
  end

  defp emit_tmux_template_exported_audit(_conn, workspace_id, session, saved, topology) do
    Audit.emit!(%{
      action: "tmux.template_exported",
      workspace_id: workspace_id,
      actor_id: "api",
      target_type: "tmux_template",
      target_ref: saved.id,
      metadata: %{
        session: session,
        template_id: saved.id,
        template_name: saved.name,
        schema_version: saved.schema_version,
        active_window_id: topology.active_window_id,
        active_pane_id: topology.active_pane_id,
        topology_version: topology.version,
        dry_run: false
      }
    })
  end

  defp emit_tmux_template_deleted_audit(workspace_id, saved) do
    Audit.emit!(%{
      action: "tmux.template_deleted",
      workspace_id: workspace_id,
      actor_id: "api",
      target_type: "tmux_template",
      target_ref: saved.id,
      metadata: %{
        template_id: saved.id,
        template_name: saved.name,
        schema_version: saved.schema_version,
        dry_run: false
      }
    })
  end

  defp built_in_template_payload(%SessionTemplate{} = template) do
    %{
      id: template.id,
      name: template.name,
      description: template.description,
      source: "built_in",
      schema_version: 1,
      apply_supported: true,
      windows: length(template.windows),
      panes:
        length(template.windows) +
          (template.windows
           |> Enum.map(&length(&1.panes))
           |> Enum.sum())
    }
  end

  defp saved_template_list_payload(saved) do
    body = saved.body || %{}
    windows = Map.get(body, "windows", [])

    %{
      id: saved.id,
      name: saved.name,
      description: saved.description,
      source: "exported",
      schema_version: saved.schema_version,
      apply_supported: Templates.apply_supported?(saved),
      source_session: saved.source_session,
      windows: length(windows),
      panes: Enum.map(windows, &layout_pane_count(Map.get(&1, "layout", %{}))) |> Enum.sum(),
      inserted_at: saved.inserted_at,
      updated_at: saved.updated_at
    }
  end

  defp saved_template_detail_payload(saved) do
    saved
    |> saved_template_list_payload()
    |> Map.put(:workspace_id, saved.workspace_id)
  end

  defp layout_pane_count(%{"panes" => panes}) when is_list(panes) do
    case panes do
      [] -> 1
      _ -> Enum.map(panes, &layout_pane_count/1) |> Enum.sum()
    end
  end

  defp layout_pane_count(_layout), do: 1

  defp template_source(%{source: source}) when is_binary(source), do: source
  defp template_source(%{"source" => source}) when is_binary(source), do: source
  defp template_source(_template), do: "built_in"

  defp template_schema_version(%{schema_version: version}) when is_integer(version), do: version

  defp template_schema_version(%{"schema_version" => version}) when is_integer(version),
    do: version

  defp template_schema_version(_template), do: 1

  defp template_step_error(conn, reason, step, partial) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "template_step_failed",
      reason: inspect(reason),
      step: step,
      partial_result: partial
    })
  end

  defp string_list_param(map, key) do
    case Map.get(map, key) do
      values when is_list(values) ->
        values
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp int_param(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def proposals(conn, %{"id" => id}) do
    case Export.proposals(id) do
      {:ok, list} -> json(conn, list)
      :error -> not_found(conn)
    end
  end

  def audit(conn, %{"id" => id}) do
    case Export.audit(id) do
      {:ok, list} -> json(conn, list)
      :error -> not_found(conn)
    end
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not_found"})
  end

  defp rejected(conn, status, reason) do
    conn
    |> put_status(status)
    |> json(%{error: to_string(reason)})
  end

  defp changeset_error(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map(fn {field, messages} -> "#{field}: #{Enum.join(messages, ", ")}" end)
    |> Enum.join("; ")
  end

  defp tmux_adapter do
    Application.get_env(:dev_ide, :tmux_adapter, Tmux)
  end
end
