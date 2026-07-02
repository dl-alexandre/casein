defmodule TmuxCtl.ClientExtraTest do
  use DevIDE.TestCase, async: false

  alias TmuxCtl.Client
  alias TmuxCtl.Test.FakeState

  @session "devide_alpha_main"

  # Scripted runner that reuses the documented runner seam
  # (`config :tmux_ctl, :runner`) exactly like `TmuxCtl.Test.FakeRunner`,
  # but lets each test feed an arbitrary canned `{output, exit_code}` so the
  # parsing branches can be exercised with realistic tmux `-F` output and the
  # mutation commands can be driven down both the success and failure paths.
  #
  # It forwards argv to the test pid via the same `{:tmux_runner, argv}`
  # message the existing FakeRunner uses, so argv assertions are identical.
  defmodule ScriptRunner do
    @moduledoc false
    @behaviour TmuxCtl.Runner

    alias TmuxCtl.Test.FakeState

    @impl true
    def run(argv, _opts) when is_list(argv) do
      if pid = FakeState.get(:fake_tmux_runner_pid), do: send(pid, {:tmux_runner, argv})
      FakeState.get(:script_response, {"", 0})
    end

    def argv(argv, _opts), do: FakeState.get(:script_argv, ["tmux" | argv])
  end

  setup do
    previous = %{
      runner: Application.get_env(:tmux_ctl, :runner),
      terminal_env: Application.get_env(:tmux_ctl, :terminal_env),
      pid: FakeState.get(:fake_tmux_runner_pid),
      script: FakeState.get(:script_response),
      script_argv: FakeState.get(:script_argv)
    }

    Application.put_env(:tmux_ctl, :runner, ScriptRunner)
    Application.delete_env(:tmux_ctl, :terminal_env)
    FakeState.put(:fake_tmux_runner_pid, self())

    on_exit(fn ->
      FakeState.restore(:fake_tmux_runner_pid, previous.pid)
      FakeState.restore(:script_response, previous.script)
      FakeState.restore(:script_argv, previous.script_argv)

      if previous.runner,
        do: Application.put_env(:tmux_ctl, :runner, previous.runner),
        else: Application.delete_env(:tmux_ctl, :runner)

      if previous.terminal_env,
        do: Application.put_env(:tmux_ctl, :terminal_env, previous.terminal_env),
        else: Application.delete_env(:tmux_ctl, :terminal_env)
    end)

    :ok
  end

  defp script(out, code), do: FakeState.put(:script_response, {out, code})

  # --- list_session_windows/1 -------------------------------------------------

  test "list_session_windows parses multiple windows and edge fields" do
    # @topology_window_fmt: id|index|name|active|panes|activity|current_command
    out =
      Enum.join(
        [
          "@1|0|shell|1|2|17|bash",
          "@2|1|editor|0|1|0|nvim",
          # blank line is trimmed by String.split(trim: true)
          "",
          # malformed (too few fields) → dropped by parse_topology_window_line
          "garbage-no-pipes",
          # non-integer index/panes/activity fall back to defaults
          "@3|x|build|0|y|z|make"
        ],
        "\n"
      )

    script(out, 0)

    assert [
             %{
               id: "@1",
               index: 0,
               name: "shell",
               active: true,
               panes: 2,
               activity: 17,
               current_command: "bash"
             },
             %{id: "@2", index: 1, name: "editor", active: false, panes: 1, activity: 0},
             %{id: "@3", index: 0, name: "build", active: false, panes: 1, activity: 0}
           ] = Client.list_session_windows(@session)

    assert_receive {:tmux_runner, ["list-windows", "-t", @session, "-F", _fmt]}
  end

  test "list_session_windows returns [] on non-zero exit" do
    script("ignored", 1)
    assert [] = Client.list_session_windows(@session)
  end

  test "list_session_windows returns [] on empty output" do
    script("", 0)
    assert [] = Client.list_session_windows(@session)
  end

  # --- list_session_panes/1 ---------------------------------------------------

  # 19-field @topology_pane_fmt:
  # window_id|pane_id|index|active|left|top|width|height|current_command|
  # pane_activity|pane_bell|window_activity|window_activity_flag|
  # window_bell_flag|pane_unseen_changes|current_path|pane_zoomed|role|pane_title
  test "list_session_panes parses full 19-field pane lines with titles" do
    out =
      Enum.join(
        [
          "@1|%1|0|1|0|0|120|40|node|1500|0|10|0|0|1|/workspace|1|agent|Claude ready",
          "@1|%2|1|0|60|0|60|40|nvim|0|0|9|1|0|0|/proj|0||Task title | with pipe"
        ],
        "\n"
      )

    script(out, 0)

    assert [
             %{
               id: "%1",
               current_command: "node",
               role: "agent",
               pane_title: "Claude ready",
               activity: 1500,
               unseen_changes: true,
               zoomed?: true
             },
             %{
               id: "%2",
               role: nil,
               pane_title: "Task title | with pipe",
               activity: 9,
               activity_flag: true
             }
           ] = Client.list_session_panes(@session)

    assert_receive {:tmux_runner, ["list-panes", "-s", "-t", @session, "-F", _fmt]}
  end

  test "list_session_panes parses full 17-field pane lines" do
    out =
      Enum.join(
        [
          "@1|%1|0|1|0|0|120|40|bash|1500|0|10|0|0|1|/workspace|1",
          "@1|%2|1|0|60|0|60|40|nvim|0|0|9|1|0|0|/proj|0"
        ],
        "\n"
      )

    script(out, 0)

    assert [
             %{
               id: "%1",
               window_id: "@1",
               index: 0,
               active: true,
               left: 0,
               top: 0,
               width: 120,
               height: 40,
               current_command: "bash",
               current_path: "/workspace",
               # pane_activity 1500 > 1 wins over window_activity
               activity: 1500,
               unseen_changes: true,
               zoomed?: true
             },
             %{
               id: "%2",
               window_id: "@1",
               active: false,
               width: 60,
               # pane_activity 0 → fall back to window_activity 9
               activity: 9,
               # window_activity_flag "1" → activity_flag true
               activity_flag: true,
               zoomed?: false,
               unseen_changes: false
             }
           ] = Client.list_session_panes(@session)

    assert_receive {:tmux_runner, ["list-panes", "-s", "-t", @session, "-F", _fmt]}
  end

  test "list_session_panes parses 16-field line (zoomed defaults to 0)" do
    # 16 fields: drop the trailing pane_zoomed field
    out = "@7|%9|2|1|5|5|80|24|zsh|3|1|2|0|0|0|/home"
    script(out, 0)

    assert [pane] = Client.list_session_panes(@session)
    assert pane.id == "%9"
    assert pane.window_id == "@7"
    assert pane.current_path == "/home"
    assert pane.zoomed? == false
    # pane_bell "1" → bell true
    assert pane.bell == true
  end

  test "list_session_panes parses minimal 10-field line" do
    # 10 fields: window_id|pane_id|index|active|left|top|width|height|cmd|path
    out = "@3|%4|0|1|0|0|100|30|fish|/srv/app"
    script(out, 0)

    assert [pane] = Client.list_session_panes(@session)
    assert pane.id == "%4"
    assert pane.current_command == "fish"
    assert pane.current_path == "/srv/app"
    assert pane.zoomed? == false
    assert pane.bell == false
    assert pane.unseen_changes == false
  end

  test "list_session_panes drops malformed lines and handles errors" do
    script("only|three|fields", 0)
    assert [] = Client.list_session_panes(@session)

    script("anything", 1)
    assert [] = Client.list_session_panes(@session)
  end

  # --- session_topology/1 -----------------------------------------------------

  test "session_topology splits W| and P| tagged lines" do
    out =
      Enum.join(
        [
          "W|@1|0|shell|1|1|5|bash",
          "P|@1|%1|0|1|0|0|120|40|bash|5|0|5|0|0|0|/workspace|1",
          # untagged line ignored by the comprehension binary match
          "noise"
        ],
        "\n"
      )

    script(out, 0)

    assert {windows, panes} = Client.session_topology(@session)
    assert [%{id: "@1", name: "shell", active: true}] = windows
    assert [%{id: "%1", window_id: "@1", zoomed?: true}] = panes

    assert_receive {:tmux_runner, argv}
    assert Enum.member?(argv, ";")
    assert Enum.member?(argv, "list-windows")
    assert Enum.member?(argv, "list-panes")
  end

  test "session_topology returns {[], []} on tmux error" do
    script("", 1)
    assert {[], []} = Client.session_topology(@session)
  end

  # --- directory_inventory/0 --------------------------------------------------

  # @directory_window_fmt: session|id|index|active|activity|current_command|name
  # @directory_pane_fmt:   session|window_id|pane_id|active|current_command|pane_activity|
  #                        window_activity|current_path|@devide_pane_role|pane_title
  test "directory_inventory groups windows and panes by session" do
    out =
      Enum.join(
        [
          "W|devide_a_main|@1|0|1|11|bash|shell",
          "W|devide_b_main|@2|0|0|0|nvim|editor",
          "P|devide_a_main|@1|%1|1|node|150|11|/work/a|operator|Agent title",
          # 5-field fallback for older fixtures without a role field.
          "P|devide_b_main|@2|%2|0|/work/b",
          # malformed window/pane lines are dropped
          "W|too|few",
          "P|too|few"
        ],
        "\n"
      )

    script(out, 0)

    assert {:ok, %{windows: windows, panes: panes}} = Client.directory_inventory()

    assert [%{id: "@1", name: "shell", active: true, current_command: "bash"}] =
             windows["devide_a_main"]

    assert [%{id: "@2", name: "editor", active: false}] = windows["devide_b_main"]

    assert [
             %{
               id: "%1",
               window_id: "@1",
               active: true,
               current_command: "node",
               activity: 150,
               current_path: "/work/a",
               role: "operator",
               pane_title: "Agent title"
             }
           ] =
             panes["devide_a_main"]

    assert [%{id: "%2", active: false, current_path: "/work/b", role: nil}] =
             panes["devide_b_main"]

    assert_receive {:tmux_runner, argv}
    assert Enum.member?(argv, "-a")
  end

  test "directory_inventory returns :error on tmux failure" do
    script("", 1)
    assert :error = Client.directory_inventory()
  end

  # --- list_windows/0 ---------------------------------------------------------

  # @list_windows_fmt: session|window_id|active|panes|automatic_rename|activity|current_command
  test "list_windows parses server-wide window list" do
    out =
      Enum.join(
        [
          "devide_a_main|@1|1|2|1|99|bash",
          "devide_b_main|@2|0|1|0|0|nvim",
          "bad-line"
        ],
        "\n"
      )

    script(out, 0)

    assert [
             %{
               session: "devide_a_main",
               window_id: "@1",
               active: true,
               panes: 2,
               automatic_rename: true,
               activity: 99,
               current_command: "bash"
             },
             %{session: "devide_b_main", active: false, automatic_rename: false}
           ] = Client.list_windows()
  end

  test "list_windows returns [] on failure" do
    script("x", 1)
    assert [] = Client.list_windows()
  end

  # --- list_sessions/0 --------------------------------------------------------

  # @list_sessions_fmt: session|attached|activity|@devide_session_alias
  test "list_sessions parses 4-field and 3-field lines" do
    out =
      Enum.join(
        [
          "devide_a_main|1|123|billing",
          # blank alias → session_alias nil
          "devide_b_main|0|45|   ",
          # 3-field fallback (no alias field)
          "devide_c_main|0|7",
          "junk"
        ],
        "\n"
      )

    script(out, 0)

    assert [
             %{session: "devide_a_main", attached: true, activity: 123, session_alias: "billing"},
             %{session: "devide_b_main", attached: false, activity: 45, session_alias: nil},
             %{session: "devide_c_main", attached: false, activity: 7}
           ] = Client.list_sessions()
  end

  test "list_sessions returns [] on failure" do
    script("", 1)
    assert [] = Client.list_sessions()
  end

  # --- list_panes/0 -----------------------------------------------------------

  test "list_panes returns {session, command} tuples" do
    out =
      Enum.join(
        [
          "devide_a_main|bash",
          "devide_b_main|nvim",
          "no-pipe-line"
        ],
        "\n"
      )

    script(out, 0)

    assert [{"devide_a_main", "bash"}, {"devide_b_main", "nvim"}] = Client.list_panes()
  end

  test "list_panes returns [] on failure" do
    script("", 1)
    assert [] = Client.list_panes()
  end

  # --- new_window/2 -----------------------------------------------------------

  test "new_window returns trimmed window id with name and cwd options" do
    script("@5\n", 0)

    assert {:ok, "@5"} = Client.new_window(@session, name: "logs", cwd: "/var/log")

    assert_receive {:tmux_runner, argv}
    assert ["new-window", "-P", "-F", _fmt, "-t", @session | rest] = argv
    assert "logs" in rest
    assert "/var/log" in rest
    assert "-n" in rest
    assert "-c" in rest
  end

  test "new_window omits name/cwd when blank or missing" do
    script("@6\n", 0)
    assert {:ok, "@6"} = Client.new_window(@session, name: "", cwd: "")

    assert_receive {:tmux_runner, ["new-window", "-P", "-F", _fmt, "-t", @session]}
  end

  test "new_window surfaces error tuple on non-zero exit" do
    script("boom", 3)
    assert {:error, {3, "boom"}} = Client.new_window(@session)
  end

  # --- select_window/2 --------------------------------------------------------

  test "select_window targets session:window and reports success/failure" do
    script("", 0)
    assert :ok = Client.select_window(@session, "@2")
    assert_receive {:tmux_runner, ["select-window", "-t", target]}
    assert target == "#{@session}:@2"

    script("nope", 5)
    assert {:error, {5, "nope"}} = Client.select_window(@session, "@2")
  end

  # --- cycle_window/2 ---------------------------------------------------------

  test "cycle_window uses -n for next and -p for prev" do
    script("", 0)
    assert :ok = Client.cycle_window(@session, "next")
    assert_receive {:tmux_runner, ["select-window", "-n", "-t", @session]}

    assert :ok = Client.cycle_window(@session, "prev")
    assert_receive {:tmux_runner, ["select-window", "-p", "-t", @session]}
  end

  test "cycle_window propagates failure" do
    script("err", 2)
    assert {:error, {2, "err"}} = Client.cycle_window(@session, "next")
  end

  # --- select_pane/2 ----------------------------------------------------------

  test "select_pane targets the bare pane id" do
    script("", 0)
    assert :ok = Client.select_pane(@session, "%1")
    assert_receive {:tmux_runner, ["select-pane", "-t", "%1"]}

    script("x", 1)
    assert {:error, {1, "x"}} = Client.select_pane(@session, "%1")
  end

  # --- paste_text/3 -----------------------------------------------------------

  test "paste_text with submit normalizes successful Enter send to :ok" do
    FakeState.put(:script_argv, ["/bin/cat"])
    script("", 0)

    assert :ok = Client.paste_text(@session, "echo ok", target: "%2", submit: true)

    assert_receive {:tmux_runner, ["paste-buffer", "-d", "-b", buffer, "-t", "%2"]}
    assert String.starts_with?(buffer, "devide-paste-")
    assert_receive {:tmux_runner, ["send-keys", "-t", "%2", "Enter"]}
  end

  # --- navigate_pane/2 --------------------------------------------------------

  test "navigate_pane directional flags" do
    for {dir, flag} <- [{"L", "-L"}, {"R", "-R"}, {"U", "-U"}, {"D", "-D"}, {"l", "-l"}] do
      script("", 0)
      assert :ok = Client.navigate_pane(@session, dir)
      assert_receive {:tmux_runner, ["select-pane", "-t", @session, ^flag]}
    end
  end

  test "navigate_pane next cycles with :.+ target" do
    script("", 0)
    assert :ok = Client.navigate_pane(@session, "n")
    assert_receive {:tmux_runner, ["select-pane", "-t", target]}
    assert target == "#{@session}:.+"
  end

  test "navigate_pane prev cycles with :.- target" do
    script("", 0)
    assert :ok = Client.navigate_pane(@session, "p")
    assert_receive {:tmux_runner, ["select-pane", "-t", target]}
    assert target == "#{@session}:.-"
  end

  test "navigate_pane rejects invalid direction" do
    assert {:error, :invalid_direction} = Client.navigate_pane(@session, "diagonal")
  end

  test "navigate_pane propagates tmux failure" do
    script("boom", 1)
    assert {:error, {1, "boom"}} = Client.navigate_pane(@session, "L")

    script("boom", 1)
    assert {:error, {1, "boom"}} = Client.navigate_pane(@session, "n")
  end

  # --- zoom_pane/2 & kill_other_panes/2 ---------------------------------------

  test "zoom_pane toggles zoom for a managed session, bare pane id passthrough" do
    script("", 0)
    assert :ok = Client.zoom_pane(@session, "%1")
    assert_receive {:tmux_runner, ["resize-pane", "-Z", "-t", "%1"]}
  end

  test "zoom_pane uses session:window target for non-% ids" do
    script("", 0)
    assert :ok = Client.zoom_pane(@session, "0")
    assert_receive {:tmux_runner, ["resize-pane", "-Z", "-t", target]}
    assert target == "#{@session}:0"
  end

  test "zoom_pane refuses non-devide sessions" do
    assert {:error, :refused_non_devide_session} = Client.zoom_pane("other", "%1")
  end

  test "zoom_pane propagates failure" do
    script("nope", 4)
    assert {:error, {4, "nope"}} = Client.zoom_pane(@session, "%1")
  end

  test "kill_other_panes kills siblings for managed session" do
    script("", 0)
    assert :ok = Client.kill_other_panes(@session, "%1")
    assert_receive {:tmux_runner, ["kill-pane", "-a", "-t", "%1"]}
  end

  test "kill_other_panes refuses non-devide session" do
    assert {:error, :refused_non_devide_session} = Client.kill_other_panes("other", "%1")
  end

  # --- select_layout/2 & next_layout/1 ----------------------------------------

  test "select_layout accepts known presets" do
    script("", 0)
    assert :ok = Client.select_layout(@session, "tiled")
    assert_receive {:tmux_runner, ["select-layout", "-t", @session, "tiled"]}
  end

  test "select_layout rejects unknown layout" do
    assert {:error, :invalid_layout} = Client.select_layout(@session, "spiral")
  end

  test "select_layout propagates failure" do
    script("err", 1)
    assert {:error, {1, "err"}} = Client.select_layout(@session, "even-horizontal")
  end

  test "next_layout cycles layout preset" do
    script("", 0)
    assert :ok = Client.next_layout(@session)
    assert_receive {:tmux_runner, ["next-layout", "-t", @session]}

    script("x", 2)
    assert {:error, {2, "x"}} = Client.next_layout(@session)
  end

  # --- kill_pane/2 ------------------------------------------------------------

  test "kill_pane kills a managed pane and refuses non-devide" do
    script("", 0)
    assert :ok = Client.kill_pane(@session, "%3")
    assert_receive {:tmux_runner, ["kill-pane", "-t", "%3"]}

    assert {:error, :refused_non_devide_session} = Client.kill_pane("other", "%3")

    script("boom", 1)
    assert {:error, {1, "boom"}} = Client.kill_pane(@session, "%3")
  end

  # --- split_pane/4 -----------------------------------------------------------

  test "split_pane horizontal returns the new pane id" do
    script("%9\n", 0)

    assert {:ok, "%9"} =
             Client.split_pane(@session, "%1", "h", cwd: "/tmp", command: "htop")

    assert_receive {:tmux_runner, argv}
    assert ["split-window", "-P", "-F", _fmt, "-h", "-t", "%1" | rest] = argv
    assert "/tmp" in rest
    assert "htop" in rest
  end

  test "split_pane vertical with no opts" do
    script("%10\n", 0)
    assert {:ok, "%10"} = Client.split_pane(@session, "%1", "v")
    assert_receive {:tmux_runner, ["split-window", "-P", "-F", _fmt, "-v", "-t", "%1"]}
  end

  test "split_pane refuses non-devide session" do
    assert {:error, :refused_non_devide_session} = Client.split_pane("other", "%1", "h")
  end

  test "split_pane rejects invalid direction" do
    assert {:error, :invalid_direction} = Client.split_pane(@session, "%1", "diagonal")
  end

  test "split_pane propagates failure" do
    script("boom", 1)
    assert {:error, {1, "boom"}} = Client.split_pane(@session, "%1", "h")
  end

  # --- resize_pane/4 (success + error + flags) --------------------------------

  test "resize_pane maps each direction to its flag and clamps amount" do
    for {dir, flag} <- [{"left", "-L"}, {"right", "-R"}, {"up", "-U"}, {"down", "-D"}] do
      script("", 0)
      assert :ok = Client.resize_pane(@session, "%1", dir, 4)
      assert_receive {:tmux_runner, ["resize-pane", "-t", "%1", ^flag, "4"]}
    end
  end

  test "resize_pane defaults amount when nil and propagates failure" do
    script("", 0)
    assert :ok = Client.resize_pane(@session, "%1", "left", nil)
    assert_receive {:tmux_runner, ["resize-pane", "-t", "%1", "-L", amount]}
    assert amount == to_string(Client.resize_amount_default())

    script("boom", 1)
    assert {:error, {1, "boom"}} = Client.resize_pane(@session, "%1", "left", 3)
  end

  test "resize_pane rejects oversized amount and non-devide session" do
    assert {:error, :invalid_amount} =
             Client.resize_pane(@session, "%1", "left", Client.resize_amount_max() + 1)

    assert {:error, :refused_non_devide_session} =
             Client.resize_pane("other", "%1", "left", 5)
  end

  # --- rename_window/3 --------------------------------------------------------

  test "rename_window targets session:window and reports outcome" do
    script("", 0)
    assert :ok = Client.rename_window(@session, "@1", "logs")
    assert_receive {:tmux_runner, ["rename-window", "-t", target, "logs"]}
    assert target == "#{@session}:@1"

    script("err", 1)
    assert {:error, {1, "err"}} = Client.rename_window(@session, "@1", "logs")
  end

  # --- kill_window/2 ----------------------------------------------------------

  test "kill_window kills a managed window and refuses others" do
    script("", 0)
    assert :ok = Client.kill_window(@session, "@1")
    assert_receive {:tmux_runner, ["kill-window", "-t", target]}
    assert target == "#{@session}:@1"

    assert {:error, :refused_non_devide_session} = Client.kill_window("other", "@1")

    script("boom", 1)
    assert {:error, {1, "boom"}} = Client.kill_window(@session, "@1")
  end

  # --- set_environment/3 & set_environments/2 ---------------------------------

  test "set_environment forwards key/value and reports failure" do
    script("", 0)
    assert :ok = Client.set_environment(@session, "FOO", "bar")
    assert_receive {:tmux_runner, ["set-environment", "-t", @session, "FOO", "bar"]}

    script("err", 1)
    assert {:error, {1, "err"}} = Client.set_environment(@session, "FOO", "bar")
  end

  test "set_environments succeeds when all vars set" do
    script("", 0)
    assert :ok = Client.set_environments(@session, %{"A" => "1"})
    assert_receive {:tmux_runner, ["set-environment", "-t", @session, "A", "1"]}
  end

  test "set_environments collects failures" do
    script("err", 1)
    assert {:error, failures} = Client.set_environments(@session, %{"A" => "1"})
    assert [{"A", {:error, {1, "err"}}}] = failures
  end

  test "set_environments ignores non-binary keys/values" do
    script("", 0)
    # Only the binary/binary pair drives a tmux call; the others are skipped.
    assert :ok = Client.set_environments(@session, %{"A" => "1", :skip => "x", "B" => 2})
    assert_receive {:tmux_runner, ["set-environment", "-t", @session, "A", "1"]}
  end

  # --- ensure_session/2 -------------------------------------------------------

  test "ensure_session applies defaults when session already exists" do
    # has-session succeeds → apply_defaults batched call also succeeds.
    script("", 0)
    assert :ok = Client.ensure_session(@session, "/work")
    assert_receive {:tmux_runner, ["has-session", "-t", @session]}
  end

  # --- session_exists?/1 & session_alive?/1 -----------------------------------

  test "session_exists? reflects has-session exit code" do
    script("", 0)
    assert Client.session_exists?(@session) == true
    assert_receive {:tmux_runner, ["has-session", "-t", @session]}

    script("", 1)
    assert Client.session_exists?(@session) == false
    assert Client.session_alive?(@session) == false
  end

  # --- capture_scrollback/2 ---------------------------------------------------

  test "capture_scrollback builds capture-pane args with ansi and target" do
    script("line1\nline2\nline3\n", 0)

    assert "line1\nline2\nline3\n" = Client.capture_scrollback(@session)
    assert_receive {:tmux_runner, argv}
    assert ["capture-pane", "-p", "-e", "-J", "-S", "-", "-t", @session] = argv
  end

  test "capture_scrollback drops -e when ansi false and targets pane" do
    script("a\nb", 0)
    assert "a\nb" = Client.capture_scrollback(@session, ansi: false, target: "%2")

    assert_receive {:tmux_runner, ["capture-pane", "-p", "-J", "-S", "-", "-t", "%2"]}
  end

  test "capture_scrollback returns empty binary on failure" do
    script("ignored", 1)
    assert <<>> == Client.capture_scrollback(@session)
  end

  # --- tail_lines/2 (pure helper) ---------------------------------------------

  test "tail_lines keeps the last n lines or all when n is nil/zero" do
    assert "two\nthree" = Client.tail_lines("one\ntwo\nthree", 2)
    assert "one\ntwo\nthree" = Client.tail_lines("one\ntwo\nthree", nil)
    assert "one\ntwo\nthree" = Client.tail_lines("one\ntwo\nthree", 0)
  end

  # --- pane_zoomed?/2 & ensure_zoomed/3 (via list_session_panes path) ---------

  test "pane_zoomed? reads the zoomed flag from the pane list" do
    script("@1|%1|0|1|0|0|120|40|bash|5|0|5|0|0|0|/work|1", 0)
    assert Client.pane_zoomed?(@session, "%1") == true

    script("@1|%1|0|1|0|0|120|40|bash|5|0|5|0|0|0|/work|0", 0)
    assert Client.pane_zoomed?(@session, "%1") == false

    # missing pane id → default false
    script("@1|%2|0|1|0|0|120|40|bash|5|0|5|0|0|0|/work|1", 0)
    assert Client.pane_zoomed?(@session, "%1") == false
  end

  test "ensure_zoomed is a no-op when desired matches actual state" do
    script("@1|%1|0|1|0|0|120|40|bash|5|0|5|0|0|0|/work|1", 0)
    assert :ok = Client.ensure_zoomed(@session, "%1", true)
    # only the list-panes read happens; no resize-pane -Z toggle
    refute_received {:tmux_runner, ["resize-pane", "-Z" | _]}
  end
end
