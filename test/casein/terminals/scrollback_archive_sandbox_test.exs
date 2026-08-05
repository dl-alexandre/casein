defmodule Casein.Terminals.ScrollbackArchiveSandboxTest do
  @moduledoc """
  Guards the suite-wide scrollback sandbox configured in `config/test.exs`.

  `ScrollbackArchive` defaults to `$HOME/.casein/tmux-scrollback` — the archive
  the *production* `-L casein` server reseeds from after a crash (see
  `docs/subsystems/tmux_crash_recovery.md`). Tests that create real tmux
  sessions spill one file per session and never reap them, so without the
  sandbox the suite writes production recovery state and grows unbounded (it
  reached 10,679 files / 488 MB on the devbox, 10,548 of them test sessions).

  `ScrollbackArchiveTest` overrides the dir in its own `setup`, so this asserts
  the property that holds no matter which test ran first: the archive dir is
  never inside `$HOME`.
  """
  use ExUnit.Case, async: false

  alias Casein.Terminals.ScrollbackArchive

  test "archive dir is sandboxed outside $HOME for the whole suite" do
    dir = ScrollbackArchive.archive_dir()

    case System.get_env("HOME") do
      home when is_binary(home) and home != "" ->
        refute String.starts_with?(Path.expand(dir), Path.expand(home)),
               """
               Test scrollback archive resolved inside $HOME: #{dir}

               The suite must never write into the production archive. Check
               that config/test.exs still sets :tmux_scrollback_archive_dir.
               """

      _ ->
        :ok
    end
  end

  test "sandbox survives app-env teardown via CASEIN_TMUX_SCROLLBACK_DIR" do
    # archive_dir/0 resolves app config → env var → $HOME at call time, and the
    # :casein app env is unloaded during VM shutdown. Without the env var,
    # scrollback spilled while the app stops lands in the production archive.
    # test_helper.exs mirrors the configured dir into the OS env for this.
    env_dir = System.get_env("CASEIN_TMUX_SCROLLBACK_DIR")

    assert is_binary(env_dir) and env_dir != "",
           "CASEIN_TMUX_SCROLLBACK_DIR must be set (see test_helper.exs) so the " <>
             "shutdown flush cannot fall back to $HOME/.casein/tmux-scrollback"

    case System.get_env("HOME") do
      home when is_binary(home) and home != "" ->
        refute String.starts_with?(Path.expand(env_dir), Path.expand(home))

      _ ->
        :ok
    end
  end
end
