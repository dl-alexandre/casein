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
# `DEVIDE_GROK_BUNDLE_ROOT` / `DEVIDE_GROK_LEADER_ROOT` are production operator
# overrides that `GrokCapabilityBundle` honors ahead of the `:casein` app env.
# A paired-agent shell (which launches Grok) exports them, so running the suite
# from such a shell leaks the live `/home/devbox/.casein/grok-*` roots into
# GrokCapabilityBundle/GrokACP tests — overriding the tmp roots those tests set
# via app env and failing them with `:unsafe_leader_directory` /
# `:invalid_grok_attachment_metadata`. CI never sets these (hence green there);
# clear them so local + precommit runs isolate from ambient env the same way.
for var <- ~w(DEVIDE_GROK_BUNDLE_ROOT DEVIDE_GROK_LEADER_ROOT) do
  System.delete_env(var)
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

# Reap the dedicated tmux server the suite runs on (`-L devide_test`, see
# config/test.exs) when the run finishes, so leaked test sessions don't pile up.
# Best-effort and scoped to the sandbox server — it can never touch the default
# server's live workspace sessions.
case {:os.type(), Casein.Terminals.TmuxServer.label()} do
  {{:win32, _}, _label} ->
    :ok

  {_os, label} when is_binary(label) ->
    System.at_exit(fn _ ->
      _ = System.cmd("tmux", ["-L", label, "kill-server"], stderr_to_stdout: true)
    end)

  _other ->
    :ok
end

# When run with `--no-start` (e.g. for pure unit tests under memory pressure),
# the Repo isn't running — skip sandbox setup rather than crash on boot.
if Process.whereis(Casein.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(Casein.Repo, :manual)
end

ExUnit.after_suite(fn _result ->
  # Some LiveView/PTY tests intentionally attach real tmux clients. If a test
  # process crashes after spawning the client but before its on_exit cleanup,
  # tmux can retain blank `devide_*` sessions indefinitely. Keep this limited
  # to synthetic test prefixes so local user/workspace sessions are untouched.
  test_session? = fn session ->
    Regex.match?(
      ~r/^devide_(alpha-\d+|hdr-ws-\d+|prevobs-ws-\d+|ws-dupe-\d+|ws-mode-transition-\d+|ws-open-close-\d+|leader-\d+|pane-link-\d+|dead-link-\d+|raw-stale-\d+|stale-\d+)_/,
      session
    ) or session == "devide_ws-adapter_sid-adapter"
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

    _ = System.cmd(tmux, ["-L", "devide_test", "kill-server"], stderr_to_stdout: true)
  end

  :ok
end)
