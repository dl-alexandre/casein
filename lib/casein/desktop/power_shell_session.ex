defmodule Casein.Desktop.PowerShellSession do
  @moduledoc """
  Application-owned PowerShell session used by the native Windows desktop UI.

  The terminal and process transport deliberately outlive any one LiveView so
  browser reconnects retain the same shell process, variables, and working
  directory.
  """

  use GenServer

  alias Casein.Desktop.{AgentEnvironment, NativeAgentLaunch}

  @name __MODULE__
  @registry Module.concat(__MODULE__, Registry)
  @supervisor Module.concat(__MODULE__, Supervisor)
  @default_cols 100
  @default_rows 30
  @capture_bytes 64 * 1024
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

  @doc "Subscribes the caller and returns the emulator and process handles."
  def subscribe(workspace \\ nil) do
    GenServer.call(server(workspace), {:subscribe, self()})
  end

  def status(workspace \\ nil), do: GenServer.call(server(workspace), :status)

  @doc "Returns the product-level topology for one native Windows session."
  def topology(workspace \\ nil), do: GenServer.call(server(workspace), :topology)

  @doc "Returns retained raw terminal output for a validated native pane target."
  def capture(workspace, pane_id), do: GenServer.call(server(workspace), {:capture, pane_id})

  @doc "Resizes a validated native pane and its ConPTY transport."
  def resize(workspace, pane_id, cols, rows),
    do: GenServer.call(server(workspace), {:resize, pane_id, cols, rows})

  @doc "Assigns a product role to a validated native pane target."
  def set_pane_role(workspace, pane_id, role),
    do: GenServer.call(server(workspace), {:set_pane_role, pane_id, role})

  @doc "Writes terminal input to one workspace-scoped native session."
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
  @doc "Restarts the native shell in the given workspace directory."
  def restart(cwd \\ nil, workspace \\ nil),
    do: GenServer.call(server(workspace), {:restart, normalize_cwd(cwd), workspace})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    cwd = Keyword.fetch!(opts, :cwd)
    workspace = Keyword.get(opts, :workspace)

    case start_transport(cwd, workspace, @default_cols, @default_rows) do
      {:ok, term, pty} ->
        {:ok,
         %{
           term: term,
           pty: pty,
           cwd: cwd,
           workspace: workspace,
           subscribers: %{},
           status: :running,
           ids: topology_ids(workspace),
           cols: @default_cols,
           rows: @default_rows,
           pane_role: "operator",
           capture: <<>>
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    state = monitor_subscriber(state, pid)
    {:reply, {:ok, state.term, state.pty, state.status}, state}
  end

  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(:topology, _from, state), do: {:reply, topology_snapshot(state), state}

  def handle_call({:capture, pane_id}, _from, state) do
    with :ok <- validate_pane(state, pane_id) do
      {:reply, {:ok, state.capture}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resize, pane_id, cols, rows}, _from, state) do
    with :ok <- validate_pane(state, pane_id),
         :ok <- validate_size(cols, rows),
         :ok <- Ghostty.Terminal.resize(state.term, cols, rows),
         :ok <- Ghostty.PTY.resize(state.pty, cols, rows) do
      {:reply, :ok, %{state | cols: cols, rows: rows}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:set_pane_role, pane_id, role}, _from, state) do
    with :ok <- validate_pane(state, pane_id),
         :ok <- validate_role(role) do
      {:reply, :ok, %{state | pane_role: role}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:input, data}, _from, state) do
    {:reply, Ghostty.PTY.write(state.pty, data), state}
  end

  def handle_call({:input, pane_id, data}, _from, state) do
    with :ok <- validate_pane(state, pane_id) do
      {:reply, Ghostty.PTY.write(state.pty, data), state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:record_agent_launch, _from, state) do
    updated = %{state | pane_role: "agent"}
    {:reply, {:ok, topology_snapshot(updated)}, updated}
  end

  def handle_call({:ensure_workspace, cwd, workspace}, _from, state)
      when state.cwd == cwd and state.workspace == workspace,
      do: {:reply, :ok, state}

  def handle_call({:ensure_workspace, cwd, workspace}, _from, state) do
    restart_transport(state, cwd, workspace)
  end

  def handle_call({:restart, cwd, workspace}, _from, state) do
    restart_transport(state, cwd, workspace)
  end

  @impl true
  def handle_info({:data, data}, state) do
    :ok = Ghostty.Terminal.write(state.term, data)
    notify(state, {:desktop_terminal_output, data})
    {:noreply, %{state | capture: retain_capture(state.capture, data)}}
  end

  def handle_info({:pty_write, data}, state) when is_binary(data) do
    :ok = Ghostty.PTY.write(state.pty, data)
    {:noreply, state}
  end

  def handle_info({:exit, reason}, state) do
    recover_transport(state, reason)
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}
  end

  def handle_info({:EXIT, pid, reason}, %{pty: pid} = state) do
    recover_transport(state, reason)
  end

  def handle_info({:EXIT, pid, reason}, %{term: pid} = state), do: {:stop, reason, state}
  def handle_info(_message, state), do: {:noreply, state}

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

  defp restart_transport(state, cwd, workspace) do
    _ = close_transport(state)

    case start_transport(cwd, workspace, @default_cols, @default_rows) do
      {:ok, term, pty} ->
        updated = %{
          state
          | term: term,
            pty: pty,
            cwd: cwd,
            workspace: workspace,
            status: :running,
            ids: topology_ids(workspace),
            cols: @default_cols,
            rows: @default_rows,
            capture: <<>>
        }

        notify(updated, {:desktop_terminal_restarted, term, pty})
        {:reply, :ok, updated}

      {:error, reason} ->
        updated = %{state | status: {:error, reason}}
        notify(updated, {:desktop_terminal_exit, reason})
        {:reply, {:error, reason}, updated}
    end
  end

  defp recover_transport(state, reason) do
    case start_transport(state.cwd, state.workspace, state.cols, state.rows) do
      {:ok, term, pty} ->
        updated = %{state | term: term, pty: pty, status: :running}
        notify(updated, {:desktop_terminal_restarted, term, pty})
        {:noreply, updated}

      {:error, restart_reason} ->
        updated = %{state | status: {:exited, {reason, restart_reason}}}
        notify(updated, {:desktop_terminal_exit, {reason, restart_reason}})
        {:noreply, updated}
    end
  end

  defp start_transport(cwd, workspace, cols, rows) do
    with {:ok, env} <- agent_environment(workspace, cwd),
         {:ok, term} <- Ghostty.Terminal.start_link(cols: cols, rows: rows),
         {:ok, pty} <-
           Ghostty.PTY.start_link(cwd: cwd, env: env, cols: cols, rows: rows) do
      {:ok, term, pty}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp agent_environment(nil, _cwd), do: {:ok, %{}}
  defp agent_environment(workspace, cwd), do: AgentEnvironment.build(workspace, cwd)

  defp close_transport(state) do
    if is_pid(state.pty) and Process.alive?(state.pty), do: Ghostty.PTY.close(state.pty)
    if is_pid(state.term) and Process.alive?(state.term), do: GenServer.stop(state.term)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp normalize_cwd(cwd) when is_binary(cwd) and cwd != "" do
    if File.dir?(cwd), do: cwd, else: File.cwd!()
  end

  defp normalize_cwd(_cwd), do: File.cwd!()

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
    %{session: session, window: session <> ":window:0", pane: session <> ":pane:0"}
  end

  defp topology_snapshot(state) do
    %{
      session: %{
        id: state.ids.session,
        workspace_id: workspace_key(state.workspace),
        alive?: state.status == :running
      },
      windows: [
        %{
          id: state.ids.window,
          session_id: state.ids.session,
          index: 0,
          name: "PowerShell",
          active?: true
        }
      ],
      panes: [
        %{
          id: state.ids.pane,
          window_id: state.ids.window,
          index: 0,
          role: state.pane_role,
          active?: true,
          cwd: state.cwd,
          cols: state.cols,
          rows: state.rows
        }
      ]
    }
  end

  defp validate_pane(%{ids: %{pane: pane_id}}, pane_id), do: :ok
  defp validate_pane(_state, _pane_id), do: {:error, :invalid_pane_target}

  defp validate_size(cols, rows)
       when is_integer(cols) and cols >= 1 and cols <= 500 and is_integer(rows) and rows >= 1 and
              rows <= 500,
       do: :ok

  defp validate_size(_cols, _rows), do: {:error, :invalid_terminal_size}

  defp validate_role(role) when role in @pane_roles, do: :ok
  defp validate_role(_role), do: {:error, :invalid_pane_role}

  defp retain_capture(previous, data) do
    capture = previous <> IO.iodata_to_binary(data)
    size = byte_size(capture)

    if size > @capture_bytes do
      binary_part(capture, size - @capture_bytes, @capture_bytes)
    else
      capture
    end
  end
end
