defmodule Casein.Desktop.PowerShellSession do
  @moduledoc """
  Application-owned PowerShell session used by the native Windows desktop UI.

  The session supervises independently owned native panes so browser reconnects
  retain product topology while each pane keeps its own ConPTY process tree.
  """

  use GenServer

  alias Casein.Desktop.{NativeAgentLaunch, PowerShellPane}
  alias Casein.Terminals.SessionTemplate

  @name __MODULE__
  @registry Module.concat(__MODULE__, Registry)
  @supervisor Module.concat(__MODULE__, Supervisor)
  @default_cols 100
  @default_rows 30
  @pane_roles ~w(operator agent verify preview)

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, Keyword.delete(opts, :name), name: name)
  end

  def child_spec(opts) do
    workspace = Keyword.get(opts, :workspace)

    %{
      id: {__MODULE__, workspace_key(workspace)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }
  end

  @doc "Ensures the desktop shell is supervised in the selected workspace."
  def ensure_started(cwd \\ nil, workspace \\ nil) do
    cwd = normalize_cwd(cwd)
    target = server(workspace)

    case resolve(target) do
      nil ->
        opts = [cwd: cwd, workspace: workspace, name: target]
        supervisor = if Process.whereis(@supervisor), do: @supervisor, else: Casein.Supervisor

        case Supervisor.start_child(supervisor, {__MODULE__, opts}) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, :already_present} -> :ok
          {:error, reason} -> {:error, reason}
        end

      pid ->
        GenServer.call(pid, {:ensure_workspace, cwd, workspace})
    end
  end

  @doc "Subscribes the caller and returns the active pane emulator and process handles."
  def subscribe(workspace \\ nil) do
    GenServer.call(server(workspace), {:subscribe, self()})
  end

  def status(workspace \\ nil), do: GenServer.call(server(workspace), :status)

  @doc "Returns the product-level topology for one native Windows session."
  def topology(workspace \\ nil), do: GenServer.call(server(workspace), :topology)

  @doc "Creates one native window with a single owned pane."
  def create_window(workspace \\ nil, opts \\ []) do
    GenServer.call(server(workspace), {:create_window, opts})
  end

  @doc "Creates one native pane under a validated window."
  def create_pane(workspace, window_id, opts \\ [])
      when is_binary(window_id) and is_list(opts) do
    GenServer.call(server(workspace), {:create_pane, window_id, opts})
  end

  @doc "Focuses a validated native pane and its parent window."
  def focus_pane(workspace, pane_id) when is_binary(pane_id) do
    GenServer.call(server(workspace), {:focus_pane, pane_id})
  end

  @doc "Closes a validated native pane and its complete ConPTY process tree."
  def close_pane(workspace, pane_id) when is_binary(pane_id) do
    GenServer.call(server(workspace), {:close_pane, pane_id})
  end

  @doc """
  Applies a built-in session template onto the native multipane topology.

  Uses the same dry-run plan as tmux (`SessionTemplate.dry_run/2`), but executes
  against owned `PowerShellPane` processes. The first `new_window` step adopts the
  existing default native window when the session still has a single root pane so
  `agent_pair` does not leave a spare empty PowerShell window.
  """
  def apply_template(workspace \\ nil, template_or_id, opts \\ [])

  def apply_template(workspace, template_or_id, opts)
      when (is_binary(template_or_id) or is_map(template_or_id)) and is_list(opts) do
    GenServer.call(server(workspace), {:apply_template, template_or_id, opts}, 30_000)
  end

  def apply_template(_workspace, _template_or_id, _opts), do: {:error, :invalid_arguments}

  @doc "Returns retained raw terminal output for a validated native pane target."
  def capture(workspace, pane_id), do: GenServer.call(server(workspace), {:capture, pane_id})

  @doc "Resizes a validated native pane and its ConPTY transport."
  def resize(workspace, pane_id, cols, rows),
    do: GenServer.call(server(workspace), {:resize, pane_id, cols, rows})

  @doc "Assigns a product role to a validated native pane target."
  def set_pane_role(workspace, pane_id, role),
    do: GenServer.call(server(workspace), {:set_pane_role, pane_id, role})

  @doc "Writes terminal input to the focused native pane."
  def send_input(workspace, data) when is_binary(data) do
    GenServer.call(server(workspace), {:input, data})
  end

  @doc "Writes terminal input only when the native pane target is current."
  def send_input(workspace, pane_id, data) when is_binary(pane_id) and is_binary(data) do
    GenServer.call(server(workspace), {:input, pane_id, data})
  end

  @doc "Launches one provider and returns its retained plan with native topology."
  @spec launch_agent(map(), String.t(), String.t(), keyword()) ::
          {:ok, %{plan: NativeAgentLaunch.t(), topology: map()}} | {:error, term()}
  def launch_agent(workspace, runtime, task, opts \\ [])

  def launch_agent(workspace, runtime, task, opts)
      when is_map(workspace) and is_binary(runtime) and is_binary(task) and is_list(opts) do
    launcher = Keyword.get(opts, :launcher, &NativeAgentLaunch.launch/4)
    topology_reporter = Keyword.get(opts, :topology_reporter, &record_agent_launch/1)
    finisher = Keyword.get(opts, :finisher, &NativeAgentLaunch.finish/4)

    case launcher.(workspace, runtime, task, Keyword.get(opts, :launch_opts, [])) do
      {:ok, %NativeAgentLaunch{} = plan} ->
        case topology_reporter.(workspace) do
          {:ok, topology} ->
            {:ok, %{plan: plan, topology: topology}}

          {:error, reason} ->
            topology_failure(plan, runtime, reason, finisher, opts)

          {:topology_error, reason} ->
            topology_failure(plan, runtime, reason, finisher, opts)

          _other ->
            topology_failure(plan, runtime, :invalid_topology_report, finisher, opts)
        end

      {:error, _reason} = error ->
        error
    end
  end

  def launch_agent(_workspace, _runtime, _task, _opts), do: {:error, :invalid_arguments}

  @doc "Restarts the native shell topology in the given workspace directory."
  def restart(cwd \\ nil, workspace \\ nil),
    do: GenServer.call(server(workspace), {:restart, normalize_cwd(cwd), workspace})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    cwd = Keyword.fetch!(opts, :cwd)
    workspace = Keyword.get(opts, :workspace)
    ids = topology_ids(workspace)

    state = %{
      cwd: cwd,
      workspace: workspace,
      subscribers: %{},
      status: :running,
      ids: ids,
      windows: [],
      panes: %{},
      pane_monitors: %{},
      active_window_id: nil,
      active_pane_id: nil,
      window_seq: 0,
      pane_seq: 0,
      pane_opts: pane_start_opts(opts)
    }

    case open_window(state, name: "PowerShell", role: "operator", active?: true) do
      {:ok, _window, _pane, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    state = monitor_subscriber(state, pid)

    case active_handles(state) do
      {:ok, term, pty, status} -> {:reply, {:ok, term, pty, status}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(:topology, _from, state), do: {:reply, topology_snapshot(state), state}

  def handle_call({:create_window, opts}, _from, state) do
    case open_window(state, opts) do
      {:ok, window, pane, state} ->
        {:reply, {:ok, %{window: window, pane: pane, topology: topology_snapshot(state)}}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:create_pane, window_id, opts}, _from, state) do
    case open_pane(state, window_id, opts) do
      {:ok, pane, state} ->
        {:reply, {:ok, %{pane: pane, topology: topology_snapshot(state)}}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:focus_pane, pane_id}, _from, state) do
    case focus(state, pane_id) do
      {:ok, state} -> {:reply, {:ok, topology_snapshot(state)}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:close_pane, pane_id}, _from, state) do
    case close_owned_pane(state, pane_id) do
      {:ok, state} -> {:reply, {:ok, topology_snapshot(state)}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:apply_template, template_or_id, opts}, _from, state) do
    case apply_template_plan(state, template_or_id, opts) do
      {:ok, result, state} -> {:reply, {:ok, result}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:capture, pane_id}, _from, state) do
    case fetch_pane(state, pane_id) do
      {:ok, pane} -> {:reply, PowerShellPane.capture(pane.pid), state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resize, pane_id, cols, rows}, _from, state) do
    with {:ok, pane} <- fetch_pane(state, pane_id),
         :ok <- validate_size(cols, rows),
         :ok <- PowerShellPane.resize(pane.pid, cols, rows) do
      {:reply, :ok, put_in(state, [:panes, pane_id], %{pane | cols: cols, rows: rows})}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:set_pane_role, pane_id, role}, _from, state) do
    with {:ok, pane} <- fetch_pane(state, pane_id),
         :ok <- validate_role(role),
         :ok <- PowerShellPane.set_role(pane.pid, role) do
      {:reply, :ok, put_in(state, [:panes, pane_id], %{pane | role: role})}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:input, data}, _from, state) do
    with {:ok, pane_id} <- active_pane_id(state),
         {:ok, pane} <- fetch_pane(state, pane_id) do
      {:reply, PowerShellPane.send_input(pane.pid, data), state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:input, pane_id, data}, _from, state) do
    case fetch_pane(state, pane_id) do
      {:ok, pane} -> {:reply, PowerShellPane.send_input(pane.pid, data), state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:record_agent_launch, _from, state) do
    with {:ok, pane_id} <- active_pane_id(state),
         {:ok, pane} <- fetch_pane(state, pane_id),
         :ok <- PowerShellPane.set_role(pane.pid, "agent") do
      updated = put_in(state, [:panes, pane_id], %{pane | role: "agent"})
      {:reply, {:ok, topology_snapshot(updated)}, updated}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:ensure_workspace, cwd, workspace}, _from, state)
      when state.cwd == cwd and state.workspace == workspace,
      do: {:reply, :ok, state}

  def handle_call({:ensure_workspace, cwd, workspace}, _from, state) do
    restart_topology(state, cwd, workspace)
  end

  def handle_call({:restart, cwd, workspace}, _from, state) do
    restart_topology(state, cwd, workspace)
  end

  @impl true
  def handle_info({:native_pane_output, pane_id, data}, state) do
    if state.active_pane_id == pane_id, do: notify(state, {:desktop_terminal_output, data})
    {:noreply, state}
  end

  def handle_info({:native_pane_restarted, pane_id, term, pty}, state) do
    if state.active_pane_id == pane_id do
      notify(state, {:desktop_terminal_restarted, term, pty})
    end

    {:noreply, state}
  end

  def handle_info({:native_pane_exit, pane_id, reason}, state) do
    if state.active_pane_id == pane_id do
      notify(state, {:desktop_terminal_exit, reason})
    end

    {:noreply, mark_pane_status(state, pane_id, {:exited, reason})}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    cond do
      Map.has_key?(state.subscribers, ref) ->
        {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}

      Map.has_key?(state.pane_monitors, ref) ->
        {:noreply, forget_pane(state, pid, ref)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.panes, fn {_id, pane} ->
      if Process.alive?(pane.pid), do: PowerShellPane.close(pane.pid)
    end)

    :ok
  end

  defp open_window(state, opts) do
    name = Keyword.get(opts, :name, "PowerShell")
    role = Keyword.get(opts, :role, "operator")
    active? = Keyword.get(opts, :active?, false)
    cwd = Keyword.get(opts, :cwd)

    with :ok <- validate_role(role),
         :ok <- validate_window_name(name) do
      window_index = state.window_seq
      window_id = state.ids.session <> ":window:" <> Integer.to_string(window_index)
      window = %{id: window_id, session_id: state.ids.session, index: window_index, name: name}

      tentative = %{
        state
        | windows: state.windows ++ [window],
          window_seq: window_index + 1,
          active_window_id:
            if(active? or state.active_window_id == nil,
              do: window_id,
              else: state.active_window_id
            )
      }

      pane_opts =
        compact_keyword(
          role: role,
          cwd: cwd,
          active?: active? or state.active_pane_id == nil
        )

      case open_pane(tentative, window_id, pane_opts) do
        {:ok, pane, state} ->
          {:ok, window_entry(state, window_id), pane, state}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp open_pane(state, window_id, opts) do
    role = Keyword.get(opts, :role, "operator")
    active? = Keyword.get(opts, :active?, false)
    cwd = Keyword.get(opts, :cwd, state.cwd)
    cols = Keyword.get(opts, :cols, @default_cols)
    rows = Keyword.get(opts, :rows, @default_rows)

    with :ok <- validate_window(state, window_id),
         :ok <- validate_role(role),
         :ok <- validate_size(cols, rows),
         {:ok, cwd} <- validate_cwd(cwd) do
      pane_index = state.pane_seq
      pane_id = state.ids.session <> ":pane:" <> Integer.to_string(pane_index)

      become_active? = active? or state.active_pane_id == nil

      start_opts =
        [
          owner: self(),
          cwd: cwd,
          workspace: state.workspace,
          ids: %{session: state.ids.session, window: window_id, pane: pane_id},
          role: role,
          active?: become_active?,
          cols: cols,
          rows: rows
        ] ++ state.pane_opts

      attrs = %{role: role, cwd: cwd, cols: cols, rows: rows, active?: become_active?}

      case PowerShellPane.start_link(start_opts) do
        {:ok, pid} -> accept_started_pane(state, pid, pane_id, window_id, pane_index, attrs)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp accept_started_pane(state, pid, pane_id, window_id, pane_seq, attrs) do
    state = register_pane(state, pid, pane_id, window_id, pane_seq, attrs)
    state = maybe_focus_new_pane(state, pane_id, attrs.active?)
    {:ok, pane_entry(state, pane_id), state}
  end

  defp maybe_focus_new_pane(state, pane_id, true), do: focus_state(state, pane_id)
  defp maybe_focus_new_pane(state, _pane_id, false), do: state

  defp register_pane(state, pid, pane_id, window_id, pane_seq, attrs) do
    ref = Process.monitor(pid)

    pane = %{
      id: pane_id,
      window_id: window_id,
      index: pane_index_in_window(state, window_id),
      role: attrs.role,
      cwd: attrs.cwd,
      cols: attrs.cols,
      rows: attrs.rows,
      pid: pid,
      status: :running,
      active?: attrs.active?
    }

    %{
      state
      | panes: Map.put(state.panes, pane_id, pane),
        pane_monitors: Map.put(state.pane_monitors, ref, pane_id),
        pane_seq: pane_seq + 1
    }
  end

  defp focus(state, pane_id) do
    with {:ok, pane} <- fetch_pane(state, pane_id) do
      state =
        state
        |> clear_active_flags()
        |> then(fn state ->
          :ok = PowerShellPane.set_active(pane.pid, true)
          put_in(state, [:panes, pane_id], %{pane | active?: true})
        end)
        |> Map.put(:active_pane_id, pane_id)
        |> Map.put(:active_window_id, pane.window_id)

      {:ok, state}
    end
  end

  defp focus_state(state, pane_id) do
    case focus(state, pane_id) do
      {:ok, state} -> state
      {:error, _reason} -> state
    end
  end

  defp close_owned_pane(state, pane_id) do
    with {:ok, pane} <- fetch_pane(state, pane_id),
         :ok <- reject_last_pane(state) do
      state =
        state
        |> stop_pane_owner(pane_id, pane.pid)
        |> Map.update!(:panes, &Map.delete(&1, pane_id))
        |> maybe_drop_empty_window(pane.window_id)
        |> rebalance_focus(pane_id, pane.window_id)

      {:ok, state}
    end
  end

  defp stop_pane_owner(state, pane_id, pid) do
    ref = monitor_for_pane(state, pane_id)
    if ref, do: Process.demonitor(ref, [:flush])
    _ = PowerShellPane.close(pid)

    monitors =
      state.pane_monitors
      |> Enum.reject(fn {_ref, id} -> id == pane_id end)
      |> Map.new()

    %{state | pane_monitors: monitors}
  end

  defp forget_pane(state, pid, ref) do
    pane_id = Map.get(state.pane_monitors, ref)

    state = %{
      state
      | pane_monitors: Map.delete(state.pane_monitors, ref),
        panes:
          case pane_id do
            nil ->
              state.panes

            id ->
              case Map.get(state.panes, id) do
                %{pid: ^pid} = pane -> Map.put(state.panes, id, %{pane | status: :exited})
                _other -> state.panes
              end
          end
    }

    if pane_id && state.active_pane_id == pane_id do
      notify(state, {:desktop_terminal_exit, :pane_owner_exit})
    end

    state
  end

  defp apply_template_plan(state, template_or_id, opts) do
    with {:ok, dry_run} <- SessionTemplate.dry_run(template_or_id, opts),
         :ok <- reject_non_terminal_steps(dry_run.steps) do
      workspace_root = Keyword.get(opts, :workspace_root, state.cwd)

      exec_state = %{
        session_state: state,
        workspace_root: workspace_root,
        refs: %{},
        executed_steps: [],
        adopted_default_window?: false
      }

      dry_run.steps
      |> Enum.reduce_while({:ok, exec_state}, fn step, {:ok, exec_state} ->
        case execute_native_step(step, exec_state) do
          {:ok, exec_state} ->
            {:cont, {:ok, exec_state}}

          {:error, reason} ->
            {:halt,
             {:error, {reason, step, native_execution_summary(dry_run, exec_state)},
              exec_state.session_state}}
        end
      end)
      |> case do
        {:ok, exec_state} ->
          {:ok,
           dry_run
           |> Map.take([:template, :step_count])
           |> Map.merge(%{
             executed_steps: Enum.reverse(exec_state.executed_steps),
             refs: exec_state.refs,
             topology: topology_snapshot(exec_state.session_state)
           }), exec_state.session_state}

        {:error, reason, session_state} ->
          {:error, reason, session_state}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp reject_non_terminal_steps(steps) do
    if Enum.any?(steps, &(&1.action == "attach_pane")) do
      {:error, :unsupported_native_template_step}
    else
      :ok
    end
  end

  defp execute_native_step(%{action: "new_window"} = step, exec_state) do
    with {:ok, cwd} <-
           resolve_template_cwd(get_in(step, [:params, :cwd]), exec_state.workspace_root),
         name <- get_in(step, [:params, :name]) || "PowerShell",
         role <- step_role(step) || "operator",
         {:ok, window, root_pane, session_state, adopted?} <-
           open_or_adopt_window(exec_state.session_state, exec_state, name, role, cwd) do
      exec_state
      |> Map.put(:session_state, session_state)
      |> Map.put(
        :adopted_default_window?,
        exec_state.adopted_default_window? or adopted?
      )
      |> put_native_ref(step.ref, window.id)
      |> put_native_ref(root_ref(step.ref), root_pane.id)
      |> record_native_step(step, %{
        window_id: window.id,
        root_pane_id: root_pane.id,
        adopted_default?: adopted?
      })
      |> ok()
    end
  end

  defp execute_native_step(%{action: "split_pane"} = step, exec_state) do
    with {:ok, target_pane_id} <- resolve_native_ref(exec_state, step.target_ref),
         {:ok, target_pane} <- fetch_pane(exec_state.session_state, target_pane_id),
         {:ok, cwd} <-
           resolve_template_cwd(get_in(step, [:params, :cwd]), exec_state.workspace_root),
         role <- step_role(step) || "operator",
         opts <- compact_keyword(role: role, cwd: cwd || target_pane.cwd, active?: false),
         {:ok, pane, session_state} <-
           open_pane(exec_state.session_state, target_pane.window_id, opts) do
      exec_state
      |> Map.put(:session_state, session_state)
      |> put_native_ref(step.ref, pane.id)
      |> record_native_step(step, %{pane_id: pane.id, target_pane_id: target_pane_id})
      |> ok()
    end
  end

  defp execute_native_step(%{action: "send_command"} = step, exec_state) do
    with {:ok, target_pane_id} <- resolve_native_ref(exec_state, step.target_ref),
         {:ok, pane} <- fetch_pane(exec_state.session_state, target_pane_id),
         command when is_binary(command) and command != "" <- get_in(step, [:params, :command]),
         payload <- native_command_payload(command),
         :ok <- PowerShellPane.send_input(pane.pid, payload) do
      exec_state
      |> record_native_step(step, %{target_pane_id: target_pane_id})
      |> ok()
    else
      nil -> {:error, :missing_template_command}
      "" -> {:error, :missing_template_command}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_native_step(%{action: "select_pane"} = step, exec_state) do
    with {:ok, target_pane_id} <- resolve_native_ref(exec_state, step.target_ref),
         {:ok, session_state} <- focus(exec_state.session_state, target_pane_id) do
      exec_state
      |> Map.put(:session_state, session_state)
      |> record_native_step(step, %{pane_id: target_pane_id})
      |> ok()
    end
  end

  defp execute_native_step(step, _exec_state), do: {:error, {:unsupported_step, step.action}}

  defp open_or_adopt_window(state, exec_state, name, role, cwd) do
    if can_adopt_default_window?(state, exec_state) do
      adopt_default_window(state, name, role, cwd)
    else
      opts = compact_keyword(name: name, role: role, cwd: cwd, active?: false)

      case open_window(state, opts) do
        {:ok, window, pane, state} -> {:ok, window, pane, state, false}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp can_adopt_default_window?(state, exec_state) do
    not exec_state.adopted_default_window? and length(state.windows) == 1 and
      map_size(state.panes) == 1
  end

  defp adopt_default_window(state, name, role, cwd) do
    window = hd(state.windows)
    {pane_id, pane} = Enum.at(state.panes, 0)

    with :ok <- validate_role(role),
         :ok <- validate_window_name(name),
         :ok <- PowerShellPane.set_role(pane.pid, role) do
      updated_window = %{window | name: name}
      updated_pane = %{pane | role: role, cwd: cwd || pane.cwd}

      state = %{
        state
        | windows: [updated_window],
          panes: Map.put(state.panes, pane_id, updated_pane)
      }

      {:ok, window_entry(state, window.id), pane_entry(state, pane_id), state, true}
    end
  end

  defp native_command_payload(command) when is_binary(command) do
    trimmed = String.trim_trailing(command)

    cond do
      String.ends_with?(trimmed, "\r") -> trimmed
      String.ends_with?(trimmed, "\n") -> String.trim_trailing(trimmed, "\n") <> "\r"
      true -> trimmed <> "\r"
    end
  end

  defp resolve_template_cwd(nil, _workspace_root), do: {:ok, nil}
  defp resolve_template_cwd("", _workspace_root), do: {:ok, nil}

  defp resolve_template_cwd(".", workspace_root) when is_binary(workspace_root),
    do: validate_cwd(workspace_root)

  defp resolve_template_cwd(path, nil) when is_binary(path), do: validate_cwd(path)

  defp resolve_template_cwd(path, workspace_root)
       when is_binary(path) and is_binary(workspace_root) do
    case Path.type(path) do
      :absolute ->
        validate_cwd(path)

      _ ->
        workspace_root
        |> Path.join(path)
        |> Path.expand()
        |> validate_cwd()
    end
  end

  defp resolve_template_cwd(_path, _workspace_root), do: {:error, :invalid_native_cwd}

  defp step_role(step), do: get_in(step, [:metadata, :role])

  defp root_ref("window:" <> window_id), do: "pane:" <> window_id <> ":root"
  defp root_ref(ref), do: ref <> ":root"

  defp put_native_ref(exec_state, ref, value),
    do: %{exec_state | refs: Map.put(exec_state.refs, ref, value)}

  defp resolve_native_ref(%{refs: refs}, ref) do
    case Map.fetch(refs, ref) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:unresolved_ref, ref}}
    end
  end

  defp record_native_step(exec_state, step, result) do
    executed_step =
      step
      |> Map.take([:index, :action, :ref, :target_ref, :params, :metadata])
      |> Map.put(:result, result)

    %{exec_state | executed_steps: [executed_step | exec_state.executed_steps]}
  end

  defp native_execution_summary(dry_run, exec_state) do
    %{
      template: dry_run.template,
      step_count: dry_run.step_count,
      executed_steps: Enum.reverse(exec_state.executed_steps),
      refs: exec_state.refs,
      topology: topology_snapshot(exec_state.session_state)
    }
  end

  defp compact_keyword(opts) do
    Enum.reject(opts, fn {_key, value} -> value in [nil, ""] end)
  end

  defp ok(value), do: {:ok, value}

  defp restart_topology(state, cwd, workspace) do
    Enum.each(state.panes, fn {_id, pane} ->
      ref = monitor_for_pane(state, pane.id)
      if ref, do: Process.demonitor(ref, [:flush])
      if Process.alive?(pane.pid), do: PowerShellPane.close(pane.pid)
    end)

    ids = topology_ids(workspace)

    base = %{
      state
      | cwd: cwd,
        workspace: workspace,
        status: :running,
        ids: ids,
        windows: [],
        panes: %{},
        pane_monitors: %{},
        active_window_id: nil,
        active_pane_id: nil,
        window_seq: 0,
        pane_seq: 0
    }

    case open_window(base, name: "PowerShell", role: "operator", active?: true) do
      {:ok, _window, _pane, updated} ->
        case active_handles(updated) do
          {:ok, term, pty, _status} ->
            notify(updated, {:desktop_terminal_restarted, term, pty})
            {:reply, :ok, updated}

          {:error, reason} ->
            updated = %{updated | status: {:error, reason}}
            notify(updated, {:desktop_terminal_exit, reason})
            {:reply, {:error, reason}, updated}
        end

      {:error, reason} ->
        updated = %{base | status: {:error, reason}}
        notify(updated, {:desktop_terminal_exit, reason})
        {:reply, {:error, reason}, updated}
    end
  end

  defp active_handles(state) do
    with {:ok, pane_id} <- active_pane_id(state),
         {:ok, pane} <- fetch_pane(state, pane_id) do
      PowerShellPane.handles(pane.pid)
    end
  end

  defp active_pane_id(%{active_pane_id: pane_id}) when is_binary(pane_id), do: {:ok, pane_id}
  defp active_pane_id(_state), do: {:error, :invalid_pane_target}

  defp fetch_pane(state, pane_id) do
    case Map.fetch(state.panes, pane_id) do
      {:ok, pane} -> {:ok, pane}
      :error -> {:error, :invalid_pane_target}
    end
  end

  defp validate_window(state, window_id) do
    if Enum.any?(state.windows, &(&1.id == window_id)),
      do: :ok,
      else: {:error, :invalid_window_target}
  end

  defp reject_last_pane(state) do
    if map_size(state.panes) <= 1, do: {:error, :last_native_pane}, else: :ok
  end

  defp maybe_drop_empty_window(state, window_id) do
    if Enum.any?(state.panes, fn {_id, pane} -> pane.window_id == window_id end) do
      state
    else
      %{state | windows: Enum.reject(state.windows, &(&1.id == window_id))}
    end
  end

  defp rebalance_focus(state, closed_pane_id, closed_window_id) do
    state =
      if state.active_pane_id == closed_pane_id do
        case first_pane_id(state) do
          nil -> %{state | active_pane_id: nil}
          pane_id -> focus_state(state, pane_id)
        end
      else
        state
      end

    if state.active_window_id == closed_window_id do
      case state.active_pane_id && Map.get(state.panes, state.active_pane_id) do
        %{window_id: window_id} -> %{state | active_window_id: window_id}
        _ -> %{state | active_window_id: first_window_id(state)}
      end
    else
      state
    end
  end

  defp first_pane_id(state) do
    state.panes
    |> Map.keys()
    |> Enum.min_by(&pane_sort_key(state, &1), fn -> nil end)
  end

  defp first_window_id(state) do
    case Enum.min_by(state.windows, & &1.index, fn -> nil end) do
      nil -> nil
      window -> window.id
    end
  end

  defp pane_sort_key(state, pane_id) do
    pane = Map.fetch!(state.panes, pane_id)
    window = Enum.find(state.windows, &(&1.id == pane.window_id))
    {window && window.index, pane.index}
  end

  defp pane_index_in_window(state, window_id) do
    state.panes
    |> Enum.count(fn {_id, pane} -> pane.window_id == window_id end)
  end

  defp clear_active_flags(state) do
    panes =
      Enum.reduce(state.panes, %{}, fn {id, pane}, acc ->
        if pane.active? do
          _ = PowerShellPane.set_active(pane.pid, false)
          Map.put(acc, id, %{pane | active?: false})
        else
          Map.put(acc, id, pane)
        end
      end)

    %{state | panes: panes}
  end

  defp mark_pane_status(state, pane_id, status) do
    case Map.get(state.panes, pane_id) do
      nil -> state
      pane -> put_in(state, [:panes, pane_id], %{pane | status: status})
    end
  end

  defp monitor_for_pane(state, pane_id) do
    Enum.find_value(state.pane_monitors, fn
      {ref, ^pane_id} -> ref
      _ -> nil
    end)
  end

  defp monitor_subscriber(state, pid) do
    if Enum.any?(state.subscribers, fn {_ref, subscriber} -> subscriber == pid end) do
      state
    else
      ref = Process.monitor(pid)
      %{state | subscribers: Map.put(state.subscribers, ref, pid)}
    end
  end

  defp notify(state, message) do
    Enum.each(state.subscribers, fn {_ref, pid} -> send(pid, message) end)
  end

  defp normalize_cwd(cwd) when is_binary(cwd) and cwd != "" do
    if File.dir?(cwd), do: cwd, else: File.cwd!()
  end

  defp normalize_cwd(_cwd), do: File.cwd!()

  defp validate_cwd(cwd) when is_binary(cwd) and cwd != "" do
    if File.dir?(cwd), do: {:ok, cwd}, else: {:error, :invalid_native_cwd}
  end

  defp validate_cwd(_cwd), do: {:error, :invalid_native_cwd}

  defp server(workspace) do
    if Process.whereis(@registry) do
      {:via, Registry, {@registry, workspace_key(workspace)}}
    else
      @name
    end
  end

  defp record_agent_launch(workspace) do
    try do
      GenServer.call(server(workspace), :record_agent_launch)
    catch
      :exit, reason -> {:topology_error, reason}
    end
  end

  defp topology_failure(plan, runtime, reason, finisher, opts) do
    _ =
      finisher.(
        plan,
        "handoff",
        "native #{runtime} topology reporting failed",
        Keyword.get(opts, :finish_opts, [])
      )

    {:error, reason}
  end

  defp resolve({:via, Registry, {registry, key}}) do
    case Registry.lookup(registry, key) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  defp resolve(name) when is_atom(name), do: Process.whereis(name)

  defp workspace_key(%{id: id}) when is_binary(id), do: id
  defp workspace_key(%{"id" => id}) when is_binary(id), do: id
  defp workspace_key(id) when is_binary(id), do: id
  defp workspace_key(_workspace), do: "__scratch__"

  defp topology_ids(workspace) do
    digest =
      workspace
      |> workspace_key()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    session = "native-session-" <> digest
    %{session: session}
  end

  defp topology_snapshot(state) do
    windows =
      state.windows
      |> Enum.sort_by(& &1.index)
      |> Enum.map(fn window ->
        %{
          id: window.id,
          session_id: window.session_id,
          index: window.index,
          name: window.name,
          active?: state.active_window_id == window.id
        }
      end)

    panes =
      state.panes
      |> Map.values()
      |> Enum.sort_by(fn pane ->
        window = Enum.find(state.windows, &(&1.id == pane.window_id))
        {window && window.index, pane.index}
      end)
      |> Enum.map(fn pane ->
        %{
          id: pane.id,
          window_id: pane.window_id,
          index: pane.index,
          role: pane.role,
          active?: state.active_pane_id == pane.id,
          cwd: pane.cwd,
          cols: pane.cols,
          rows: pane.rows
        }
      end)

    %{
      session: %{
        id: state.ids.session,
        workspace_id: workspace_key(state.workspace),
        alive?: state.status == :running
      },
      windows: windows,
      panes: panes
    }
  end

  defp window_entry(state, window_id) do
    window = Enum.find(state.windows, &(&1.id == window_id))

    %{
      id: window.id,
      session_id: window.session_id,
      index: window.index,
      name: window.name,
      active?: state.active_window_id == window.id
    }
  end

  defp pane_entry(state, pane_id) do
    pane = Map.fetch!(state.panes, pane_id)

    %{
      id: pane.id,
      window_id: pane.window_id,
      index: pane.index,
      role: pane.role,
      active?: state.active_pane_id == pane.id,
      cwd: pane.cwd,
      cols: pane.cols,
      rows: pane.rows
    }
  end

  defp pane_start_opts(opts) do
    []
    |> maybe_put(:transport, Keyword.get(opts, :transport))
    |> maybe_put(:transport_opts, Keyword.get(opts, :transport_opts))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp validate_size(cols, rows)
       when is_integer(cols) and cols >= 1 and cols <= 500 and is_integer(rows) and rows >= 1 and
              rows <= 500,
       do: :ok

  defp validate_size(_cols, _rows), do: {:error, :invalid_terminal_size}

  defp validate_role(role) when role in @pane_roles, do: :ok
  defp validate_role(_role), do: {:error, :invalid_pane_role}

  defp validate_window_name(name) when is_binary(name) and name != "", do: :ok
  defp validate_window_name(_name), do: {:error, :invalid_window_name}
end
