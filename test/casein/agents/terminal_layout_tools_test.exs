defmodule Casein.Agents.TerminalLayoutToolsTest do
  @moduledoc """
  The `terminal_layout_*` MCP surface: what it advertises, what it refuses,
  and that planning is the default rather than an opt-in.
  """
  use Casein.DataCase, async: false

  alias Casein.Agents.GrokCapabilityPolicy
  alias Casein.Agents.TerminalTools
  alias Casein.Terminals.Templates
  alias McpCtl.Tool
  alias TmuxCtl.Test.FakeState

  @workspace "ws-layout-mcp"
  @session "casein_ws-layout-mcp_main"

  setup do
    previous = %{
      windows: FakeState.get(:fake_tmux_windows),
      panes: FakeState.get(:fake_tmux_panes),
      test_pid: FakeState.get(:fake_tmux_test_pid),
      adapter: Application.get_env(:casein, :tmux_adapter)
    }

    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    FakeState.put(:fake_tmux_test_pid, self())

    on_exit(fn ->
      FakeState.restore(:fake_tmux_windows, previous.windows)
      FakeState.restore(:fake_tmux_panes, previous.panes)
      FakeState.restore(:fake_tmux_test_pid, previous.test_pid)

      if previous.adapter,
        do: Application.put_env(:casein, :tmux_adapter, previous.adapter),
        else: Application.delete_env(:casein, :tmux_adapter)
    end)

    root = temp_root!()
    seed_topology(root)

    {:ok, root: root}
  end

  describe "tools/list" do
    test "both layout tools are advertised and classified as mutations" do
      definitions = TerminalTools.definitions()

      for name <- ["terminal_layout_apply", "terminal_layout_snapshot"] do
        tool = Enum.find(definitions, &(&1.name == name))
        assert tool, "#{name} missing from tools/list"
        assert %{"mutation" => true} = Tool.public_metadata(tool)
      end
    end

    test "capability clients stay read-only until agent write is enabled" do
      locked = allowed_terminal_tools(false)
      unlocked = allowed_terminal_tools(true)

      refute "terminal_layout_apply" in locked
      refute "terminal_layout_snapshot" in locked
      assert "terminal_layout_apply" in unlocked
      assert "terminal_layout_snapshot" in unlocked
    end

    test "every tool still carries explicit mutation metadata" do
      assert GrokCapabilityPolicy.classified?()
    end
  end

  describe "terminal_layout_apply" do
    test "takes which layout, never where it goes" do
      for key <- ~w(placement size position pane_id window_id geometry focus fraction ratio) do
        args = %{
          "workspace_id" => @workspace,
          "session" => @session,
          "template_id" => "tpl-1",
          key => "anything"
        }

        assert {:error, error} = TerminalTools.invoke("terminal_layout_apply", args)
        assert error.error == :placement_not_allowed
        assert key in error.rejected
      end
    end

    test "plans by default and changes nothing", %{root: root} do
      template = save_template!(root)

      assert {:ok, payload} =
               TerminalTools.invoke("terminal_layout_apply", %{
                 "workspace_id" => @workspace,
                 "session" => @session,
                 "template_id" => template.id
               })

      assert payload.mode == "planned"
      refute payload.applied?
      assert payload.focus_unchanged?
      assert payload.additive_only?
      assert is_binary(payload.plan_digest)

      # The handoff tells the caller how to actually execute.
      assert payload.next_tool == "terminal_layout_apply"
      assert payload.next_arguments.dry_run == false
      assert payload.next_arguments.plan_digest == payload.plan_digest

      refute_received {:fake_tmux_split_pane, _, _, _, _}
      refute_received {:fake_tmux_new_window, _, _}
      refute_received {:fake_tmux_send_command, _, _, _, _}
    end

    test "executing without the plan digest is refused", %{root: root} do
      template = save_template!(root)

      assert {:error, error} =
               TerminalTools.invoke("terminal_layout_apply", %{
                 "workspace_id" => @workspace,
                 "session" => @session,
                 "template_id" => template.id,
                 "dry_run" => false
               })

      assert error.error == :plan_stale
      refute_received {:fake_tmux_split_pane, _, _, _, _}
    end

    test "a built-in template id is refused rather than replayed" do
      assert {:error, :unsupported_reconcile} =
               TerminalTools.invoke("terminal_layout_apply", %{
                 "workspace_id" => @workspace,
                 "session" => @session,
                 "template_id" => "agent_pair"
               })
    end
  end

  describe "terminal_layout_snapshot" do
    test "saves an undo point and hands back how to apply it" do
      assert {:ok, payload} =
               TerminalTools.invoke("terminal_layout_snapshot", %{
                 "workspace_id" => @workspace,
                 "session" => @session,
                 "name" => "before the change",
                 "tags" => ["undo"]
               })

      assert payload.saved?
      assert payload.template_id
      assert payload.name == "before the change"
      assert payload.window_count == 1
      assert payload.next_tool == "terminal_layout_apply"
      assert payload.next_arguments.template_id == payload.template_id

      assert {:ok, saved} = Templates.get(@workspace, payload.template_id)
      assert saved.tags == ["undo"]

      refute_received {:fake_tmux_split_pane, _, _, _, _}
      refute_received {:fake_tmux_select_pane, _, _}
    end

    test "dry run previews without saving" do
      before = Templates.list_for_workspace(@workspace) |> length()

      assert {:ok, payload} =
               TerminalTools.invoke("terminal_layout_snapshot", %{
                 "workspace_id" => @workspace,
                 "session" => @session,
                 "dry_run" => true
               })

      refute payload.saved?
      assert payload.template_id == nil
      assert Templates.list_for_workspace(@workspace) |> length() == before
    end

    test "refuses a session outside the caller's workspace" do
      assert {:error, :workspace_mismatch} =
               TerminalTools.invoke("terminal_layout_snapshot", %{
                 "workspace_id" => @workspace,
                 "session" => "casein_other-workspace_main"
               })
    end
  end

  # ---------------------------------------------------------------------------

  defp allowed_terminal_tools(write_enabled?) do
    TerminalTools.definitions()
    |> Enum.filter(fn tool ->
      case Tool.public_metadata(tool) do
        %{"mutation" => false} -> true
        %{"mutation" => true} -> write_enabled?
        _ -> false
      end
    end)
    |> Enum.map(& &1.name)
  end

  defp save_template!(root) do
    {:ok, saved} =
      Templates.save(%{
        workspace_id: @workspace,
        name: "mcp-layout",
        body: %{
          "version" => 2,
          "name" => "mcp-layout",
          "root" => "${workspace_root}",
          "windows" => [
            %{
              "name" => "server",
              "root" => "${workspace_root}",
              "layout" => %{
                "direction" => "horizontal",
                "panes" => [
                  %{"name" => "app", "cwd" => "${workspace_root}", "command" => "mix phx.server"},
                  %{
                    "name" => "logs",
                    "cwd" => "${workspace_root}",
                    "command" => "tail -f log/dev.log"
                  }
                ]
              }
            }
          ]
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
        "casein-layout-mcp-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
