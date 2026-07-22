defmodule DevIDE.Previews.FileServer do
  @moduledoc """
  Per-workspace loopback static file server for browser-viewable workspace paths.

  One GenServer per `workspace_id`, keyed in `DevIDE.Previews.FileServer.Registry`
  and supervised under `DevIDE.Previews.FileServer.Supervisor` (`restart: :temporary`).
  On start it binds a Bandit listener to `127.0.0.1` on an ephemeral port rooted
  at `Workspaces.safe_host_loc/1`, then exposes that port so a `:preview` pane can
  load `http://127.0.0.1:<port>/<rel>` through the existing preview proxy.

  Reaped when the workspace's tmux session terminates (topology
  `:session_terminated`) and by an idle timeout so listeners do not leak.

  Idle is measured from the last **useful** activity: `ensure_started/2`
  (port lookup) **or** an HTTP hit on the plug. A preview pane left open and
  reloaded keeps the server alive; a silent abandon still reaps after the
  idle window. Full pane-registration coupling remains a possible follow-up.
  """

  use GenServer
  require Logger

  alias DevIDE.Previews.Deps
  alias DevIDE.Previews.FileServer.Plug, as: FileServerPlug

  # Topology PubSub messages use this atom tag; resolved at runtime so this
  # module never names DevIDE.Terminals.TmuxTopology at compile time.
  @topology_tag Deps.topology_tag()
  # Belt-and-suspenders: stop after this long with no ensure_started / HTTP
  # activity even if the topology signal is missed.
  @idle_ms 15 * 60 * 1000

  ## Public API

  def child_spec(arg) do
    %{
      id: {__MODULE__, arg},
      start: {__MODULE__, :start_link, [arg]},
      restart: :temporary
    }
  end

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: via(workspace_id(arg)))

  def via(workspace_id) when is_binary(workspace_id),
    do: {:via, Registry, {DevIDE.Previews.FileServer.Registry, workspace_id}}

  def whereis(workspace_id) when is_binary(workspace_id) do
    case Registry.lookup(DevIDE.Previews.FileServer.Registry, workspace_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Returns `{:ok, port}` for the workspace's loopback file server, starting one
  if not already running.
  """
  @spec ensure_started(map() | String.t(), keyword()) ::
          {:ok, pos_integer()} | {:error, term()}
  def ensure_started(workspace, opts \\ [])

  def ensure_started(workspace, opts) when is_map(workspace) or is_binary(workspace) do
    id = workspace_id(workspace)

    case whereis(id) do
      {:ok, pid} ->
        GenServer.call(pid, :port)

      :error ->
        case DynamicSupervisor.start_child(
               DevIDE.Previews.FileServer.Supervisor,
               {__MODULE__, {workspace, opts}}
             ) do
          {:ok, pid} ->
            GenServer.call(pid, :port)

          {:error, {:already_started, pid}} ->
            GenServer.call(pid, :port)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc "Stop the file server for a workspace, if running."
  @spec stop(String.t() | map()) :: :ok
  def stop(workspace) do
    id = workspace_id(workspace)

    case whereis(id) do
      {:ok, pid} -> GenServer.stop(pid, :normal)
      :error -> :ok
    end
  end

  @doc """
  Reset the idle timer for a running file server.

  Called from the plug on every HTTP request so an open preview that keeps
  loading assets does not get reaped while the pane is still in use.
  Accepts a server pid (preferred — no Registry hop) or a workspace id.
  """
  @spec touch(pid() | String.t()) :: :ok
  def touch(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.cast(pid, :touch)
    :ok
  end

  def touch(workspace_id) when is_binary(workspace_id) do
    case whereis(workspace_id) do
      {:ok, pid} -> touch(pid)
      :error -> :ok
    end
  end

  def touch(_), do: :ok

  ## Callbacks

  @impl true
  def init({workspace, opts}) when is_list(opts) do
    id = workspace_id(workspace)

    with {:ok, loc} <- resolve_loc(workspace),
         # Pass self() so the plug can cast :touch without a Registry lookup
         # (the GenServer name is registered, but pid is the reliable handle
         # for request-path activity while the listener is live).
         {:ok, bandit_pid, port} <- start_listener(loc, self()) do
      Process.flag(:trap_exit, true)
      Process.monitor(bandit_pid)

      tmux_session = Keyword.get(opts, :tmux_session) || default_tmux_session(workspace)
      maybe_subscribe_topology(tmux_session)

      {:ok,
       %{
         workspace_id: id,
         loc: loc,
         bandit_pid: bandit_pid,
         port: port,
         tmux_session: tmux_session,
         idle_ref: schedule_idle()
       }}
    else
      {:error, reason} ->
        {:stop, reason}
    end
  end

  def init(workspace), do: init({workspace, []})

  @impl true
  def handle_call(:port, _from, state) do
    {:reply, {:ok, state.port}, touch_idle(state)}
  end

  @impl true
  def handle_cast(:touch, state) do
    {:noreply, touch_idle(state)}
  end

  @impl true
  def handle_info({@topology_tag, {:session_terminated, %{session: session}}}, state) do
    if state.tmux_session == session do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({@topology_tag, _other}, state), do: {:noreply, state}

  # Match the current idle generation so a cancelled timer that already
  # delivered its message cannot reap a server that was touched afterward.
  def handle_info({:idle_timeout, ref}, %{idle_ref: ref} = state), do: {:stop, :normal, state}
  def handle_info({:idle_timeout, _stale}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{bandit_pid: pid} = state) do
    Logger.warning(
      "file server bandit exited workspace=#{state.workspace_id} reason=#{inspect(reason)}"
    )

    {:stop, :normal, state}
  end

  def handle_info({:EXIT, pid, reason}, %{bandit_pid: pid} = state) do
    Logger.warning(
      "file server bandit exit workspace=#{state.workspace_id} reason=#{inspect(reason)}"
    )

    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_pid(state[:bandit_pid]) and Process.alive?(state.bandit_pid) do
      # Bandit is a supervisor; stop it so the port is released promptly.
      _ = Supervisor.stop(state.bandit_pid, :normal)
    end

    :ok
  end

  ## Internals

  defp start_listener(loc, server_pid) when is_pid(server_pid) do
    case Bandit.start_link(
           plug: {FileServerPlug, loc: loc, server: server_pid},
           scheme: :http,
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false,
           # Serve identity, never gzip/deflate. The preview proxy fetches with
           # `decode_body: false` and forwards the body verbatim; if Bandit
           # compressed under the browser's `Accept-Encoding`, the proxy would
           # relay gzip bytes that the iframe then parses as text — rendering an
           # SVG/HTML file as an "Encoding error" / binary garbage. These files
           # are small and travel one loopback hop, so compression buys nothing.
           http_options: [compress: false]
         ) do
      {:ok, pid} ->
        case ThousandIsland.listener_info(pid) do
          {:ok, {_address, port}} when is_integer(port) and port > 0 ->
            {:ok, pid, port}

          other ->
            _ = Supervisor.stop(pid, :normal)
            {:error, {:listener_info, other}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_loc(workspace) do
    case Deps.impl(:workspaces).safe_host_loc(workspace) do
      {:ok, {:local, _root} = loc} -> {:ok, loc}
      {:ok, {:remote, _, _} = loc} -> {:ok, loc}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_loc, other}}
    end
  end

  defp maybe_subscribe_topology(session) when is_binary(session) and session != "" do
    _ = Deps.impl(:terminals).topology_subscribe(session)
    :ok
  end

  defp maybe_subscribe_topology(_), do: :ok

  defp default_tmux_session(%{name: name}) when is_binary(name) and name != "" do
    # Default sid used by the primary workspace terminal attachment.
    Deps.impl(:terminals).session_name(name, "main")
  end

  defp default_tmux_session(%{"name" => name}) when is_binary(name) and name != "" do
    Deps.impl(:terminals).session_name(name, "main")
  end

  defp default_tmux_session(_), do: nil

  defp schedule_idle do
    ref = make_ref()
    Process.send_after(self(), {:idle_timeout, ref}, idle_ms())
    ref
  end

  defp touch_idle(%{idle_ref: ref} = state) do
    if is_reference(ref), do: Process.cancel_timer(ref)
    %{state | idle_ref: schedule_idle()}
  end

  defp idle_ms do
    Application.get_env(:dev_ide, :file_server_idle_ms, @idle_ms)
  end

  defp workspace_id(%{id: id}) when is_binary(id), do: id
  defp workspace_id(%{"id" => id}) when is_binary(id), do: id
  defp workspace_id(id) when is_binary(id), do: id
  defp workspace_id({workspace, _opts}), do: workspace_id(workspace)
  defp workspace_id(_), do: raise(ArgumentError, "workspace must have a binary id")
end
