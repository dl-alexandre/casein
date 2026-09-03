defmodule Casein.Terminals.TmuxWindowJanitor do
  @moduledoc """
  Periodic sweep that reaps blank, auto-named, never-used tmux windows that
  accumulate inside `casein_*` sessions.

  This complements `Casein.Terminals.TmuxJanitor` (which is subscriber-driven
  and works at the *session* level): the subscriber bookkeeping is in-memory and
  lost on a server restart, and it never reaches *inside* a session to trim the
  extra windows a user spins up (tmux `Ctrl-b c`) and abandons. This sweep is the
  safety net for those.

  It also reaps whole **orphaned sessions** — blank `casein_*` sessions with no
  attached client, idle past `:tmux_session_idle_seconds`, where every pane is
  just a shell. These are the per-tab sessions abandoned by closed tabs and the
  ones left dangling after a restart wiped the reactive janitor's subscriber
  map. Per-tab independence is preserved: an attached session (a live viewer) is
  never touched.

  Finally — and only when `:tmux_agent_idle_seconds` is configured — it reaps
  **idle agent panes**: an `opencode`/`claude`/`codex`/`grok` sitting at its
  prompt in a session nobody is attached to, untouched for hours, in a worktree
  with nothing unsaved. Neither rule above can reach these (an agent is not a
  shell, so its session counts as busy), which is how a host accumulates dozens
  of resident agents from tabs closed days ago — each holding a few GB — until
  the box runs out of memory (devbox, 2026-08-27).

  Two populations sit outside all three rules by construction: an agent with no
  tmux pane among its ancestors, which nothing here can reach at any timeout,
  and an agent in a session with an attached client, which a live viewer always
  wins. `Casein.Terminals.AgentResidency` and `mix casein.agents.residency`
  enumerate the first, so its size is measured rather than counted by hand.

  ## Kill policy — a window is reaped only when ALL hold

    * its session name starts with `casein_` (never touch foreign sessions);
    * `automatic_rename` is on — i.e. the user never named it. The moment a
      user renames a window (`Ctrl-b ,`) tmux turns automatic-rename off, so a
      named window is permanently safe;
    * it is **not** the active window of its session (which also guarantees the
      session has another window, so we never kill the last one and destroy the
      session);
    * it has exactly one pane whose foreground command is a login/interactive
      shell — nothing is running in it;
    * it has been idle (no activity) for at least `:tmux_window_idle_seconds`.

  ## Kill policy — an idle agent window is reaped only when ALL hold

    * its session name starts with `casein_`;
    * its session has **no attached client** — a live viewer always wins;
    * it has exactly one pane, whose foreground command is a known agent
      binary (`claude`, `grok`, `codex`, `opencode`);
    * it has been idle for at least `:tmux_agent_idle_seconds`;
    * the pane's current directory is a git worktree with a **clean** status
      (nothing modified, nothing untracked). Anything unsaved is left alone,
      mirroring the agent-worktree reaper. A directory that is not a git
      repository, or whose status cannot be read, is treated as dirty.

  An agent window that is its session's only window takes the whole session
  with it (via `kill/1`, so the scrollback archive is dropped too); otherwise
  just the window is killed.

  ## Configuration

    * `:tmux_window_sweep_ms` — sweep interval in ms; `nil`/`0` disables the
      janitor entirely (no sweep ever runs). Default `nil`.
    * `:tmux_window_idle_seconds` — minimum idle age before a window is
      eligible. Default `600`.
    * `:tmux_session_idle_seconds` — minimum idle age before an orphaned
      session is eligible. Default `600`.
    * `:tmux_agent_idle_seconds` — minimum idle age before an unattached agent
      window is eligible. `nil`/`0` disables agent reaping (the default).
    * `:tmux_agent_worktree_clean_fn` — `(path -> boolean)` override for the
      clean-worktree check. Tests only; defaults to `git_worktree_clean?/1`.
  """
  use GenServer

  require Logger

  alias Casein.Terminals.Backend

  @default_idle_seconds 600

  # Foreground commands that mean "just a shell sitting at a prompt". A window
  # running anything else (vim, a build, a REPL, ssh…) reports that command
  # instead and is left alone.
  @shells ~w(bash zsh sh fish dash ash -bash -zsh -sh -fish)

  # Foreground commands that are an agent TUI. tmux reports the process comm,
  # so a binary shipped as `claude.exe` shows up as `claude_exe`; normalise by
  # dropping any extension-ish suffix before matching.
  @agent_processes ~w(claude grok codex opencode)

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Run a sweep now and return the number of windows killed. Mainly for tests/ops."
  @spec sweep_now() :: non_neg_integer()
  def sweep_now, do: GenServer.call(__MODULE__, :sweep_now)

  @doc """
  Return the windows, sessions and agent windows that would be reaped by the
  current policy.

  This is the dry-run surface for ops scripts and diagnostics. It performs the
  same tmux inventory reads as `sweep_now/0`, but never mutates tmux.
  """
  @spec dry_run_now() :: %{
          total: non_neg_integer(),
          windows: [map()],
          sessions: [map()],
          agents: [map()]
        }
  def dry_run_now, do: GenServer.call(__MODULE__, :dry_run_now)

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

  def handle_call(:dry_run_now, _from, state) do
    {:reply, candidates(System.system_time(:second)), state}
  end

  ## Internals

  defp run_sweep do
    now = System.system_time(:second)
    candidates = candidates(now)

    sweep_windows(candidates.windows) + sweep_sessions(candidates.sessions) +
      sweep_agents(candidates.agents)
  end

  defp candidates(now) do
    window_idle = window_idle_seconds()
    session_idle = session_idle_seconds()
    agent_idle = agent_idle_seconds()
    busy = busy_sessions()

    all_windows = tmux().list_windows()
    all_sessions = tmux().list_sessions()

    windows =
      all_windows
      |> Enum.filter(&killable?(&1, now, window_idle))
      |> Enum.map(&window_candidate(&1, now, window_idle))

    sessions =
      all_sessions
      |> Enum.filter(&session_killable?(&1, now, session_idle, busy))
      |> Enum.map(&session_candidate(&1, now, session_idle))

    agents =
      if agent_idle do
        attached = attached_sessions(all_sessions)
        window_counts = Enum.frequencies_by(all_windows, & &1.session)

        all_windows
        |> Enum.filter(&agent_killable?(&1, now, agent_idle, attached))
        |> Enum.filter(&worktree_clean?(Map.get(&1, :current_path)))
        |> Enum.map(&agent_candidate(&1, now, agent_idle, window_counts))
      else
        []
      end

    %{
      total: length(windows) + length(sessions) + length(agents),
      windows: windows,
      sessions: sessions,
      agents: agents
    }
  end

  # Trim extra blank auto-named windows (leaves the active window — so a session
  # is never emptied here; whole-session reaping is sweep_sessions/1's job).
  defp sweep_windows(windows) do
    Enum.reduce(windows, 0, fn win, killed ->
      case Backend.module().kill_window(win.session, win.window_id) do
        :ok ->
          Logger.info(
            "TmuxWindowJanitor: killed blank idle window #{win.session}:#{win.window_id} " <>
              "(cmd=#{win.current_command}, idle≥#{win.idle_threshold_seconds}s)"
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

  # Reap whole orphaned sessions: casein_*, unattached, idle, and blank (every
  # pane is a shell). `busy` is the set of sessions with at least one non-shell
  # pane — those are spared regardless of attach/idle state.
  defp sweep_sessions(sessions) do
    Enum.reduce(sessions, 0, fn sess, killed ->
      case Backend.module().kill(sess.session) do
        {_, 0} ->
          Logger.info(
            "TmuxWindowJanitor: killed orphaned idle session #{sess.session} " <>
              "(idle≥#{sess.idle_threshold_seconds}s)"
          )

          killed + 1

        :ok ->
          Logger.info(
            "TmuxWindowJanitor: killed orphaned idle session #{sess.session} " <>
              "(idle≥#{sess.idle_threshold_seconds}s)"
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

  # Reap idle, unattached agent windows whose worktree is clean. When the agent
  # window is the last one in its session, kill the session so the scrollback
  # archive goes with it (kill_window on the last window would leave it behind).
  defp sweep_agents(agents) do
    Enum.reduce(agents, 0, fn agent, killed ->
      result =
        if agent.last_window,
          do: Backend.module().kill(agent.session),
          else: Backend.module().kill_window(agent.session, agent.window_id)

      case result do
        ok when ok == :ok or (is_tuple(ok) and elem(ok, 1) == 0) ->
          Logger.info(
            "TmuxWindowJanitor: killed idle agent window #{agent.session}:#{agent.window_id} " <>
              "(cmd=#{agent.current_command}, idle≥#{agent.idle_threshold_seconds}s, " <>
              "clean worktree=#{agent.current_path}" <>
              if(agent.last_window, do: ", last window → session killed)", else: ")")
          )

          killed + 1

        other ->
          Logger.warning(
            "TmuxWindowJanitor: kill agent #{agent.session}:#{agent.window_id} failed: " <>
              inspect(other)
          )

          killed
      end
    end)
  end

  # Sessions that have any pane running something other than a bare shell.
  defp busy_sessions do
    tmux().list_panes()
    |> Enum.reduce(MapSet.new(), fn {session, cmd}, acc ->
      if cmd in @shells, do: acc, else: MapSet.put(acc, session)
    end)
  end

  defp attached_sessions(sessions) do
    sessions
    |> Enum.filter(& &1.attached)
    |> MapSet.new(& &1.session)
  end

  @doc false
  @spec killable?(map(), integer(), non_neg_integer()) :: boolean()
  def killable?(win, now, idle_seconds) do
    String.starts_with?(win.session, "casein_") and
      win.automatic_rename and
      not win.active and
      win.panes == 1 and
      win.current_command in @shells and
      now - win.activity >= idle_seconds
  end

  @doc false
  @spec session_killable?(map(), integer(), non_neg_integer(), MapSet.t()) :: boolean()
  def session_killable?(sess, now, idle_seconds, busy) do
    String.starts_with?(sess.session, "casein_") and
      not sess.attached and
      not MapSet.member?(busy, sess.session) and
      now - sess.activity >= idle_seconds
  end

  @doc false
  @spec agent_killable?(map(), integer(), non_neg_integer(), MapSet.t()) :: boolean()
  def agent_killable?(win, now, idle_seconds, attached) do
    String.starts_with?(win.session, "casein_") and
      not MapSet.member?(attached, win.session) and
      win.panes == 1 and
      agent_process?(win.current_command) and
      now - win.activity >= idle_seconds
  end

  @doc false
  @spec agent_process?(String.t() | nil) :: boolean()
  def agent_process?(cmd) when is_binary(cmd) do
    base =
      cmd
      |> Path.basename()
      |> String.replace(~r/[._-](exe|bin|js)$/i, "")

    base in @agent_processes
  end

  def agent_process?(_), do: false

  @doc """
  True only when `path` is a git worktree whose status is completely clean —
  no modified, staged or untracked files. Any failure (not a repo, git missing,
  unreadable) is reported as *not clean* so the janitor errs towards sparing.
  """
  @spec git_worktree_clean?(String.t() | nil) :: boolean()
  def git_worktree_clean?(path) when is_binary(path) and path != "" do
    if File.dir?(path) do
      case System.cmd(
             "git",
             ["-C", path, "status", "--porcelain", "--untracked-files=normal"],
             stderr_to_stdout: true
           ) do
        {"", 0} -> true
        _ -> false
      end
    else
      false
    end
  rescue
    _ -> false
  end

  def git_worktree_clean?(_), do: false

  defp worktree_clean?(path) do
    case Application.get_env(:casein, :tmux_agent_worktree_clean_fn) do
      fun when is_function(fun, 1) -> fun.(path)
      _ -> git_worktree_clean?(path)
    end
  end

  defp window_candidate(win, now, idle) do
    win
    |> Map.take([:session, :window_id, :current_command, :activity])
    |> Map.merge(%{
      reason: :blank_idle_window,
      age_seconds: max(now - win.activity, 0),
      idle_threshold_seconds: idle
    })
  end

  defp session_candidate(sess, now, idle) do
    sess
    |> Map.take([:session, :activity])
    |> Map.merge(%{
      reason: :blank_orphan_session,
      age_seconds: max(now - sess.activity, 0),
      idle_threshold_seconds: idle
    })
  end

  defp agent_candidate(win, now, idle, window_counts) do
    win
    |> Map.take([:session, :window_id, :current_command, :activity])
    |> Map.merge(%{
      reason: :idle_agent_window,
      current_path: Map.get(win, :current_path),
      last_window: Map.get(window_counts, win.session, 1) <= 1,
      age_seconds: max(now - win.activity, 0),
      idle_threshold_seconds: idle
    })
  end

  defp schedule(ms), do: Process.send_after(self(), :sweep, ms)

  defp tmux, do: Casein.Terminals.tmux_adapter()

  defp sweep_ms do
    case Application.get_env(:casein, :tmux_window_sweep_ms) do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  defp window_idle_seconds, do: idle_seconds(:tmux_window_idle_seconds)
  defp session_idle_seconds, do: idle_seconds(:tmux_session_idle_seconds)

  # Agent reaping is opt-in: unset/zero means "never touch agent panes".
  defp agent_idle_seconds do
    case Application.get_env(:casein, :tmux_agent_idle_seconds) do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  defp idle_seconds(key) do
    case Application.get_env(:casein, key) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_idle_seconds
    end
  end
end
