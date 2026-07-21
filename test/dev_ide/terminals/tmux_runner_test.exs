defmodule DevIDE.Terminals.TmuxRunnerTest do
  # async: false — mutates Application/System env, PATH, and :persistent_term
  # (the same global state the sibling DevIDE.Terminals.TmuxTest guards).
  use DevIDE.TestCase, async: false

  alias DevIDE.Terminals.TmuxExecutable
  alias DevIDE.Terminals.TmuxRunner
  alias DevIDE.Terminals.TmuxServer

  setup do
    workspace_source = Application.get_env(:dev_ide, :workspace_source)
    tmux_host_shell = Application.get_env(:dev_ide, :tmux_host_shell)
    tmux_config_file_dev = Application.get_env(:dev_ide, :tmux_config_file)
    tmux_config_file_ctl = Application.get_env(:tmux_ctl, :config_file)
    env_host_shell = System.get_env("DEV_IDE_TMUX_HOST_SHELL")
    env_config = System.get_env("DEV_IDE_TMUX_CONFIG")
    path = System.get_env("PATH")

    on_exit(fn ->
      put_or_delete_env("DEV_IDE_TMUX_HOST_SHELL", env_host_shell)
      put_or_delete_env("DEV_IDE_TMUX_CONFIG", env_config)
      put_or_delete_env("PATH", path)
      put_or_delete_app_env(:dev_ide, :workspace_source, workspace_source)
      put_or_delete_app_env(:dev_ide, :tmux_host_shell, tmux_host_shell)
      put_or_delete_app_env(:dev_ide, :tmux_config_file, tmux_config_file_dev)
      put_or_delete_app_env(:tmux_ctl, :config_file, tmux_config_file_ctl)
    end)

    :ok
  end

  describe "host_shell?/0" do
    test "true when the :dev_ide app env flag is set" do
      Application.put_env(:dev_ide, :tmux_host_shell, true)
      System.delete_env("DEV_IDE_TMUX_HOST_SHELL")

      assert TmuxRunner.host_shell?()
    end

    test "true when the OS env var is an affirmative token" do
      Application.put_env(:dev_ide, :tmux_host_shell, false)
      System.put_env("DEV_IDE_TMUX_HOST_SHELL", "yes")

      assert TmuxRunner.host_shell?()
    end

    test "falsey when neither source opts in" do
      Application.put_env(:dev_ide, :tmux_host_shell, false)
      System.put_env("DEV_IDE_TMUX_HOST_SHELL", "0")

      refute TmuxRunner.host_shell?()
    end
  end

  describe "argv/2 in host-shell mode" do
    setup do
      # Force the host branch and avoid any has-session shellout from the
      # session-target heuristic by never passing a -t target in these cases.
      Application.put_env(:dev_ide, :tmux_host_shell, true)
      System.delete_env("DEV_IDE_TMUX_CONFIG")
      Application.delete_env(:dev_ide, :tmux_config_file)
      Application.delete_env(:tmux_ctl, :config_file)
      :ok
    end

    test "prepends tmux + server args and the default config file when none is configured" do
      argv = TmuxRunner.argv(["list-sessions"])

      tmux = TmuxExecutable.resolve()
      assert [^tmux | rest] = argv
      assert Enum.take(rest, length(TmuxServer.args())) == TmuxServer.args()
      assert List.last(argv) == "list-sessions"
      # The bundled priv/tmux/devide.conf resolves as the default config file.
      assert "-f" in argv
      assert Enum.any?(argv, &String.ends_with?(&1, "devide.conf"))
    end

    test "host_argv/1 is the shared foreground attach argv and includes config" do
      dir = make_tmp_dir()
      config = Path.join(dir, "devide.conf")
      File.write!(config, "set-option -g status off\n")

      Application.put_env(:tmux_ctl, :config_file, config)

      assert [TmuxExecutable.resolve()] ++
               TmuxServer.args() ++
               ["-f", config, "new-session", "-A", "-s", "devide_alpha_u-dev"] ==
               TmuxRunner.host_argv(["new-session", "-A", "-s", "devide_alpha_u-dev"])
    end

    test "inserts -f <config> when a tmux config file is configured" do
      dir = make_tmp_dir()
      config = Path.join(dir, "devide.conf")
      File.write!(config, "set-option -g status off\n")

      Application.put_env(:tmux_ctl, :config_file, config)

      assert [TmuxExecutable.resolve()] ++ TmuxServer.args() ++ ["-f", config, "kill-server"] ==
               TmuxRunner.argv(["kill-server"])
    end

    test "prefers the :dev_ide config file and resolves it from the OS env too" do
      dir = make_tmp_dir()
      config = Path.join(dir, "from_env.conf")
      File.write!(config, "set -g mouse on\n")

      # tmux_ctl key unset; DEV_IDE_TMUX_CONFIG env should be picked up.
      System.put_env("DEV_IDE_TMUX_CONFIG", config)

      argv = TmuxRunner.argv(["display-message"])
      assert "-f" in argv
      assert config in argv
    end

    test "skips a configured path that is not a regular file, falling back to the default" do
      Application.put_env(:tmux_ctl, :config_file, "/no/such/devide.conf")

      argv = TmuxRunner.argv(["list-windows"])
      # The bad configured path is skipped...
      refute "/no/such/devide.conf" in argv
      # ...and resolution falls back to the bundled default config.
      assert Enum.any?(argv, &String.ends_with?(&1, "devide.conf"))
    end
  end

  describe "argv/2 container-wrapping branch" do
    setup do
      Application.put_env(:dev_ide, :tmux_host_shell, false)
      System.delete_env("DEV_IDE_TMUX_HOST_SHELL")
      Application.put_env(:dev_ide, :workspace_source, DevIDE.Test.WrappingWorkspaceSource)
      :ok
    end

    test "wraps the full tmux argv through the workspace source (no cwd)" do
      # WrappingWorkspaceSource ignores its argv and returns a fixed wrapper,
      # proving the no-cwd container branch routed through prepare_local_argv/1.
      assert ["sh", "-c", _] = TmuxRunner.argv(["list-sessions"])
    end

    test "wraps with cwd opt when a non-empty cwd is supplied" do
      assert ["sh", "-c", _] = TmuxRunner.argv(["new-window"], cwd: "/host/workspace")
    end

    test "treats an empty cwd as the no-cwd branch" do
      assert ["sh", "-c", _] = TmuxRunner.argv(["new-window"], cwd: "")
    end
  end

  describe "argv/2 direct local branch" do
    setup do
      Application.put_env(:dev_ide, :tmux_host_shell, false)
      System.delete_env("DEV_IDE_TMUX_HOST_SHELL")
      Application.put_env(:dev_ide, :workspace_source, DevIDE.WorkspaceSource.Local)
      :ok
    end

    test "uses host tmux argv with DevIDE config when the workspace source is identity" do
      dir = make_tmp_dir()
      config = Path.join(dir, "devide.conf")
      File.write!(config, "set-option -g status off\n")
      Application.put_env(:tmux_ctl, :config_file, config)

      assert [TmuxExecutable.resolve()] ++
               TmuxServer.args() ++
               ["-f", config, "new-session", "-d", "-s", "devide_home_u-dev"] ==
               TmuxRunner.argv(["new-session", "-d", "-s", "devide_home_u-dev"],
                 cwd: "/home/alexandre"
               )
    end
  end

  describe "argv/2 host-session-target detection" do
    test "a live host session forces the host branch even when not in host-shell mode" do
      put_fake_tmux("""
      #!/bin/sh
      for a in "$@"; do
        [ "$a" = "has-session" ] && exit 0
      done
      exit 1
      """)

      Application.put_env(:dev_ide, :tmux_host_shell, false)
      System.delete_env("DEV_IDE_TMUX_HOST_SHELL")
      Application.put_env(:dev_ide, :workspace_source, DevIDE.Test.WrappingWorkspaceSource)

      # -t names an existing host session, so host_session_alive? returns true
      # and we get host tmux argv (not the wrapper's ["sh", ...]).
      argv = TmuxRunner.argv(["send-keys", "-t", "devide_alpha_u-dev:0", "echo hi"])
      tmux = TmuxExecutable.resolve()
      assert [^tmux | _] = argv
      assert "send-keys" in argv
    end

    test "a dead host session falls through to the container wrapper" do
      put_fake_tmux("""
      #!/bin/sh
      exit 1
      """)

      Application.put_env(:dev_ide, :tmux_host_shell, false)
      System.delete_env("DEV_IDE_TMUX_HOST_SHELL")
      Application.put_env(:dev_ide, :workspace_source, DevIDE.Test.WrappingWorkspaceSource)

      assert ["sh", "-c", _] =
               TmuxRunner.argv(["send-keys", "-t", "devide_alpha_u-dev", "echo hi"])
    end

    test "argv without a -t target never probes for a session and wraps" do
      Application.put_env(:dev_ide, :tmux_host_shell, false)
      System.delete_env("DEV_IDE_TMUX_HOST_SHELL")
      Application.put_env(:dev_ide, :workspace_source, DevIDE.Test.WrappingWorkspaceSource)

      assert ["sh", "-c", _] = TmuxRunner.argv(["list-windows", "-a"])
    end
  end

  describe "run/2" do
    test "builds argv and executes it, returning {output, exit_status}" do
      # WrappingWorkspaceSource resolves to a real, harmless `sh` invocation:
      #   sh -c 'printf wrapped >&2; exit 42'
      # so System.cmd runs for real with stderr folded into stdout.
      Application.put_env(:dev_ide, :tmux_host_shell, false)
      System.delete_env("DEV_IDE_TMUX_HOST_SHELL")
      Application.put_env(:dev_ide, :workspace_source, DevIDE.Test.WrappingWorkspaceSource)

      assert {out, 42} = TmuxRunner.run(["list-sessions"])
      assert out =~ "wrapped"
    end

    test "passes :cd through to System.cmd opts" do
      Application.put_env(:dev_ide, :tmux_host_shell, false)
      System.delete_env("DEV_IDE_TMUX_HOST_SHELL")
      Application.put_env(:dev_ide, :workspace_source, DevIDE.Test.WrappingWorkspaceSource)

      dir = make_tmp_dir()
      assert {_out, 42} = TmuxRunner.run(["list-sessions"], cd: dir)
    end
  end

  describe "local_argv_wrapped?/0" do
    test "returns false for direct local identity execution" do
      Application.put_env(:dev_ide, :workspace_source, DevIDE.WorkspaceSource.Local)

      refute TmuxRunner.local_argv_wrapped?()
    end

    test "returns true when the workspace source wraps local argv" do
      Application.put_env(:dev_ide, :workspace_source, DevIDE.Test.WrappingWorkspaceSource)

      assert TmuxRunner.local_argv_wrapped?()
    end
  end

  describe "container_has_tmux?/1" do
    test "returns true for direct local identity execution" do
      Application.put_env(:dev_ide, :workspace_source, DevIDE.WorkspaceSource.Local)
      cwd = unique_cwd()

      assert TmuxRunner.container_has_tmux?(cwd)
    end

    test "returns true via the sh-wrapped probe and caches the result" do
      # Any source whose wrapper begins with "sh" short-circuits to true without
      # any System.cmd. Use a unique cwd so the :persistent_term cache key is
      # private to this test.
      Application.put_env(:dev_ide, :workspace_source, DevIDE.Test.WrappingWorkspaceSource)
      cwd = unique_cwd()

      assert TmuxRunner.container_has_tmux?(cwd)
      # Second call hits the cached branch (still true).
      assert TmuxRunner.container_has_tmux?(cwd)
    end
  end

  ## helpers

  defp make_tmp_dir do
    dir = Path.join(System.tmp_dir!(), "devide-tmuxrunner-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp put_fake_tmux(script) do
    dir = make_tmp_dir()
    tmux_bin = Path.join(dir, "tmux")
    File.write!(tmux_bin, script)
    File.chmod!(tmux_bin, 0o755)
    System.put_env("PATH", dir <> ":" <> (System.get_env("PATH") || ""))
    dir
  end

  defp unique_cwd do
    cwd = "/tmp/devide-tmuxrunner-probe-#{System.unique_integer([:positive])}"
    key = {TmuxRunner, :container_tmux, cwd}
    on_exit(fn -> :persistent_term.erase(key) end)
    cwd
  end

  defp put_or_delete_env(name, nil), do: System.delete_env(name)
  defp put_or_delete_env(name, value), do: System.put_env(name, value)

  defp put_or_delete_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp put_or_delete_app_env(app, key, value), do: Application.put_env(app, key, value)
end
