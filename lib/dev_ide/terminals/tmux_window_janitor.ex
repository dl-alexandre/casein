defmodule DevIDE.Terminals.TmuxWindowJanitor do
  @moduledoc """
  Periodic sweep that reaps blank, auto-named, never-used tmux windows that
  accumulate inside `devide_*` sessions.

  This complements `DevIDE.Terminals.TmuxJanitor` (which is subscriber-driven
  and works at the *session* level): the subscriber bookkeeping is in-memory and
  lost on a server restart, and it never reaches *inside* a session to trim the
  extra windows a user spins up (tmux `Ctrl-b c`) and abandons. This sweep is the
  safety net for those.

  It also reaps whole **orphaned sessions** — blank `devide_*` sessions with no
  attached client, idle past `:tmux_session_idle_seconds`, where every pane is
  just a shell. These are the per-tab sessions abandoned by closed tabs and the
  ones left dangling after a restart wiped the reactive janitor's subscriber
  map. Per-tab independence is preserved: an attached session (a live viewer) is
  never touched.

  ## Kill policy — a window is reaped only when ALL hold

    * its session name starts with `devide_` (never touch foreign sessions);
    * `automatic_rename` is on — i.e. the user never named it. The moment a
      user renames a window (`Ctrl-b ,`) tmux turns automatic-rename off, so a
      named window is permanently safe;
    * it is **not** the active window of its session (which also guarantees the
      session has another window, so we never kill the last one and destroy the
      session);
    * it has exactly one pane whose foreground command is a login/interactive
      shell — nothing is running in it;
    * it has been idle (no activity) for at least `:tmux_window_idle_seconds`.

  ## Configuration

    * `:tmux_window_sweep_ms` — sweep interval in ms; `nil`/`0` disables the
      janitor entirely (no sweep ever runs). Default `nil`.
    * `:tmux_window_idle_seconds` — minimum idle age before a window is
      eligible. Default `600`.
    * `:tmux_session_idle_seconds` — minimum idle age before an orphaned
      session is eligible. Default `600`.
  """
  use GenServer

  require Logger

  alias DevIDE.Terminals.Tmux

  @default_idle_seconds 600

  # Foreground commands that mean "just a shell sitting at a prompt". A window
  # running anything else (vim, a build, a REPL, ssh…) reports that command
  # instead and is left alone.
  @shells ~w(bash zsh sh fish dash ash -bash -zsh -sh -fish)

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Run a sweep now and return the number of windows killed. Mainly for tests/ops."
  @spec sweep_now() :: non_neg_integer()
  def sweep_now, do: GenServer.call(__MODULE__, :sweep_now)

  ## Server callbacks

  @impl true
  def init(_opts) do
    case sweep_ms() do
      ms when is_integer(ms) and ms > 0 ->
        schedule(ms)
        {:ok, %{interval_ms: ms}}

      _ ->
        # Disabled — start but stay idle so the supervision tree is unchanged
        # whether or not the feature is configured on.
        {:ok, %{interval_ms: nil}}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    _ = run_sweep()
    if state.interval_ms, do: schedule(state.interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:sweep_now, _from, state) do
    {:reply, run_sweep(), state}
  end

  ## Internals

  defp run_sweep do
    now = System.system_time(:second)
    sweep_windows(now) + sweep_sessions(now)
  end

  # Trim extra blank auto-named windows (leaves the active window — so a session
  # is never emptied here; whole-session reaping is sweep_sessions/1's job).
  defp sweep_windows(now) do
    idle = window_idle_seconds()

    Tmux.list_windows()
    |> Enum.filter(&killable?(&1, now, idle))
    |> Enum.reduce(0, fn win, killed ->
      case Tmux.kill_window(win.session, win.window_id) do
        :ok ->
          Logger.info(
            "TmuxWindowJanitor: killed blank idle window #{win.session}:#{win.window_id} " <>
              "(cmd=#{win.current_command}, idle≥#{idle}s)"
          )

          killed + 1

        {:error, reason} ->
          Logger.warning(
            "TmuxWindowJanitor: kill #{win.session}:#{win.window_id} failed: #{inspect(reason)}"
          )

          killed
      end
    end)
  end

  # Reap whole orphaned sessions: devide_*, unattached, idle, and blank (every
  # pane is a shell). `busy` is the set of sessions with at least one non-shell
  # pane — those are spared regardless of attach/idle state.
  defp sweep_sessions(now) do
    idle = session_idle_seconds()
    busy = busy_sessions()

    Tmux.list_sessions()
    |> Enum.filter(&session_killable?(&1, now, idle, busy))
    |> Enum.reduce(0, fn sess, killed ->
      case Tmux.kill(sess.session) do
        {_, 0} ->
          Logger.info(
            "TmuxWindowJanitor: killed orphaned idle session #{sess.session} (idle≥#{idle}s)"
          )

          killed + 1

        other ->
          Logger.warning(
            "TmuxWindowJanitor: kill session #{sess.session} failed: #{inspect(other)}"
          )

          killed
      end
    end)
  end

  # Sessions that have any pane running something other than a bare shell.
  defp busy_sessions do
    Tmux.list_panes()
    |> Enum.reduce(MapSet.new(), fn {session, cmd}, acc ->
      if cmd in @shells, do: acc, else: MapSet.put(acc, session)
    end)
  end

  @doc """
  Pure kill predicate (see the module doc for the policy). Exposed so the policy
  can be unit-tested without a live tmux server.
  """
  @spec killable?(map(), integer(), non_neg_integer()) :: boolean()
  def killable?(win, now, idle_seconds) do
    String.starts_with?(win.session, "devide_") and
      win.automatic_rename and
      not win.active and
      win.panes == 1 and
      win.current_command in @shells and
      now - win.activity >= idle_seconds
  end

  @doc """
  Pure session-reap predicate. `busy` is the set of session names that have at
  least one non-shell pane. Exposed for unit testing without a live tmux server.
  """
  @spec session_killable?(map(), integer(), non_neg_integer(), MapSet.t()) :: boolean()
  def session_killable?(sess, now, idle_seconds, busy) do
    String.starts_with?(sess.session, "devide_") and
      not sess.attached and
      not MapSet.member?(busy, sess.session) and
      now - sess.activity >= idle_seconds
  end

  defp schedule(ms), do: Process.send_after(self(), :sweep, ms)

  defp sweep_ms do
    case Application.get_env(:dev_ide, :tmux_window_sweep_ms) do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  defp window_idle_seconds, do: idle_seconds(:tmux_window_idle_seconds)
  defp session_idle_seconds, do: idle_seconds(:tmux_session_idle_seconds)

  defp idle_seconds(key) do
    case Application.get_env(:dev_ide, key) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_idle_seconds
    end
  end
end
