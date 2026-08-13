defmodule Casein.Terminals.LayoutOpsTest do
  @moduledoc """
  The shared declarative-layout context: one mutate path, two lanes.

  These pin what the `:agent` lane refuses, because that is the whole reason
  MCP is allowed near session layout at all.
  """
  use Casein.DataCase, async: false

  alias Casein.Terminals.LayoutOps
  alias Casein.Terminals.Templates
  alias TmuxCtl.Test.FakeState

  @workspace "ws-layout-1"
  @session "casein_ws-layout-1_main"

  setup do
    previous = %{
      windows: FakeState.get(:fake_tmux_windows),
      panes: FakeState.get(:fake_tmux_panes),
      next_window: FakeState.get(:fake_tmux_next_window),
      test_pid: FakeState.get(:fake_tmux_test_pid),
      adapter: Application.get_env(:casein, :tmux_adapter)
    }

    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    FakeState.put(:fake_tmux_test_pid, self())

    on_exit(fn ->
      FakeState.restore(:fake_tmux_windows, previous.windows)
      FakeState.restore(:fake_tmux_panes, previous.panes)
      FakeState.restore(:fake_tmux_next_window, previous.next_window)
      FakeState.restore(:fake_tmux_test_pid, previous.test_pid)

      if previous.adapter,
        do: Application.put_env(:casein, :tmux_adapter, previous.adapter),
        else: Application.delete_env(:casein, :tmux_adapter)
    end)

    root = temp_root!()
    seed_topology(root)

    {:ok, root: root}
  end

  describe "validate_plan/2 — the no-close guarantee" do
    test "refuses any change action outside the additive allowlist" do
      changes = [
        %{index: 1, action: "create_window", target_id: nil, template_ref: %{ref: "window:a"}},
        %{index: 2, action: "kill_pane", target_id: "%7", template_ref: %{ref: "pane:a:1"}}
      ]

      assert {:error, error} = LayoutOps.validate_plan(changes, :operator)
      assert error.error == :destructive_change_refused
      assert [%{action: "kill_pane", target_id: "%7"}] = error.refused

      # Same refusal on the agent lane — neither lane can close anything.
      assert {:error, %{error: :destructive_change_refused}} =
               LayoutOps.validate_plan(changes, :agent)
    end

    test "agent lane strips focus changes, operator lane keeps them" do
      changes = [
        %{index: 1, action: "split_pane", target_id: "%1", template_ref: %{ref: "pane:a:1"}},
        %{index: 2, action: "select_pane", target_id: "%2", template_ref: %{ref: "pane:a:2"}}
      ]

      assert {:ok, executable, skipped} = LayoutOps.validate_plan(changes, :agent)
      assert Enum.map(executable, & &1.action) == ["split_pane"]
      assert [%{action: "select_pane", skipped_reason: "focus_belongs_to_operator"}] = skipped

      assert {:ok, operator_executable, []} = LayoutOps.validate_plan(changes, :operator)
      assert Enum.map(operator_executable, & &1.action) == ["split_pane", "select_pane"]
    end
  end

  describe "plan/4" do
    test "returns a digest that is stable across repeated planning", %{root: root} do
      template = save_template!(root)

      assert {:ok, first} =
               LayoutOps.plan(@workspace, @session, template.id,
                 lane: :agent,
                 workspace_root: root
               )

      assert {:ok, second} =
               LayoutOps.plan(@workspace, @session, template.id,
                 lane: :agent,
                 workspace_root: root
               )

      assert first.digest == second.digest
      assert byte_size(first.digest) == 16
      refute Enum.any?(first.changes, &(&1.action == "select_pane"))
    end

    test "built-in templates have no reconcile plan" do
      assert {:error, :unsupported_reconcile} =
               LayoutOps.plan(@workspace, @session, "agent_pair", lane: :agent)
    end
  end

  describe "apply_plan/4 on the agent lane" do
    test "refuses without the digest of a plan the caller has seen", %{root: root} do
      template = save_template!(root)

      assert {:error, error} =
               LayoutOps.apply_plan(@workspace, @session, template.id,
                 lane: :agent,
                 workspace_root: root
               )

      assert error.error == :plan_stale
      assert error.expected_digest == nil
      refute_received {:fake_tmux_split_pane, _, _, _, _}
      refute_received {:fake_tmux_send_command, _, _, _, _}
    end

    test "refuses a digest that no longer matches the live layout", %{root: root} do
      template = save_template!(root)

      assert {:error, %{error: :plan_stale, plan_digest: current}} =
               LayoutOps.apply_plan(@workspace, @session, template.id,
                 lane: :agent,
                 workspace_root: root,
                 expect_digest: "0000000000000000"
               )

      assert is_binary(current)
      refute_received {:fake_tmux_split_pane, _, _, _, _}
    end

    test "applies with a matching digest, never touching focus", %{root: root} do
      template = save_template!(root)

      assert {:ok, plan} =
               LayoutOps.plan(@workspace, @session, template.id,
                 lane: :agent,
                 workspace_root: root
               )

      assert {:ok, result} =
               LayoutOps.apply_plan(@workspace, @session, template.id,
                 lane: :agent,
                 workspace_root: root,
                 expect_digest: plan.digest,
                 tmux: Casein.Test.FakeTmuxAdapter
               )

      assert result.execution.plan_executed
      assert_receive {:fake_tmux_split_pane, @session, _target, _direction, _new_pane}
      assert_receive {:fake_tmux_send_command, @session, _pane, "tail -f log/dev.log", _}

      # The operator's cursor is not the agent's to move.
      refute_received {:fake_tmux_select_pane, _session, _pane}
      assert Enum.any?(result.skipped, &(&1.action == "select_pane"))
    end

    test "saves an undo snapshot before executing", %{root: root} do
      template = save_template!(root)
      before = Templates.list_for_workspace(@workspace) |> length()

      assert {:ok, plan} =
               LayoutOps.plan(@workspace, @session, template.id,
                 lane: :agent,
                 workspace_root: root
               )

      assert {:ok, result} =
               LayoutOps.apply_plan(@workspace, @session, template.id,
                 lane: :agent,
                 workspace_root: root,
                 expect_digest: plan.digest,
                 tmux: Casein.Test.FakeTmuxAdapter
               )

      assert %{template_id: undo_id} = result.undo
      assert Templates.list_for_workspace(@workspace) |> length() == before + 1
      assert {:ok, undo} = Templates.get(@workspace, undo_id)
      assert "undo" in undo.tags
    end

    test "refuses a template carrying a command the policy blocks", %{root: root} do
      template = save_template!(root, command: "sudo systemctl restart nginx")

      assert {:ok, plan} =
               LayoutOps.plan(@workspace, @session, template.id,
                 lane: :agent,
                 workspace_root: root
               )

      assert {:error, error} =
               LayoutOps.apply_plan(@workspace, @session, template.id,
                 lane: :agent,
                 workspace_root: root,
                 expect_digest: plan.digest,
                 tmux: Casein.Test.FakeTmuxAdapter
               )

      assert error.error == :command_blocked
      assert error.command == "sudo systemctl restart nginx"
      refute_received {:fake_tmux_split_pane, _, _, _, _}
      refute_received {:fake_tmux_send_command, _, _, _, _}
    end

    test "operator lane keeps its focus restore and needs no digest", %{root: root} do
      template = save_template!(root)

      assert {:ok, result} =
               LayoutOps.apply_plan(@workspace, @session, template.id,
                 lane: :operator,
                 workspace_root: root,
                 tmux: Casein.Test.FakeTmuxAdapter
               )

      assert result.undo == nil
      assert result.skipped == []
      assert_receive {:fake_tmux_select_pane, @session, _pane}
    end
  end

  describe "snapshot/3" do
    test "saves the live layout as a template that can be applied back", %{root: root} do
      assert {:ok, snapshot} =
               LayoutOps.snapshot(@workspace, @session,
                 workspace_root: root,
                 name: "before change",
                 tags: ["undo"],
                 actor_id: "agent"
               )

      assert snapshot.saved.id
      assert snapshot.saved.name == "before change"
      assert snapshot.saved.source_session == @session
      assert snapshot.template["windows"] != []

      assert {:ok, _plan} =
               LayoutOps.plan(@workspace, @session, snapshot.saved.id,
                 lane: :agent,
                 workspace_root: root
               )
    end

    test "save: false previews without writing a row", %{root: root} do
      before = Templates.list_for_workspace(@workspace) |> length()

      assert {:ok, snapshot} =
               LayoutOps.snapshot(@workspace, @session, workspace_root: root, save: false)

      assert snapshot.saved == nil
      assert snapshot.yaml =~ "windows"
      assert Templates.list_for_workspace(@workspace) |> length() == before
    end

    test "does not touch tmux", %{root: root} do
      assert {:ok, _snapshot} = LayoutOps.snapshot(@workspace, @session, workspace_root: root)

      refute_received {:fake_tmux_split_pane, _, _, _, _}
      refute_received {:fake_tmux_new_window, _, _}
      refute_received {:fake_tmux_select_pane, _, _}
      refute_received {:fake_tmux_send_command, _, _, _, _}
    end
  end

  # ---------------------------------------------------------------------------

  defp save_template!(root, opts \\ []) do
    command = Keyword.get(opts, :command, "tail -f log/dev.log")

    {:ok, saved} =
      Templates.save(%{
        workspace_id: @workspace,
        name: "layout-under-test",
        body: %{
          "version" => 2,
          "name" => "layout-under-test",
          "root" => "${workspace_root}",
          "windows" => [
            %{
              "name" => "server",
              "root" => "${workspace_root}",
              "layout" => %{
                "direction" => "horizontal",
                "panes" => [
                  %{
                    "name" => "app",
                    "cwd" => "${workspace_root}",
                    "command" => "mix phx.server"
                  },
                  %{"name" => "logs", "cwd" => "${workspace_root}", "command" => command}
                ]
              }
            }
          ],
          "startup" => %{"window" => "server", "pane" => "app"}
        },
        source_session: @session,
        schema_version: 2
      })

    _ = root
    saved
  end

  defp seed_topology(root) do
    FakeState.put(:fake_tmux_windows, %{
      @session => [
        %{
          id: "@1",
          index: 0,
          name: "server",
          active: true,
          panes: 1,
          activity: 0,
          current_command: "mix"
        }
      ]
    })

    FakeState.put(:fake_tmux_panes, %{
      @session => [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 160,
          height: 40,
          current_command: "mix",
          current_path: root
        }
      ]
    })
  end

  defp temp_root! do
    root =
      Path.join(
        System.tmp_dir!(),
        "casein-layout-ops-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
