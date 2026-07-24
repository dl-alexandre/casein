defmodule TmuxCtl.ClientTest do
  use Casein.TestCase, async: false

  alias TmuxCtl.Client
  alias TmuxCtl.Test.FakeState

  @session "devide_alpha_main"

  setup do
    previous = %{
      runner: Application.get_env(:tmux_ctl, :runner),
      fake_tmux_windows: FakeState.get(:fake_tmux_windows),
      fake_tmux_panes: FakeState.get(:fake_tmux_panes),
      fake_tmux_runner_pid: FakeState.get(:fake_tmux_runner_pid),
      fake_tmux_apply_defaults_code: FakeState.get(:fake_tmux_apply_defaults_code),
      fake_tmux_capture_output: FakeState.get(:fake_tmux_capture_output),
      fake_tmux_failures: FakeState.get(:fake_tmux_failures),
      terminal_env: Application.get_env(:tmux_ctl, :terminal_env),
      default_command: Application.get_env(:tmux_ctl, :default_command)
    }

    Application.put_env(:tmux_ctl, :runner, TmuxCtl.Test.FakeRunner)
    Application.delete_env(:tmux_ctl, :default_command)
    FakeState.put(:fake_tmux_runner_pid, self())

    on_exit(fn ->
      FakeState.restore(:fake_tmux_windows, previous.fake_tmux_windows)
      FakeState.restore(:fake_tmux_panes, previous.fake_tmux_panes)
      FakeState.restore(:fake_tmux_runner_pid, previous.fake_tmux_runner_pid)
      FakeState.restore(:fake_tmux_apply_defaults_code, previous.fake_tmux_apply_defaults_code)
      FakeState.restore(:fake_tmux_capture_output, previous.fake_tmux_capture_output)
      FakeState.restore(:fake_tmux_failures, previous.fake_tmux_failures)

      if previous.runner,
        do: Application.put_env(:tmux_ctl, :runner, previous.runner),
        else: Application.delete_env(:tmux_ctl, :runner)

      if previous.terminal_env,
        do: Application.put_env(:tmux_ctl, :terminal_env, previous.terminal_env),
        else: Application.delete_env(:tmux_ctl, :terminal_env)

      if previous.default_command,
        do: Application.put_env(:tmux_ctl, :default_command, previous.default_command),
        else: Application.delete_env(:tmux_ctl, :default_command)
    end)

    put_topology!(@session)
    :ok
  end

  test "list_session_windows and list_session_panes parse topology output" do
    assert [
             %{
               id: "@1",
               name: "shell",
               active: true,
               panes: 1,
               current_command: "bash"
             }
           ] = Client.list_session_windows(@session)

    assert [
             %{
               id: "%1",
               window_id: "@1",
               active: true,
               width: 120,
               height: 40,
               current_path: "/workspace",
               role: "operator",
               paired: false,
               paired_reason: "no agent env"
             }
           ] = Client.list_session_panes(@session)
  end

  test "session_topology returns windows and panes in one subprocess" do
    assert {windows, panes} = Client.session_topology(@session)
    assert [%{id: "@1"}] = windows
    assert [%{id: "%1"}] = panes
    assert_receive {:tmux_runner, argv}
    assert Enum.member?(argv, ";")
  end

  test "resize_pane issues resize-pane for managed devide sessions" do
    assert :ok = Client.resize_pane(@session, "%1", "right", 8)
    assert_receive {:tmux_runner, ["resize-pane", "-t", target, "-R", "8"]}
    assert target == "%1"
  end

  test "resize_pane uses bare pane id for high-numbered tmux pane ids" do
    assert :ok = Client.resize_pane(@session, "%8031", "down", 3)
    assert_receive {:tmux_runner, ["resize-pane", "-t", "%8031", "-D", "3"]}
  end

  test "resize_pane rejects non-devide sessions and invalid input" do
    assert {:error, :refused_non_devide_session} =
             Client.resize_pane("other_session", "%1", "left")

    assert {:error, :invalid_amount} = Client.resize_pane(@session, "%1", "up", 0)
    assert {:error, :invalid_resize} = Client.resize_pane(@session, "%1", "diagonal")
  end

  test "resize_window resizes every window and records the session default-size" do
    FakeState.put(:fake_tmux_windows, %{
      @session => [
        %{id: "@1", index: 0, name: "bash", active: true, panes: 1, activity: 0},
        %{id: "@4", index: 1, name: "claude", active: false, panes: 1, activity: 0}
      ]
    })

    assert :ok = Client.resize_window(@session, 100, 30)

    assert_receive {:tmux_runner, ["set-option", "-t", @session, "default-size", "100x30"]}

    assert_receive {:tmux_runner,
                    ["resize-window", "-t", @session <> ":@1", "-x", "100", "-y", "30"]}

    assert_receive {:tmux_runner,
                    ["resize-window", "-t", @session <> ":@4", "-x", "100", "-y", "30"]}
  end

  test "resize_window falls back to the current window when enumeration fails" do
    FakeState.put(:fake_tmux_failures, %{
      ["list-windows", "-t", @session, "-F", "\#{window_id}"] => {"no server", 1}
    })

    assert :ok = Client.resize_window(@session, 100, 30)
    assert_receive {:tmux_runner, ["resize-window", "-t", @session, "-x", "100", "-y", "30"]}
  end

  test "set_session_alias sets the devide alias user option" do
    assert :ok = Client.set_session_alias(@session, "billing")

    assert_receive {:tmux_runner,
                    ["set-option", "-t", @session, "@devide_session_alias", "billing"]}
  end

  test "set_session_alias unsets the option for a blank name" do
    assert :ok = Client.set_session_alias(@session, "   ")
    assert_receive {:tmux_runner, ["set-option", "-t", @session, "-u", "@devide_session_alias"]}
  end

  test "set_pane_role stores and clears a managed pane user option" do
    assert :ok = Client.set_pane_role(@session, "%1", "agent")

    assert_receive {:tmux_runner, ["set-option", "-p", "-t", "%1", "@devide_pane_role", "agent"]}

    assert :ok = Client.set_pane_role(@session, "%1", nil)
    assert_receive {:tmux_runner, ["set-option", "-p", "-t", "%1", "-u", "@devide_pane_role"]}
  end

  test "set_pane_role refuses unsafe roles and unmanaged sessions" do
    assert {:error, :invalid_role} = Client.set_pane_role(@session, "%1", "Agent Pane")

    assert {:error, :refused_non_devide_session} =
             Client.set_pane_role("other_session", "%1", "agent")

    refute_received {:tmux_runner, ["set-option", "-p", "-t", "%1", "@devide_pane_role", _]}
  end

  test "consolidate_sessions appends source windows into target session" do
    source = "devide_alpha_agent"

    FakeState.update(:fake_tmux_windows, %{}, fn windows ->
      Map.put(windows, source, [
        %{
          id: "@2",
          index: 0,
          name: "agent",
          active: true,
          panes: 1,
          activity: 0,
          current_command: "bash"
        },
        %{
          id: "@3",
          index: 1,
          name: "verify",
          active: false,
          panes: 1,
          activity: 0,
          current_command: "bash"
        }
      ])
    end)

    assert {:ok, %{moved_windows: 2, source_sessions: 1}} =
             Client.consolidate_sessions(@session, [source])

    source_window_2 = source <> ":@2"
    source_window_3 = source <> ":@3"
    target = @session <> ":"

    assert_receive {:tmux_runner, ["list-windows", "-t", ^source, "-F", _]}
    assert_receive {:tmux_runner, ["move-window", "-d", "-s", ^source_window_2, "-t", ^target]}
    assert_receive {:tmux_runner, ["move-window", "-d", "-s", ^source_window_3, "-t", ^target]}
  end

  test "consolidate_sessions refuses non-devide sessions" do
    assert {:error, :refused_non_devide_session} =
             Client.consolidate_sessions("other_session", [@session])

    assert {:error, :refused_non_devide_session} =
             Client.consolidate_sessions(@session, ["other_session"])
  end

  test "kill refuses non-devide sessions" do
    assert {:error, :refused_non_devide_session} = Client.kill("other_session")
    refute_received {:tmux_runner, ["kill-session", "-t", "other_session"]}
  end

  test "new_window includes configured terminal env" do
    Application.put_env(:tmux_ctl, :terminal_env, %{
      "DEV_IDE_CLIPBOARD" => "osc52",
      "PATH" => "/tmp/devide-shims:/usr/bin"
    })

    assert {:ok, _window_id} = Client.new_window(@session, name: "files", cwd: "/workspace")
    assert_receive {:tmux_runner, argv}
    assert contains_sequence?(argv, ["-e", "DEV_IDE_CLIPBOARD=osc52"])
    assert contains_sequence?(argv, ["-e", "PATH=/tmp/devide-shims:/usr/bin"])
  end

  test "new_window ignores malformed terminal env config" do
    Application.put_env(:tmux_ctl, :terminal_env, nil)

    assert {:ok, _window_id} = Client.new_window(@session, name: "files", cwd: "/workspace")
    assert_receive {:tmux_runner, argv}
    refute "-e" in argv
  end

  test "new_window appends configured default command when no command is provided" do
    Application.put_env(:tmux_ctl, :default_command, "devide-shell")

    assert {:ok, _window_id} = Client.new_window(@session, name: "files", cwd: "/workspace")
    assert_receive {:tmux_runner, argv}

    assert List.last(argv) == "devide-shell"
  end

  test "split_pane includes configured terminal env" do
    Application.put_env(:tmux_ctl, :terminal_env, %{"DEV_IDE_TERMINAL" => "1"})

    assert {:ok, _pane_id} = Client.split_pane(@session, "%1", "h")
    assert_receive {:tmux_runner, argv}
    assert contains_sequence?(argv, ["-e", "DEV_IDE_TERMINAL=1"])
  end

  test "split_pane appends default command unless an explicit command is provided" do
    Application.put_env(:tmux_ctl, :default_command, "devide-shell")

    assert {:ok, _pane_id} = Client.split_pane(@session, "%1", "h")
    assert_receive {:tmux_runner, argv}
    assert List.last(argv) == "devide-shell"

    assert {:ok, _pane_id} = Client.split_pane(@session, "%1", "h", command: "htop")
    assert_receive {:tmux_runner, argv}
    assert List.last(argv) == "htop"
    refute "devide-shell" in argv
  end

  test "apply_defaults succeeds when batched tmux call exits cleanly" do
    assert :ok = Client.apply_defaults(@session)
  end

  test "apply_defaults sets window-size manual so Casein owns resizing" do
    assert :ok = Client.apply_defaults(@session)
    assert_receive {:tmux_runner, argv}

    assert contains_sequence?(argv, [
             "set-option",
             "-t",
             @session,
             "window-size",
             "manual"
           ])

    refute Enum.member?(argv, "aggressive-resize")
  end

  test "apply_defaults sets pane-border-lines to single" do
    assert :ok = Client.apply_defaults(@session)
    assert_receive {:tmux_runner, argv}

    assert contains_sequence?(argv, [
             "set-option",
             "-t",
             @session,
             "-g",
             "pane-border-lines",
             "single"
           ])
  end

  test "apply_defaults pushes configured terminal env into the tmux session" do
    Application.put_env(:tmux_ctl, :terminal_env, %{"DEV_IDE_CLIPBOARD" => "osc52"})

    assert :ok = Client.apply_defaults(@session)
    assert_receive {:tmux_runner, argv}

    assert contains_sequence?(argv, [
             "set-environment",
             "-t",
             @session,
             "DEV_IDE_CLIPBOARD",
             "osc52"
           ])
  end

  test "apply_defaults sets configured default command on the session" do
    Application.put_env(:tmux_ctl, :default_command, "devide-shell")

    assert :ok = Client.apply_defaults(@session)
    assert_receive {:tmux_runner, argv}

    assert contains_sequence?(argv, [
             "set-option",
             "-t",
             @session,
             "default-command",
             "devide-shell"
           ])
  end

  test "apply_defaults reports partial failures individually" do
    FakeState.put(:fake_tmux_apply_defaults_code, 1)

    assert {:error, failures} = Client.apply_defaults(@session)
    assert Enum.any?(failures, fn {name, _code, _out} -> name == "mouse" end)
  end

  test "capture_scrollback tails output when lines is set" do
    FakeState.put(:fake_tmux_capture_output, "one\ntwo\nthree")

    assert "two\nthree" = Client.capture_scrollback(@session, lines: 2, ansi: false)
  end

  test "inject pastes text through a tmux buffer and sends enter by default" do
    assert :ok = Client.inject("%7", "hello\nworld")

    assert_receive {:tmux_runner, ["set-buffer", "-b", buffer, "--", "hello\nworld"]}
    assert_receive {:tmux_runner, ["paste-buffer", "-b", ^buffer, "-t", "%7"]}
    assert_receive {:tmux_runner, ["send-keys", "-t", "%7", "Enter"]}
    assert_receive {:tmux_runner, ["delete-buffer", "-b", ^buffer]}
  end

  test "inject can paste without sending enter" do
    assert :ok = Client.inject("%7", "draft", enter: false)

    assert_receive {:tmux_runner, ["set-buffer", "-b", buffer, "--", "draft"]}
    assert_receive {:tmux_runner, ["paste-buffer", "-b", ^buffer, "-t", "%7"]}
    refute_receive {:tmux_runner, ["send-keys", "-t", "%7", "Enter"]}
    assert_receive {:tmux_runner, ["delete-buffer", "-b", ^buffer]}
  end

  test "inject emits success telemetry" do
    handler_id = {__MODULE__, self(), :inject_success}

    :telemetry.attach(
      handler_id,
      [:dev_ide, :tmux, :inject],
      fn event, measurements, metadata, pid ->
        send(pid, {:tmux_inject_telemetry, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok = Client.inject("%7", "hello")

    assert_receive {:tmux_inject_telemetry, [:dev_ide, :tmux, :inject], %{count: 1},
                    %{target: "%7"}}
  end

  test "inject returns structured errors without leaking prompt text" do
    handler_id = {__MODULE__, self(), :inject_error}

    :telemetry.attach(
      handler_id,
      [:dev_ide, :tmux, :inject, :error],
      fn event, measurements, metadata, pid ->
        send(pid, {:tmux_inject_error_telemetry, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    FakeState.put(:fake_tmux_failures, %{"set-buffer" => {"set-buffer failed", 1}})

    assert {:error, %{command: command, exit_status: 1, output: "set-buffer failed"} = reason} =
             Client.inject("%7", "super secret prompt")

    assert ["tmux", "set-buffer", "-b", _buffer, "--", "[REDACTED]"] = command
    refute inspect(reason) =~ "super secret prompt"

    assert_receive {:tmux_inject_error_telemetry, [:dev_ide, :tmux, :inject, :error], %{count: 1},
                    %{reason: telemetry_reason, target: "%7"}}

    refute inspect(telemetry_reason) =~ "super secret prompt"
  end

  test "capture_recent returns captured text and targets recent history" do
    FakeState.put(:fake_tmux_capture_output, "recent output")

    assert {:ok, "recent output"} = Client.capture_recent("%7", 50)
    assert_receive {:tmux_runner, ["capture-pane", "-p", "-J", "-t", "%7", "-S", "-50"]}
  end

  defp put_topology!(session) do
    FakeState.put(:fake_tmux_windows, %{
      session => [
        %{
          id: "@1",
          index: 0,
          name: "shell",
          active: true,
          panes: 1,
          activity: 0,
          current_command: "bash"
        }
      ]
    })

    FakeState.put(:fake_tmux_panes, %{
      session => [
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
          role: "operator",
          activity: 10,
          activity_flag: true,
          bell: false,
          unseen_changes: true,
          zoomed?: true,
          paired: false,
          paired_reason: "no agent env"
        }
      ]
    })
  end

  defp contains_sequence?(tokens, sequence) do
    tokens
    |> Enum.chunk_every(length(sequence), 1, :discard)
    |> Enum.any?(&(&1 == sequence))
  end

  test "ensure_zoomed is idempotent when pane is already zoomed" do
    assert :ok = Client.ensure_zoomed(@session, "%1", true)
    refute_received {:tmux_runner, ["resize-pane", "-Z", "-t", _]}
  end

  test "ensure_zoomed toggles when pane is not zoomed" do
    FakeState.update(:fake_tmux_panes, %{}, fn panes ->
      Map.update!(panes, @session, fn session_panes ->
        Enum.map(session_panes, &Map.put(&1, :zoomed?, false))
      end)
    end)

    assert :ok = Client.ensure_zoomed(@session, "%1", true)
    assert_receive {:tmux_runner, ["resize-pane", "-Z", "-t", "%1"]}
  end
end
