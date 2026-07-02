defmodule DevIDE.Terminals.Session do
  @moduledoc """
  PTY-attached tmux session.

  Starts `tmux new-session -A -s <name>` under a PTY allocated by `erlexec`.
  The `-A` flag means "attach if exists, create otherwise" — this is the
  reconnect mechanism: Session processes can come and go, but the underlying
  tmux session persists until killed.

  One Session per `(workspace, sid)` pair, keyed in `DevIDE.Terminals.Registry`.
  Subscribers receive `{:term_data, ref, binary}` for live data and
  `{:term_data, ref, binary, :replay}` for initial replay on attach.
  """

  use GenServer
  require Logger

  alias DevIDE.Terminals.Tmux
  alias DevIDE.Terminals.TmuxRunner
  alias DevIDE.Terminals.Shims

  @default_rows 40
  @default_cols 120

  # Retained tail of pane output, replayed to a new subscriber on attach.
  # This is what makes resume-after-disconnect (product.md §8.2, §12 row 5)
  # show the operator what happened while they were gone, instead of an
  # empty pane that picks up only future bytes.
  @buffer_bytes 64 * 1024

  ## Public API

  @type loc :: {:local, String.t()} | {:remote, String.t(), String.t()}

  def child_spec({_workspace, _sid, _loc} = arg) do
    %{id: {__MODULE__, arg}, start: {__MODULE__, :start_link, [arg]}, restart: :temporary}
  end

  def start_link({workspace, sid, loc}) do
    name = via(workspace, sid)
    GenServer.start_link(__MODULE__, {workspace, sid, loc}, name: name)
  end

  def via(workspace, sid),
    do: {:via, Registry, {DevIDE.Terminals.Registry, {workspace, sid}}}

  def whereis(workspace, sid) do
    case Registry.lookup(DevIDE.Terminals.Registry, {workspace, sid}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Returns the Session pid, starting one if not already running.
  """
  def ensure_started(workspace, sid, loc) do
    case whereis(workspace, sid) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        DynamicSupervisor.start_child(
          DevIDE.Terminals.Supervisor,
          {__MODULE__, {workspace, sid, loc}}
        )
    end
  end

  @doc """
  Subscribes the caller to live output. Additive: existing subscribers keep
  receiving data. Replays the retained buffer to the new subscriber.

  Returns `{:ok, ref, cols, rows}`. The `ref` is the session-wide discriminator
  on `{:term_data, ref, _}` and `{:term_exit, ref, _}` messages — shared across
  subscribers so they all see the same "messages from THIS session" tag.
  """
  def subscribe(pid), do: GenServer.call(pid, {:subscribe, self()})

  @doc """
  Returns the retained output buffer without subscribing.

  Useful for read-only consumers (e.g. agent watchers, preview UIs) that want
  to peek at recent output without joining the live fan-out. The buffer is
  capped at #{div(64 * 1024, 1024)}KB; bytes older than that are gone.
  """
  def snapshot(pid), do: GenServer.call(pid, :snapshot)

  @doc """
  Removes the calling pid from the subscriber set without stopping the
  session. The PTY persists for other subscribers and for future reconnects.
  """
  def unsubscribe(pid), do: GenServer.call(pid, {:unsubscribe, self()})

  def send_input(pid, data) when is_binary(data), do: GenServer.cast(pid, {:input, data})
  def resize(pid, cols, rows), do: GenServer.cast(pid, {:resize, cols, rows})
  def stop(pid), do: GenServer.stop(pid, :normal)

  ## Callbacks

  @impl true
  def init({workspace, sid, loc}) do
    # Defer the blocking PTY bring-up (tmux scrollback capture + :exec.run, each
    # a subprocess round-trip) to handle_continue so init returns immediately
    # and DynamicSupervisor.start_child isn't serialized on it. handle_continue
    # runs before any queued subscribe/input call, so callers still see a live
    # PTY — they just block until :spawn finishes instead of blocking start_child.
    {:ok,
     %{
       ref: nil,
       workspace: workspace,
       sid: sid,
       loc: loc,
       tmux: Tmux.session_name(workspace, sid),
       exec_pid: nil,
       ospid: nil,
       # Multi-subscriber fan-out (B1 fix): map of monitor_ref => pid.
       # All subscribers share the session-wide `ref` field on outbound
       # messages — the ref discriminates "this session" from stale
       # messages, not one subscriber from another.
       subscribers: %{},
       cols: @default_cols,
       rows: @default_rows,
       buffer: <<>>
     }, {:continue, :spawn}}
  end

  @impl true
  def handle_continue(
        :spawn,
        %{workspace: workspace, sid: sid, loc: loc, tmux: tmux_session} = state
      ) do
    # A resume reattaches a tmux session that already exists; a fresh open
    # creates it. The two differ in bring-up width (below) and scrollback seed.
    resumed? = match?({:local, _cwd}, loc) and Tmux.session_exists?(tmux_session)

    # Seed scrollback only in local mode; over ssh the round-trip to capture
    # scrollback isn't worth it (tmux on the remote retains its own scrollback
    # which redraws on attach).
    seeded_buffer =
      if resumed? do
        Tmux.capture_scrollback(tmux_session)
        |> trim_to(@buffer_bytes)
      else
        <<>>
      end

    # Bring the PTY up at the right width. A *new* tmux session is created at the
    # default size, but a *resumed* one already has a window size set by whatever
    # client last drove it. erlexec allocates the attach PTY small; left to the
    # `:exec.winsz` below at the hardcoded default — combined with tmux
    # `window-size latest` — it would shrink the resumed window down to the
    # default, collapsing the operator's terminal into a narrow column (with the
    # captured scrollback re-wrapped narrow) until a browser refit round-trips
    # back up. Seed the winsz from the existing window so a resume opens at its
    # real width; the browser's fit still adjusts to the actual viewport after.
    {cols, rows} =
      with true <- resumed?,
           {:ok, {w, h}} <- Tmux.window_size(tmux_session) do
        {w, h}
      else
        _ -> {@default_cols, @default_rows}
      end

    {cmd, cwd_opt} = build_cmd(loc, tmux_session)

    # In PTY mode, erlexec routes all child output through the :stderr channel.
    # Capture both so this code is robust to either routing.
    opts =
      [
        :stdin,
        :monitor,
        :pty,
        {:env,
         [{~c"TERM", ~c"xterm-256color"}, {~c"COLORTERM", ~c"truecolor"}] ++
           Shims.exec_env()},
        {:stdout, self()},
        {:stderr, self()}
      ] ++ cwd_opt

    case :exec.run(cmd, opts) do
      {:ok, exec_pid, ospid} ->
        _ = :exec.winsz(ospid, rows, cols)

        Logger.debug("terminal session started",
          workspace: workspace,
          sid: sid,
          tmux: tmux_session,
          ospid: ospid
        )

        {:noreply,
         %{
           state
           | ref: make_ref(),
             exec_pid: exec_pid,
             ospid: ospid,
             cols: cols,
             rows: rows,
             buffer: seeded_buffer
         }}

      {:error, reason} ->
        {:stop, {:exec_failed, reason}, state}
    end
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    state =
      case find_subscriber_ref(state, pid) do
        nil ->
          ref = Process.monitor(pid)
          %{state | subscribers: Map.put(state.subscribers, ref, pid)}

        _existing_ref ->
          # Already subscribed (e.g. reconnect using the same pid). No-op on
          # the monitor; buffer replay below still gives them a fresh view.
          state
      end

    # Replay retained output to the new subscriber only. Other subscribers
    # have already seen what's in the buffer in real time.
    if state.buffer != <<>> do
      send(pid, {:term_data, state.ref, state.buffer, :replay})
    end

    {:reply, {:ok, state.ref, state.cols, state.rows}, state}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    state =
      case find_subscriber_ref(state, pid) do
        nil ->
          state

        ref ->
          Process.demonitor(ref, [:flush])
          %{state | subscribers: Map.delete(state.subscribers, ref)}
      end

    {:reply, :ok, state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, state.buffer, state}
  end

  @impl true
  def handle_cast({:input, data}, state) do
    :exec.send(state.ospid, data)
    {:noreply, state}
  end

  def handle_cast({:resize, cols, rows}, state) when is_integer(cols) and is_integer(rows) do
    cols = max(min(cols, 500), 1)
    rows = max(min(rows, 500), 1)
    _ = :exec.winsz(state.ospid, rows, cols)
    {:noreply, %{state | cols: cols, rows: rows}}
  end

  @impl true
  def handle_info({:stdout, _ospid, data}, state), do: {:noreply, ingest(state, data)}
  def handle_info({:stderr, _ospid, data}, state), do: {:noreply, ingest(state, data)}

  # A subscriber went away. Remove just that one — do not stop the session;
  # other subscribers (and future reconnects) keep the PTY alive.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state)
      when is_map_key(state.subscribers, ref) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}
  end

  def handle_info({:DOWN, ospid, :process, _pid, reason}, %{ospid: ospid} = state) do
    for pid <- Map.values(state.subscribers),
        do: send(pid, {:term_exit, state.ref, reason})

    {:stop, :normal, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{ospid: ospid}) do
    _ = :exec.kill(ospid, 15)
    :ok
  catch
    :exit, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  ## Internal

  # Build the erlexec argv for the underlying PTY command, returning the cmd
  # and any extra opts (like {:cd, ...}). Local mode spawns tmux through the
  # configured WorkspaceSource's argv wrapper — for the milc-devbox manager
  # integration that means `docker compose exec <service> tmux …`, which puts
  # the tmux *server itself* inside the workspace container the manager owns.
  # The session's lifecycle is then bound to the container (stops with it,
  # rebuilds on next attach), removing the host-side desync hazard the older
  # "host tmux wrapping docker exec bash" pattern had. Remote mode still
  # wraps in `ssh -tt` so the cockpit talks to a remote tmux over an
  # ssh-allocated pty.
  defp build_cmd({:local, cwd}, tmux_session) do
    exec_cwd = DevIDE.WorkspaceSource.local_exec_cwd(cwd)

    new_session_args = fn opts ->
      [
        "new-session",
        "-A"
      ] ++
        Shims.tmux_env_flags(opts) ++
        [
          "-s",
          tmux_session,
          "-c",
          exec_cwd,
          "-x",
          Integer.to_string(@default_cols),
          "-y",
          Integer.to_string(@default_rows)
        ]
    end

    # Host-targeted invocations carry the configured server label (`-L …`) and
    # config (`-f …`) so they match management calls in TmuxRunner; the
    # container branch runs tmux inside the workspace's own isolated server.
    host_argv = fn extra -> TmuxRunner.host_argv(new_session_args.([]) ++ extra) end
    container_argv = fn extra -> ["tmux" | new_session_args.(include_path?: false) ++ extra] end
    integrated_shell = fn -> [login_shell_command()] end

    cmd_list =
      cond do
        Tmux.host_shell?() ->
          # Explicit host-shell mode: run both tmux and the pane shell on the
          # host. Do not use the manager's docker-compose pane wrapper here;
          # that wrapper is for non-host fallback and exits immediately in
          # workspaces that are intentionally host-shell backed.
          host_argv.(integrated_shell.())

        Tmux.local_argv_wrapped?() and Tmux.container_has_tmux?(cwd) ->
          # Preferred: tmux server runs inside the manager-owned container.
          DevIDE.WorkspaceSource.prepare_local_argv(container_argv.(integrated_shell.()),
            tty: true,
            cwd: cwd,
            normal_cwd: exec_cwd
          )

        true ->
          # Fallback for workspace images that don't yet ship tmux: run tmux on
          # the host. If the workspace container is actually running, use its
          # shell as the pane command; otherwise use the host shell in `cwd`.
          # The latter is what keeps bespoke/devbox checkouts usable when the
          # manager Docker start flow does not apply.
          case DevIDE.WorkspaceSource.local_tmux_pane_shell(cwd) do
            nil -> host_argv.(integrated_shell.())
            shell -> host_argv.([shell])
          end
      end

    cmd =
      cmd_list
      |> DevIDE.Terminals.CleanExec.wrap_argv()
      |> resolve_executable()
      |> Enum.map(&to_charlist/1)

    {cmd, [{:cd, to_charlist(cwd)}]}
  end

  defp build_cmd({:remote, host, path}, tmux_session) do
    # Quote path for the remote shell. `cd` first so the tmux session inherits
    # the workspace as cwd; `-A` reattaches if the session already exists.
    remote =
      "cd #{shell_quote(path)} && exec tmux new-session -A -s #{tmux_session} -x #{@default_cols} -y #{@default_rows}"

    cmd =
      ~c"ssh -tt -o BatchMode=yes -o ServerAliveInterval=30 -o ConnectTimeout=10 #{host} -- #{shell_quote(remote)}"

    {cmd, []}
  end

  defp shell_quote(s) when is_binary(s) do
    "'" <> String.replace(s, "'", "'\\''") <> "'"
  end

  defp login_shell_command do
    Application.get_env(:dev_ide, :tmux_login_shell_command) ||
      System.get_env("DEV_IDE_TMUX_LOGIN_SHELL") ||
      Shims.shell_command()
  end

  defp resolve_executable([cmd | rest]) when is_binary(cmd) do
    [executable_path(cmd) | rest]
  end

  defp resolve_executable(argv), do: argv

  defp executable_path(cmd) do
    cond do
      String.contains?(cmd, "/") -> cmd
      path = System.find_executable(cmd) -> path
      true -> cmd
    end
  end

  # Append fresh PTY output to the retained buffer (capped at @buffer_bytes)
  # and forward live to the current subscriber if any. Buffering continues
  # even when no subscriber is attached, which is what makes resume work.
  defp ingest(state, data) do
    bin = IO.iodata_to_binary(data)

    for pid <- Map.values(state.subscribers),
        do: send(pid, {:term_data, state.ref, bin})

    %{state | buffer: DevIDE.BoundedBuffer.append(state.buffer, bin, @buffer_bytes)}
  end

  # Reverse-lookup a subscriber's monitor ref by pid. O(N) but N is tiny
  # (one tab + maybe one watcher in realistic cases).
  defp find_subscriber_ref(state, pid) do
    Enum.find_value(state.subscribers, fn
      {ref, ^pid} -> ref
      _ -> nil
    end)
  end

  defp trim_to(bin, cap) when byte_size(bin) <= cap, do: bin

  defp trim_to(bin, cap) do
    size = byte_size(bin)
    binary_part(bin, size - cap, cap)
  end
end
