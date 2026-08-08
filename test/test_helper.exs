# `:pty` tests attach real tmux PTYs and assert genuine PTY/owner-sharing
# invariants. They are reliable only on a PTY-stable host (e.g. devbox) and
# flake under load in sandboxes/CI. Excluded by default; run them explicitly
# where PTY is stable with: mix test --include pty
#
# Keep concurrency below PostgreSQL's per-container connection ceiling and the
# devbox's subprocess pressure ceiling. The default max_cases (scheduler count;
# 64 in this devbox) can temporarily open enough sandbox connections to hit
# FATAL 53300 "too many clients already", and the tmux-heavy tests can spawn
# enough children under shared-host load to trip erl_child_setup failures or VM
# crashes. Keep this conservative so full-suite/precommit runs are durable.
# assert_receive defaults to 100ms, which flakes under full-suite CPU contention
# on this multi-tenant box: tests that drive a LiveView event → fake adapter →
# message round-trip (e.g. the `{:fake_tmux_*}` pane-split assertions) usually
# complete in <100ms in isolation but occasionally miss the window under load,
# failing a different subtest each run. Raising the global grace to 1s costs
# passing tests nothing (assert_receive returns as soon as the message lands)
# and only extends the wait before a genuine failure. refute_receive keeps its
# own (short, explicit) timeouts, so negative assertions are unaffected.
# `CASEIN_GROK_BUNDLE_ROOT` / `CASEIN_GROK_LEADER_ROOT` are production operator
# overrides that `GrokCapabilityBundle` honors ahead of the `:casein` app env.
# A paired-agent shell (which launches Grok) exports them, so running the suite
# from such a shell leaks the live `/home/devbox/.casein/grok-*` roots into
# GrokCapabilityBundle/GrokACP tests — overriding the tmp roots those tests set
# via app env and failing them with `:unsafe_leader_directory` /
# `:invalid_grok_attachment_metadata`. CI never sets these (hence green there);
# clear them so local + precommit runs isolate from ambient env the same way.
for var <- ~w(CASEIN_GROK_BUNDLE_ROOT CASEIN_GROK_LEADER_ROOT) do
  System.delete_env(var)
end

# Close the scrollback sandbox over VM *shutdown*.
#
# config/test.exs sets :tmux_scrollback_archive_dir, but
# `ScrollbackArchive.archive_dir/0` resolves app config → env var → $HOME at
# *call* time, and the `:casein` app env is unloaded while the VM stops. Any
# spill during shutdown (SessionOwner terminate → put/2) therefore reads a nil
# app config and falls back to $HOME/.casein/tmux-scrollback — the production
# archive. That is exactly how test sessions kept landing there even with the
# config set: the writes all arrive in one burst in the final milliseconds of
# the run. `CASEIN_TMUX_SCROLLBACK_DIR` lives in the OS process env, which
# outlives app-env teardown, so it still resolves after config is gone.
case Application.get_env(:casein, :tmux_scrollback_archive_dir) do
  dir when is_binary(dir) and dir != "" -> System.put_env("CASEIN_TMUX_SCROLLBACK_DIR", dir)
  _ -> :ok
end

# One tmux server per test VM. `config/test.exs` pins the label to a fixed
# `casein_test`, which is correct for isolating the suite from live sessions but
# NOT for isolating concurrent suites from each other: this box routinely runs
# several at once (the deploy poller's gate, the self-hosted PR-gate runner, and
# an agent's local run all share it). They landed on one server, and the first
# to finish ran `kill-server` — see the reaping below — out from under the
# others. The victims surfaced it as `server exited unexpectedly` and
# `:start_failed, :pty_unavailable` in the live-tmux tests
# (workspace_pane_split_test.exs, workspace_live_test.exs), i.e. a red gate on a
# green tree. Suffixing with the OS pid makes the label unique among *live*
# runs, which is exactly the property the reaping needs. Applied before the app
# starts so `Casein.Terminals.TmuxServer.label/0` reads the per-run value.
#
# The base label still gets used for a moment: `mix test` starts the
# application *before* it evaluates this file, so anything tmux-ish during boot
# lands on the unsuffixed `casein_test` server. Remember the base label so the
# reaper below cleans up both, otherwise every run leaves one socket behind
# under a name no per-run reaper will ever look at.
casein_base_tmux_label = Application.get_env(:casein, :tmux_server_label)

if is_binary(casein_base_tmux_label) do
  Application.put_env(:casein, :tmux_server_label, "casein_test_#{System.pid()}")
end

ExUnit.start(
  exclude: [:pty, :tmux, :tidewave_available, :preview_e2e],
  max_cases: 4,
  assert_receive_timeout: 5_000
)

# Drain tests arm real grace/hard timeouts on the singleton Drain server;
# without this seam the timer fires ~3s later and System.stop(0) gracefully
# shuts down the VM MID-SUITE — silently truncated runs that still exit 0.
# (Root-caused 2026-06-12 after a day of "tests truncate under load".)
Application.put_env(:casein, :drain_stop_system, fn _status ->
  IO.puts(:stderr, "[test] Drain stop_system intercepted (would have stopped the VM)")
  :ok
end)

unless System.get_env("MIX_TEST_NO_START") in ["1", "true"] do
  {:ok, _} = Application.ensure_all_started(:casein)
end

# Reap the dedicated tmux server the suite runs on (`-L casein_test`, see
# config/test.exs) when the run finishes, so leaked test sessions don't pile up.
# Best-effort and scoped to the sandbox server — it can never touch the default
# server's live workspace sessions.
defmodule Casein.TestTmuxReaper do
  @moduledoc false

  # `tmux kill-server` stops the server but does NOT unlink its socket, and the
  # per-run `casein_test_<pid>` label means every single run left a fresh one
  # behind. 378 had accumulated in /tmp/tmux-1001 on the devbox — 283 from this
  # suite, still growing at ~28/day — which is also what makes the live server
  # list unreadable when triaging a real tmux problem. Remove the socket after
  # reaping the server.
  #
  # Deleting is safe precisely because the label carries the OS pid: no
  # concurrent suite, and no live workspace server, can be using this path.
  def socket_path(label) do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {out, 0} ->
        Path.join([System.get_env("TMUX_TMPDIR") || "/tmp", "tmux-#{String.trim(out)}", label])

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def reap(tmux \\ "tmux", labels) do
    labels
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.each(fn label ->
      _ = System.cmd(tmux, ["-L", label, "kill-server"], stderr_to_stdout: true)

      case socket_path(label) do
        nil -> :ok
        path -> File.rm(path)
      end
    end)

    :ok
  end
end

case {:os.type(), Casein.Terminals.TmuxServer.label()} do
  {{:win32, _}, _label} ->
    :ok

  {_os, label} when is_binary(label) ->
    System.at_exit(fn _ ->
      Casein.TestTmuxReaper.reap([label, casein_base_tmux_label])
    end)

  _other ->
    :ok
end

# When run with `--no-start` (e.g. for pure unit tests under memory pressure),
# the Repo isn't running — skip sandbox setup rather than crash on boot.
if Process.whereis(Casein.Repo) do
  # Shared-box heal: unfinished attention branches (#698) have rewritten
  # mobile_attention_cursors_scope_index to include subject_kind. Master code
  # still ON CONFLICT (user_id, origin_id, card_id). When the live index does
  # not match that target, mark_viewed/5 raises 42P10 and the cover gate goes
  # red for every PR sharing casein_test — not just the attention lane.
  # Restore the master unique scope without dropping polluted columns.
  #
  # MUST run before Sandbox.mode(:manual). After :manual, Repo.query/1 without
  # a checkout returns OwnershipError, the case falls through to _other, and
  # the heal is a silent no-op — which is exactly how master stayed red.
  if function_exported?(Casein.Repo, :query, 1) do
    case Casein.Repo.query("""
         SELECT indexdef FROM pg_indexes
         WHERE tablename = 'mobile_attention_cursors'
           AND indexname = 'mobile_attention_cursors_scope_index'
         """) do
      {:ok, %{rows: [[def]]}} when is_binary(def) ->
        if String.contains?(def, "subject_kind") do
          _ = Casein.Repo.query("DROP INDEX IF EXISTS mobile_attention_cursors_user_kind_index")
          _ = Casein.Repo.query("DROP INDEX IF EXISTS mobile_attention_cursors_scope_index")

          _ =
            Casein.Repo.query("""
            CREATE UNIQUE INDEX mobile_attention_cursors_scope_index
            ON mobile_attention_cursors (user_id, origin_id, card_id)
            """)
        end

      _other ->
        :ok
    end
  end

  Ecto.Adapters.SQL.Sandbox.mode(Casein.Repo, :manual)
end

ExUnit.after_suite(fn _result ->
  # Some LiveView/PTY tests intentionally attach real tmux clients. If a test
  # process crashes after spawning the client but before its on_exit cleanup,
  # tmux can retain blank `casein_*` sessions indefinitely. Keep this limited
  # to synthetic test prefixes so local user/workspace sessions are untouched.
  test_session? = fn session ->
    Regex.match?(
      ~r/^casein_(alpha-\d+|hdr-ws-\d+|prevobs-ws-\d+|ws-dupe-\d+|ws-mode-transition-\d+|ws-open-close-\d+|leader-\d+|pane-link-\d+|dead-link-\d+|raw-stale-\d+|stale-\d+)_/,
      session
    ) or session == "casein_ws-adapter_sid-adapter"
  end

  if tmux = not match?({:win32, _}, :os.type()) && System.find_executable("tmux") do
    with {sessions, 0} <- System.cmd(tmux, ["list-sessions", "-F", "\#{session_name}"]) do
      sessions
      |> String.split("\n", trim: true)
      |> Enum.filter(test_session?)
      |> Enum.each(fn session ->
        _ = System.cmd(tmux, ["kill-session", "-t", session], stderr_to_stdout: true)
      end)
    end

    # Reap this run's own server only — a hardcoded label here would both miss
    # the per-run server and kill a concurrent suite's. Goes through the reaper
    # so the socket file is unlinked too, not just the server stopped.
    case Casein.Terminals.TmuxServer.label() do
      label when is_binary(label) ->
        Casein.TestTmuxReaper.reap(tmux, [label, casein_base_tmux_label])

      _ ->
        :ok
    end
  end

  :ok
end)
