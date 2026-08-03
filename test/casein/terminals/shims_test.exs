defmodule Casein.Terminals.ShimsTest do
  use Casein.TestCase, async: false

  alias Casein.Terminals.Shims

  setup do
    previous_dir = Application.get_env(:casein, :terminal_shims_dir)
    previous_tool_root = Application.get_env(:casein, :terminal_tools_dir)

    previous_desktop_enabled =
      Application.get_env(:casein, :terminal_desktop_integration_enabled)

    previous_desktop_entries_dir = Application.get_env(:casein, :terminal_desktop_entries_dir)
    previous_mimeapps_path = Application.get_env(:casein, :terminal_mimeapps_path)
    tmp = Path.join(System.tmp_dir!(), "casein-shims-test-#{System.unique_integer([:positive])}")
    shim_dir = Path.join(tmp, "shims")
    tool_root = Path.join(tmp, "tools")
    real_dir = Path.join(tmp, "real")
    clean_bin = Path.join(tmp, "bin")
    desktop_dir = Path.join(tmp, "applications")
    mimeapps_path = Path.join(tmp, "mimeapps.list")

    Application.put_env(:casein, :terminal_shims_dir, shim_dir)
    Application.put_env(:casein, :terminal_tools_dir, tool_root)
    Application.put_env(:casein, :terminal_desktop_integration_enabled, false)
    Application.put_env(:casein, :terminal_desktop_entries_dir, desktop_dir)
    Application.put_env(:casein, :terminal_mimeapps_path, mimeapps_path)
    File.mkdir_p!(real_dir)
    write_clean_bin!(clean_bin)

    on_exit(fn ->
      restore(:terminal_shims_dir, previous_dir)
      restore(:terminal_tools_dir, previous_tool_root)
      restore(:terminal_desktop_integration_enabled, previous_desktop_enabled)
      restore(:terminal_desktop_entries_dir, previous_desktop_entries_dir)
      restore(:terminal_mimeapps_path, previous_mimeapps_path)
      File.rm_rf(tmp)
    end)

    {:ok,
     shim_dir: shim_dir,
     tool_root: tool_root,
     real_dir: real_dir,
     clean_bin: clean_bin,
     desktop_dir: desktop_dir,
     mimeapps_path: mimeapps_path,
     tmp: tmp}
  end

  test "materializes casein-open shim and markdown desktop default", %{
    desktop_dir: desktop_dir,
    mimeapps_path: mimeapps_path
  } do
    assert :ok = Shims.materialize!(["casein-open"], desktop?: true)

    shim = Shims.shim_path("casein-open")
    assert File.regular?(shim)

    script = File.read!(shim)
    assert script =~ "CASEIN_API_BASE_URL"
    assert script =~ "/api/workspaces/${workspace_id}/open"
    assert script =~ "--max-time 5"

    desktop_entry = Path.join(desktop_dir, "casein-preview.desktop")
    assert File.regular?(desktop_entry)

    desktop = File.read!(desktop_entry)
    assert desktop =~ "Name=Casein Preview"
    assert desktop =~ "Exec=casein-open %f"
    assert desktop =~ "Terminal=true"
    assert desktop =~ "MimeType=text/markdown;text/x-markdown;"

    mimeapps = File.read!(mimeapps_path)
    assert mimeapps =~ "[Default Applications]"
    assert mimeapps =~ "text/markdown=casein-preview.desktop"
    assert mimeapps =~ "text/x-markdown=casein-preview.desktop"
  end

  test "casein-open posts the target and current directory to the open API", %{
    clean_bin: clean_bin,
    real_dir: real_dir,
    tmp: tmp
  } do
    workdir = Path.join(tmp, "workspace")
    File.mkdir_p!(workdir)
    write_fake_curl!(real_dir)
    Shims.materialize!(["casein-open"])

    capture = Path.join(tmp, "curl.capture")

    {out, 0} =
      System.cmd(Shims.shim_path("casein-open"), ["docs/readme.md"],
        cd: workdir,
        env: [
          {"PATH", Enum.join([real_dir, clean_bin], ":")},
          {"CASEIN_API_BASE_URL", "http://casein.test"},
          {"CASEIN_WORKSPACE_ID", "ws-open"},
          {"CASEIN_API_TOKEN", "open-token"},
          {"CASEIN_FAKE_CURL_CAPTURE", capture}
        ],
        stderr_to_stdout: true
      )

    assert out == "Opened docs/readme.md in Casein viewer\n"
    {canonical_workdir, 0} = System.cmd("pwd", [], cd: workdir)

    assert File.read!(capture) ==
             "http://casein.test/api/workspaces/ws-open/open\n5\n" <>
               ~s({"target":"docs/readme.md","base_dir":"#{String.trim(canonical_workdir)}"}) <>
               "\n"
  end

  test "casein-open rejects targets with control characters before curl", %{
    clean_bin: clean_bin,
    tmp: tmp
  } do
    workdir = Path.join(tmp, "workspace")
    File.mkdir_p!(workdir)
    Shims.materialize!(["casein-open"])

    capture = Path.join(tmp, "curl.capture")

    {out, 64} =
      System.cmd(Shims.shim_path("casein-open"), ["docs/\nreadme.md"],
        cd: workdir,
        env: [
          {"PATH", clean_bin},
          {"CASEIN_API_BASE_URL", "http://casein.test"},
          {"CASEIN_WORKSPACE_ID", "ws-open"},
          {"CASEIN_API_TOKEN", "open-token"},
          {"CASEIN_FAKE_CURL_CAPTURE", capture}
        ],
        stderr_to_stdout: true
      )

    assert out =~ "casein-open: target contains unsupported control characters"
    refute File.exists?(capture)
  end

  test "materializes an elio shim that enables OSC52 lazily", %{
    shim_dir: shim_dir,
    real_dir: real_dir
  } do
    write_fake_elio!(real_dir)

    assert :ok = Shims.materialize!()
    shim = Shims.shim_path("elio")
    assert File.regular?(shim)
    assert File.regular?(Shims.install_script_path("elio"))
    assert File.regular?(Shims.shell_integration_path())

    {out, 0} =
      System.cmd(shim, [],
        env: [{"PATH", Enum.join([shim_dir, real_dir, "/usr/bin", "/bin"], ":")}],
        stderr_to_stdout: true
      )

    assert out =~ "ELIO_CLIPBOARD_OSC52=1"
    assert out =~ "CASEIN_APP_SHIM=elio"
    assert out =~ "CASEIN_TERMINAL=1"
    assert out =~ "CASEIN_CLIPBOARD=osc52"
  end

  test "materialize! writes no grok shim while still writing elio" do
    assert :ok = Shims.materialize!()

    assert File.regular?(Shims.shim_path("elio"))
    refute File.exists?(Shims.shim_path("grok"))
    refute File.exists?(Shims.install_script_path("grok"))

    # Even an explicit request must not shadow the ~/.local/bin grok launcher.
    assert :ok = Shims.materialize!(["grok"])
    refute File.exists?(Shims.shim_path("grok"))
  end

  test "registry theme descriptors are well-formed" do
    themed = for {name, %{theme: theme}} <- Shims.registry(), do: {name, theme}
    assert length(themed) >= 2

    for {name, theme} <- themed do
      assert is_binary(theme.path) and theme.path != "", "#{name} theme path"

      case theme.mode do
        :static ->
          assert is_binary(theme.template) and theme.template != ""

        :scheme_variant ->
          assert %{format: :toml, section: section, key: key, values: values} = theme.stamp
          assert is_binary(section) and is_binary(key)
          assert %{dark: dark, light: light} = values
          assert is_binary(dark) and is_binary(light)
      end
    end

    assert Shims.theme_specs() == Map.new(themed)
  end

  test "materialize! skips rewriting files that already match" do
    assert :ok = Shims.materialize!()
    shim = Shims.shim_path("elio")
    install = Shims.install_script_path("elio")

    stale = {{2020, 1, 1}, {0, 0, 0}}
    File.touch!(shim, stale)
    File.touch!(install, stale)

    assert :ok = Shims.materialize!()

    assert File.stat!(shim, time: :universal).mtime == stale
    assert File.stat!(install, time: :universal).mtime == stale
  end

  test "materialize! restores a drifted shim" do
    assert :ok = Shims.materialize!()
    shim = Shims.shim_path("elio")
    expected = File.read!(shim)

    File.write!(shim, "#!/bin/bash\necho corrupted\n")
    assert :ok = Shims.materialize!()
    assert File.read!(shim) == expected
  end

  test "materialize! restores a shim with drifted permissions" do
    assert :ok = Shims.materialize!()
    shim = Shims.shim_path("elio")
    File.chmod!(shim, 0o644)

    assert :ok = Shims.materialize!()
    assert Bitwise.band(File.stat!(shim).mode, 0o777) == 0o755
  end

  test "materialized shim preserves an explicit app env override", %{
    shim_dir: shim_dir,
    real_dir: real_dir
  } do
    write_fake_elio!(real_dir)
    Shims.materialize!()

    {out, 0} =
      System.cmd(Shims.shim_path("elio"), [],
        env: [
          {"PATH", Enum.join([shim_dir, real_dir, "/usr/bin", "/bin"], ":")},
          {"ELIO_CLIPBOARD_OSC52", "0"}
        ],
        stderr_to_stdout: true
      )

    assert out =~ "ELIO_CLIPBOARD_OSC52=0"
  end

  test "materialized shim derives COLORFGBG from terminal scheme when missing", %{
    shim_dir: shim_dir,
    real_dir: real_dir
  } do
    write_fake_elio!(real_dir)
    Shims.materialize!()

    {out, 0} =
      System.cmd(Shims.shim_path("elio"), [],
        env: [
          {"PATH", Enum.join([shim_dir, real_dir, "/usr/bin", "/bin"], ":")},
          {"CASEIN_TERMINAL_SCHEME", "light"},
          {"COLORFGBG", nil}
        ],
        stderr_to_stdout: true
      )

    assert out =~ "COLORFGBG=0;15"
  end

  test "materialized shim preserves explicit COLORFGBG", %{
    shim_dir: shim_dir,
    real_dir: real_dir
  } do
    write_fake_elio!(real_dir)
    Shims.materialize!()

    {out, 0} =
      System.cmd(Shims.shim_path("elio"), [],
        env: [
          {"PATH", Enum.join([shim_dir, real_dir, "/usr/bin", "/bin"], ":")},
          {"CASEIN_TERMINAL_SCHEME", "dark"},
          {"COLORFGBG", "custom"}
        ],
        stderr_to_stdout: true
      )

    assert out =~ "COLORFGBG=custom"
  end

  test "materialized shim installs a missing known tool before launching", %{
    shim_dir: shim_dir,
    clean_bin: clean_bin
  } do
    Shims.materialize!()
    write_fake_installer!(Shims.install_script_path("elio"), Shims.tools_bin_dir())

    {out, 0} =
      System.cmd(Shims.shim_path("elio"), ["--from-test"],
        env: [{"PATH", Enum.join([shim_dir, clean_bin], ":")}],
        stderr_to_stdout: true
      )

    assert out =~ "Casein: elio not found. Installing"
    assert out =~ "Casein: elio installed. Launching"
    assert out =~ "ELIO_CLIPBOARD_OSC52=1"
    assert out =~ "ARGV=--from-test"
  end

  test "theme env exports scheme, COLORFGBG, and optional preset" do
    assert %{
             "CASEIN_TERMINAL_SCHEME" => "light",
             "COLORFGBG" => "0;15",
             "COLORTERM" => "truecolor",
             "CASEIN_TERMINAL_PRESET" => "catppuccin"
           } = Shims.theme_env(:light, "catppuccin")

    assert %{
             "CASEIN_TERMINAL_SCHEME" => "dark",
             "COLORFGBG" => "15;0",
             "COLORTERM" => "truecolor"
           } = Shims.theme_env(:dark)
  end

  test "env merges theme variables when scheme is provided" do
    assert %{
             "CASEIN_TERMINAL" => "1",
             "CASEIN_CLIPBOARD" => "osc52",
             "CASEIN_SHELL_INTEGRATION" => "1",
             "CASEIN_SHELL_INTEGRATION_BASH" => _,
             "CASEIN_TERMINAL_SCHEME" => "light",
             "COLORFGBG" => "0;15",
             "COLORTERM" => "truecolor",
             "CASEIN_TERMINAL_PRESET" => "catppuccin"
           } = Shims.env(scheme: :light, preset: "catppuccin", include_path?: false)
  end

  test "terminal env can omit PATH for non-host execution contexts", %{shim_dir: shim_dir} do
    assert %{
             "CASEIN_TERMINAL" => "1",
             "CASEIN_CLIPBOARD" => "osc52",
             "CASEIN_SHELL_INTEGRATION" => "1",
             "COLORTERM" => "truecolor",
             "CASEIN_SHELL_INTEGRATION_BASH" => _
           } = Shims.env(include_path?: false)

    refute Map.has_key?(Shims.env(include_path?: false), "PATH")
    assert Shims.env()["PATH"] =~ shim_dir
    assert Shims.env()["PATH"] =~ Shims.tools_bin_dir()
    # Agent launcher + npm bins must be on every pane PATH so template panes
    # do not depend on bashrc alone for `claude` / `grok`.
    assert Shims.env()["PATH"] =~ Casein.Agents.AgentShims.bin_dir()
    assert Shims.env()["PATH"] =~ Casein.Agents.AgentShims.npm_bin_dir()
  end

  test "sync_tmux_terminal_env! publishes agent PATH for new-window -e flags" do
    prev = Application.get_env(:tmux_ctl, :terminal_env)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:tmux_ctl, :terminal_env, prev),
        else: Application.delete_env(:tmux_ctl, :terminal_env)
    end)

    env = Shims.sync_tmux_terminal_env!()
    published = Application.get_env(:tmux_ctl, :terminal_env)

    assert published == env
    assert published["PATH"] =~ Casein.Agents.AgentShims.bin_dir()
    assert published["PATH"] =~ Casein.Agents.AgentShims.npm_bin_dir()
    assert published["PATH"] =~ Shims.dir()
  end

  test "materializes bash shell integration with OSC 133 and tmux passthrough marks" do
    Shims.materialize!()

    path = Shims.shell_integration_path()
    assert File.regular?(path)

    script = File.read!(path)
    assert script =~ "133;A"
    assert script =~ "133;B"
    assert script =~ "133;C;cmd="
    assert script =~ "133;D;"
    assert script =~ "133;B"
    assert script =~ "tmux;"
    assert script =~ "PROMPT_COMMAND=__casein_prompt_command"
    assert script =~ "trap '__casein_preexec' DEBUG"
    # Fresh panes that inherited a thin release PATH still find agent shims.
    assert script =~ "__casein_prepend_path"
    assert script =~ ".casein/agent-shims"
    assert script =~ ".local/bin"
    assert script =~ "npm-global/bin"

    assert {_, 0} = System.cmd(bash!(), ["-n", path])
  end

  test "shell integration prepends agent bins even when inherited PATH is thin", %{tmp: tmp} do
    Shims.materialize!()
    script = Shims.shell_integration_path()
    home = Path.join(tmp, "home")
    agent_bin = Path.join(home, ".casein/agent-shims")
    File.mkdir_p!(agent_bin)
    shim = Path.join(agent_bin, "claude")
    File.write!(shim, "#!/bin/sh\necho ok\n")
    File.chmod!(shim, 0o755)

    {out, 0} =
      System.cmd(
        bash!(),
        [
          "-c",
          """
          export HOME=#{shell_quote(home)}
          export PATH=/usr/bin:/bin
          export CASEIN_SHELL_INTEGRATION_SKIP_RC=1
          source #{shell_quote(script)}
          command -v claude
          """
        ],
        stderr_to_stdout: true
      )

    assert String.trim(out) == shim
  end

  test "shell integration keeps agent launcher shims ahead of bare npm package bins",
       %{tmp: tmp} do
    Shims.materialize!()
    script = Shims.shell_integration_path()
    home = Path.join(tmp, "home")

    local_bin = Path.join(home, ".casein/agent-shims")
    npm_bin = Path.join(home, ".local/share/npm-global/bin")
    File.mkdir_p!(local_bin)
    File.mkdir_p!(npm_bin)

    # A Casein agent-launcher shim and a bare npm package binary of the SAME
    # name: PATH order decides which `claude` a fresh pane launches, and the
    # agent-shims launcher (skip-permissions + MCP env) must win. Prepending
    # each dir individually used to reverse the order and let the npm bin
    # shadow it.
    casein_shim = Path.join(local_bin, "claude")
    npm_bare = Path.join(npm_bin, "claude")
    File.write!(casein_shim, "#!/bin/sh\necho ok\n")
    File.write!(npm_bare, "#!/bin/sh\necho ok\n")
    File.chmod!(casein_shim, 0o755)
    File.chmod!(npm_bare, 0o755)

    {out, 0} =
      System.cmd(
        bash!(),
        [
          "-c",
          """
          export HOME=#{shell_quote(home)}
          export PATH=/usr/bin:/bin
          export CASEIN_SHELL_INTEGRATION_SKIP_RC=1
          source #{shell_quote(script)}
          command -v claude
          """
        ],
        stderr_to_stdout: true
      )

    assert String.trim(out) == casein_shim
  end

  test "shell integration forces agent shims back ahead of rc-prepended installer dirs",
       %{tmp: tmp} do
    Shims.materialize!()
    script = Shims.shell_integration_path()
    home = Path.join(tmp, "home")

    agent_shims = Path.join(home, ".casein/agent-shims")
    installer_bin = Path.join(home, ".grok/bin")
    File.mkdir_p!(agent_shims)
    File.mkdir_p!(installer_bin)

    casein_shim = Path.join(agent_shims, "grok")
    real_grok = Path.join(installer_bin, "grok")
    File.write!(casein_shim, "#!/bin/sh\necho shim\n")
    File.write!(real_grok, "#!/bin/sh\necho real\n")
    File.chmod!(casein_shim, 0o755)
    File.chmod!(real_grok, 0o755)

    # The pane env put agent-shims first, then a user rc file prepended the
    # grok installer dir on top. Presence-only dedupe would leave the real
    # binary winning (silent unpaired launch) — sourcing shell integration
    # must move the Casein launcher back to the front.
    {out, 0} =
      System.cmd(
        bash!(),
        [
          "-c",
          """
          export HOME=#{shell_quote(home)}
          export PATH=#{shell_quote(installer_bin)}:#{shell_quote(agent_shims)}:/usr/bin:/bin
          export CASEIN_SHELL_INTEGRATION_SKIP_RC=1
          source #{shell_quote(script)}
          command -v grok
          """
        ],
        stderr_to_stdout: true
      )

    assert String.trim(out) == casein_shim
  end

  describe "tmux session env hydration" do
    # `tmux set-environment` only reaches panes created after the call, so a
    # pane whose shell started before PaneEnv pushed the workspace env keeps the
    # server's global env (no CASEIN_WORKSPACE_ID, global admin token) and every
    # agent launcher refuses to start. Shell integration must pull the session
    # table in itself.
    setup %{tmp: tmp} do
      fake_bin = Path.join(tmp, "fake-tmux-bin")
      File.mkdir_p!(fake_bin)
      {:ok, fake_bin: fake_bin}
    end

    test "sourcing shell integration imports CASEIN_* from the session table",
         %{fake_bin: fake_bin} do
      Shims.materialize!()

      write_fake_tmux!(fake_bin, """
      CASEIN_WORKSPACE_ID=ws-123
      CASEIN_WORKSPACE_NAME=dalexandre-devide
      CASEIN_TERMINAL_MCP_URL=http://127.0.0.1:4000/api/terminals/mcp?workspace_id=ws-123
      """)

      out =
        source_integration(
          fake_bin,
          Shims.shell_integration_path(),
          ~s(echo "$CASEIN_WORKSPACE_NAME|$CASEIN_WORKSPACE_ID|$CASEIN_TERMINAL_MCP_URL")
        )

      assert String.trim(out) ==
               "dalexandre-devide|ws-123|http://127.0.0.1:4000/api/terminals/mcp?workspace_id=ws-123"
    end

    test "hydration ignores non-CASEIN vars, honours removals, and never evaluates values",
         %{fake_bin: fake_bin} do
      Shims.materialize!()

      # PATH must stay owned by the integration's own prepend logic, and a
      # value containing shell metacharacters must arrive literally — the
      # importer assigns, it never evals.
      write_fake_tmux!(fake_bin, """
      CASEIN_WORKSPACE_ID=ws-123
      CASEIN_QUOTED=a b'c"d$(touch #{Path.join(System.tmp_dir!(), "casein-hydration-pwned")})
      -CASEIN_STALE
      PATH=/hijacked
      NOT_CASEIN=nope
      """)

      out =
        source_integration(
          fake_bin,
          Shims.shell_integration_path(),
          ~s|echo "stale=${CASEIN_STALE-UNSET} other=${NOT_CASEIN-UNSET}"; | <>
            ~s|echo "quoted=$CASEIN_QUOTED"; case ":$PATH:" in *:/hijacked:*) echo BAD;; *) echo path-ok;; esac|
        )

      refute File.exists?(Path.join(System.tmp_dir!(), "casein-hydration-pwned"))
      assert out =~ "stale=UNSET other=UNSET"
      assert out =~ ~s(quoted=a b'c"d$\(touch)
      assert out =~ "path-ok"
      refute out =~ "BAD"
    end

    test "shell integration is a no-op outside tmux", %{fake_bin: fake_bin} do
      Shims.materialize!()
      write_fake_tmux!(fake_bin, "CASEIN_WORKSPACE_ID=ws-123")

      {out, 0} =
        System.cmd(
          bash!(),
          [
            "-c",
            """
            export PATH=#{shell_quote(fake_bin)}:/usr/bin:/bin
            unset TMUX
            export CASEIN_SHELL_INTEGRATION_SKIP_RC=1
            source #{shell_quote(Shims.shell_integration_path())}
            echo "id=${CASEIN_WORKSPACE_ID-UNSET}"
            """
          ],
          stderr_to_stdout: true
        )

      assert String.trim(out) == "id=UNSET"
    end

    test "prompt hook retries until the session env is populated", %{fake_bin: fake_bin, tmp: tmp} do
      Shims.materialize!()

      # Model the pane-create race: the first `show-environment` (shell init)
      # runs before PaneEnv pushed anything; the next one — at the first prompt
      # — sees the workspace vars.
      flag = Path.join(tmp, "paired")
      path = Path.join(fake_bin, "tmux")

      File.write!(path, """
      #!/bin/sh
      [ "$1" = "show-environment" ] || exit 0
      if [ -f #{shell_quote(flag)} ]; then
        echo CASEIN_WORKSPACE_ID=ws-123
      fi
      """)

      File.chmod!(path, 0o755)

      out =
        source_integration(
          fake_bin,
          Shims.shell_integration_path(),
          """
          echo "before=${CASEIN_WORKSPACE_ID-UNSET}"
          touch #{shell_quote(flag)}
          __casein_sync_session_env_if_pending
          echo "after=${CASEIN_WORKSPACE_ID-UNSET}"
          rm -f #{shell_quote(flag)}
          __casein_sync_session_env_if_pending
          echo "sticky=${CASEIN_WORKSPACE_ID-UNSET}"
          """
        )

      assert out =~ "before=UNSET"
      assert out =~ "after=ws-123"
      # Once paired, the hook stops calling tmux — a later empty table must not
      # strip a working pane's env back out.
      assert out =~ "sticky=ws-123"
    end
  end

  test "prompt-end marker in PS1 expands to escape bytes without a stray bracket", %{tmp: tmp} do
    Shims.materialize!()

    rcfile = Path.join(tmp, "prompt-expansion.bashrc")

    File.write!(
      rcfile,
      """
      export CASEIN_SHELL_INTEGRATION_SKIP_RC=1
      unset CASEIN_SHELL_INTEGRATION_LOADED
      export TMUX=fake,1,0
      PS1='$ '
      source #{Shims.shell_integration_path()}
      """
    )

    # Let readline render PS1 itself. `${PS1@P}` would be simpler, but that
    # expansion is unavailable in the Bash 3.2 shipped by macOS.
    {expanded, 0} =
      System.cmd(
        "/bin/sh",
        [
          "-c",
          "#{shell_quote(bash!())} --noprofile --rcfile #{shell_quote(rcfile)} -i < /dev/null"
        ],
        stderr_to_stdout: true
      )

    # An interactive Bash renders the prompt before consuming EOF. The OSC
    # passthrough must end with an intact ST (ESC backslash); with an unescaped
    # ST backslash, the following `\]` leaks a printable `]` into the prompt.
    assert expanded =~ "\e\\exit\n"
    refute expanded =~ "\e\\]exit\n"
  end

  test "shell command enters integration when available and falls back otherwise" do
    command = Shims.shell_command()

    assert command =~ "sh -lc"
    # zsh branch first (gated on $SHELL being zsh — the macOS default), then
    # the original integrated-bash chain (the devbox default).
    assert command =~ "CASEIN_SHELL_INTEGRATION_ZDOTDIR"
    assert command =~ ~s(${SHELL:-})
    assert command =~ ~s(exec "$__casein_shell" -il)
    assert command =~ "CASEIN_SHELL_INTEGRATION_BASH"
    assert command =~ "bash --init-file"
    assert command =~ "bash -l"
  end

  if System.find_executable("zsh") do
    test "staged ZDOTDIR bootstraps integrated zsh and restores user ZDOTDIR", %{tmp: tmp} do
      Shims.materialize!()
      home = Path.join(tmp, "home")
      File.mkdir_p!(home)

      script = """
      print -r -- "loaded=${CASEIN_SHELL_INTEGRATION_LOADED:-0}"
      print -r -- "zdotdir=${ZDOTDIR:-unset}"
      print -r -- "precmd=${precmd_functions}"
      print -r -- "preexec=${preexec_functions}"
      __casein_precmd
      """

      {out, 0} =
        System.cmd(
          System.find_executable("zsh"),
          ["-il", "-c", script],
          env: [
            {"HOME", home},
            {"PATH", "/usr/bin:/bin"},
            {"ZDOTDIR", Shims.zdotdir_path()},
            {"CASEIN_USER_ZDOTDIR", ""},
            {"CASEIN_SHELL_INTEGRATION_ZSH", Shims.zsh_integration_path()},
            {"CASEIN_SHELL_INTEGRATION_LOADED", nil}
          ],
          stderr_to_stdout: true
        )

      assert out =~ "loaded=1"
      assert out =~ "zdotdir=unset"
      assert out =~ ~r/precmd=.*__casein_precmd/
      assert out =~ ~r/preexec=.*__casein_preexec/
      refute out =~ "read-only variable"
    end

    test "custom user ZDOTDIR cannot bypass staged integration", %{tmp: tmp} do
      Shims.materialize!()
      home = Path.join(tmp, "home")
      user_zdotdir = Path.join(tmp, "custom-zdotdir")
      escaped = Path.join(tmp, "escaped-zdotdir")
      File.mkdir_p!(home)
      File.mkdir_p!(user_zdotdir)
      File.write!(Path.join(user_zdotdir, ".zshenv"), "export ZDOTDIR=#{shell_quote(escaped)}\n")
      File.write!(Path.join(user_zdotdir, ".zprofile"), "export CASEIN_PROFILE_SEEN=1\n")
      File.write!(Path.join(user_zdotdir, ".zshrc"), "export CASEIN_RC_SEEN=1\n")

      {out, 0} =
        System.cmd(
          System.find_executable("zsh"),
          [
            "-il",
            "-c",
            "print -r -- \"profile=$CASEIN_PROFILE_SEEN rc=$CASEIN_RC_SEEN loaded=$CASEIN_SHELL_INTEGRATION_LOADED zdotdir=$ZDOTDIR\""
          ],
          env: [
            {"HOME", home},
            {"PATH", "/usr/bin:/bin"},
            {"ZDOTDIR", Shims.zdotdir_path()},
            {"CASEIN_USER_ZDOTDIR", user_zdotdir},
            {"CASEIN_SHELL_INTEGRATION_ZDOTDIR", Shims.zdotdir_path()},
            {"CASEIN_SHELL_INTEGRATION_ZSH", Shims.zsh_integration_path()}
          ],
          stderr_to_stdout: true
        )

      assert out =~ "profile=1 rc=1 loaded=1 zdotdir=#{user_zdotdir}"
    end

    test "zsh integration appends the prompt-end mark to PS1", %{tmp: tmp} do
      Shims.materialize!()
      home = Path.join(tmp, "home")
      File.mkdir_p!(home)

      {out, 0} =
        System.cmd(
          System.find_executable("zsh"),
          ["-il", "-c", ~s(print -r -- "ps1=${PS1}")],
          env: [
            {"HOME", home},
            {"PATH", "/usr/bin:/bin"},
            {"ZDOTDIR", Shims.zdotdir_path()},
            {"CASEIN_SHELL_INTEGRATION_ZSH", Shims.zsh_integration_path()},
            {"CASEIN_SHELL_INTEGRATION_LOADED", nil}
          ],
          stderr_to_stdout: true
        )

      assert out =~ "%{\e]133;B\a%}"
    end

    test "zsh integration keeps agent shims ahead of bare npm package bins",
         %{tmp: tmp} do
      Shims.materialize!()
      home = Path.join(tmp, "home")

      local_bin = Path.join(home, ".casein/agent-shims")
      npm_bin = Path.join(home, ".local/share/npm-global/bin")
      File.mkdir_p!(local_bin)
      File.mkdir_p!(npm_bin)

      casein_shim = Path.join(local_bin, "claude")
      npm_bare = Path.join(npm_bin, "claude")
      File.write!(casein_shim, "#!/bin/sh\necho ok\n")
      File.write!(npm_bare, "#!/bin/sh\necho ok\n")
      File.chmod!(casein_shim, 0o755)
      File.chmod!(npm_bare, 0o755)

      {out, 0} =
        System.cmd(
          System.find_executable("zsh"),
          [
            "-i",
            "-c",
            """
            export CASEIN_SHELL_INTEGRATION_SKIP_RC=1
            unset CASEIN_SHELL_INTEGRATION_LOADED
            source #{shell_quote(Shims.zsh_integration_path())}
            command -v claude
            """
          ],
          env: [{"HOME", home}, {"PATH", "/usr/bin:/bin"}],
          stderr_to_stdout: true
        )

      assert String.trim(out) |> String.ends_with?(casein_shim)
    end
  end

  test "ensure-terminal-tool provisions through a temp cargo root", %{
    clean_bin: clean_bin,
    tool_root: tool_root
  } do
    write_fake_cargo!(clean_bin)

    {out, 0} =
      System.cmd(bash!(), ["scripts/ensure-terminal-tool.sh", "elio"],
        env: [
          {"PATH", clean_bin},
          {"CASEIN_TERMINAL_TOOLS_DIR", tool_root}
        ],
        stderr_to_stdout: true
      )

    assert out =~ "Casein: provisioning terminal tool 'elio'"
    assert out =~ "Casein: provisioned terminal tool 'elio'"
    refute File.exists?(Path.join(tool_root, ".elio-install.lock"))

    managed_elio = Path.join([tool_root, "bin", "elio"])
    assert File.regular?(managed_elio)
    assert {installed_out, 0} = System.cmd(managed_elio, [])
    assert installed_out =~ "fake cargo elio"
  end

  test "ensure-terminal-tool check mode reports missing without installing", %{
    clean_bin: clean_bin,
    tool_root: tool_root
  } do
    write_fake_cargo!(clean_bin)

    {out, 1} =
      System.cmd(bash!(), ["scripts/ensure-terminal-tool.sh", "--check", "elio"],
        env: [
          {"PATH", clean_bin},
          {"CASEIN_TERMINAL_TOOLS_DIR", tool_root}
        ],
        stderr_to_stdout: true
      )

    assert out =~ "Casein: elio is not installed"
    refute File.exists?(Path.join([tool_root, "bin", "elio"]))
  end

  test "generated fallback installer provisions through a temp cargo root", %{
    clean_bin: clean_bin,
    tool_root: tool_root
  } do
    write_fake_cargo!(clean_bin)
    Shims.materialize!()

    {out, 0} =
      System.cmd(Shims.install_script_path("elio"), [],
        env: [
          {"PATH", clean_bin},
          {"CASEIN_TERMINAL_TOOLS_DIR", tool_root}
        ],
        stderr_to_stdout: true
      )

    assert out =~ "Casein: provisioning terminal tool 'elio'"
    assert out =~ "Casein: provisioned terminal tool 'elio'"
    refute File.exists?(Path.join(tool_root, ".elio-install.lock"))

    managed_elio = Path.join([tool_root, "bin", "elio"])
    assert File.regular?(managed_elio)
    assert {installed_out, 0} = System.cmd(managed_elio, [])
    assert installed_out =~ "fake cargo elio"
  end

  defp write_fake_elio!(dir) do
    path = Path.join(dir, "elio")

    File.write!(path, fake_elio_script())
    File.chmod!(path, 0o755)
  end

  defp write_fake_installer!(path, tool_bin) do
    elio = Path.join(tool_bin, "elio")

    File.write!(path, [
      "#!/usr/bin/env bash\n",
      "set -euo pipefail\n",
      "mkdir -p #{shell_quote(tool_bin)}\n",
      "cat >#{shell_quote(elio)} <<'EOS'\n",
      fake_elio_script(),
      "EOS\n",
      "chmod +x #{shell_quote(elio)}\n"
    ])

    File.chmod!(path, 0o755)
  end

  defp write_fake_cargo!(dir) do
    path = Path.join(dir, "cargo")

    File.write!(path, [
      "#!/usr/bin/env bash\n",
      "set -euo pipefail\n",
      "root=''\n",
      "while [[ $# -gt 0 ]]; do\n",
      "  case \"$1\" in\n",
      "    install) shift ;;\n",
      "    --root) root=\"$2\"; shift 2 ;;\n",
      "    *) shift ;;\n",
      "  esac\n",
      "done\n",
      "mkdir -p \"${root}/bin\"\n",
      "cat >\"${root}/bin/elio\" <<'EOS'\n",
      "#!/usr/bin/env bash\n",
      "echo fake cargo elio\n",
      "EOS\n",
      "chmod +x \"${root}/bin/elio\"\n"
    ])

    File.chmod!(path, 0o755)
  end

  defp write_fake_curl!(dir) do
    path = Path.join(dir, "curl")

    File.write!(path, [
      "#!/usr/bin/env bash\n",
      "set -euo pipefail\n",
      "out=''\n",
      "data=''\n",
      "max_time=''\n",
      "request_url=''\n",
      "while [[ $# -gt 0 ]]; do\n",
      "  case \"$1\" in\n",
      "    -o) out=\"$2\"; shift 2 ;;\n",
      "    --max-time) max_time=\"$2\"; shift 2 ;;\n",
      "    --data) data=\"$2\"; shift 2 ;;\n",
      "    -w|-X|-H) shift 2 ;;\n",
      "    http://*|https://*) request_url=\"$1\"; shift ;;\n",
      "    *) shift ;;\n",
      "  esac\n",
      "done\n",
      "printf '{\"kind\":\"markdown\",\"path\":\"docs/readme.md\"}' >\"$out\"\n",
      "if [[ -n \"${CASEIN_FAKE_CURL_CAPTURE:-}\" ]]; then\n",
      "  printf '%s\\n%s\\n%s\\n' \"$request_url\" \"$max_time\" \"$data\" >\"$CASEIN_FAKE_CURL_CAPTURE\"\n",
      "fi\n",
      "printf '200'\n"
    ])

    File.chmod!(path, 0o755)
  end

  defp write_clean_bin!(dir) do
    File.mkdir_p!(dir)

    Enum.each(~w(bash env dirname mkdir cat chmod cp mv mktemp rm sed sleep tr), fn name ->
      source = System.find_executable(name) || raise "missing executable for test: #{name}"
      File.ln_s!(source, Path.join(dir, name))
    end)
  end

  defp write_fake_tmux!(dir, show_environment_output) do
    path = Path.join(dir, "tmux")

    File.write!(path, """
    #!/bin/sh
    [ "$1" = "show-environment" ] || exit 0
    cat <<'CASEIN_FAKE_TMUX'
    #{show_environment_output}
    CASEIN_FAKE_TMUX
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp source_integration(fake_bin, script, probe) do
    {out, 0} =
      System.cmd(
        bash!(),
        [
          "-c",
          """
          export PATH=#{shell_quote(fake_bin)}:/usr/bin:/bin
          export TMUX=fake,1,0
          export CASEIN_SHELL_INTEGRATION_SKIP_RC=1
          source #{shell_quote(script)}
          #{probe}
          """
        ],
        stderr_to_stdout: true
      )

    out
  end

  defp bash!, do: System.find_executable("bash") || raise("missing bash")

  defp fake_elio_script do
    [
      "#!/usr/bin/env bash\n",
      "printf 'ELIO_CLIPBOARD_OSC52=%s\\n' \"${ELIO_CLIPBOARD_OSC52:-}\"\n",
      "printf 'CASEIN_APP_SHIM=%s\\n' \"${CASEIN_APP_SHIM:-}\"\n",
      "printf 'CASEIN_TERMINAL=%s\\n' \"${CASEIN_TERMINAL:-}\"\n",
      "printf 'CASEIN_CLIPBOARD=%s\\n' \"${CASEIN_CLIPBOARD:-}\"\n",
      "printf 'COLORFGBG=%s\\n' \"${COLORFGBG:-}\"\n",
      "printf 'ARGV=%s\\n' \"$*\"\n"
    ]
  end

  defp shell_quote(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)
end
