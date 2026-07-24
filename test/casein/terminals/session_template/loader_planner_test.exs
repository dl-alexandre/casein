defmodule Casein.Terminals.SessionTemplate.LoaderPlannerTest do
  use Casein.TestCase, async: true

  alias Casein.Terminals.SessionTemplate
  alias Casein.Terminals.SessionTemplate.Executor
  alias Casein.Terminals.SessionTemplate.Loader
  alias Casein.Terminals.SessionTemplate.Pane
  alias Casein.Terminals.SessionTemplate.Planner
  alias Casein.Terminals.SessionTemplate.Window

  describe "Loader" do
    test "built_in/0 exposes the four hard-coded templates" do
      built_in = Loader.built_in()

      assert Map.keys(built_in) |> Enum.sort() ==
               ["agent_pair", "agent_preview_demo", "generic_project", "phoenix_dev"]

      assert Enum.all?(Map.values(built_in), &match?(%SessionTemplate{}, &1))
    end

    test "agent_pair declares durable pane roles" do
      assert %SessionTemplate{windows: [window]} = Loader.built_in()["agent_pair"]
      assert window.role == "operator"

      assert Enum.map(window.panes, &{&1.id, &1.role}) == [
               {"agent", "agent"},
               {"verify", "verify"}
             ]
    end

    test "list/0 returns built-ins sorted by id with no saved templates" do
      ids = Loader.list() |> Enum.map(& &1.id)
      assert ids == ["agent_pair", "agent_preview_demo", "generic_project", "phoenix_dev"]
    end

    test "get/1 resolves a known id and rejects unknown ids" do
      assert {:ok, %SessionTemplate{id: "phoenix_dev"}} = Loader.get("phoenix_dev")
      assert {:error, :template_not_found} = Loader.get("does-not-exist")
    end
  end

  describe "Planner.dry_run/2 with built-in templates" do
    test "plans windows, commands, and splits for phoenix_dev" do
      assert {:ok, result} = Planner.dry_run("phoenix_dev")

      assert result.dry_run == true
      assert result.template.windows == 2
      assert result.step_count == length(result.steps)

      actions = Enum.map(result.steps, & &1.action)
      assert Enum.count(actions, &(&1 == "new_window")) == 2
      assert "split_pane" in actions
      assert "send_command" in actions

      commands =
        result.steps
        |> Enum.filter(&(&1.action == "send_command"))
        |> Enum.map(&get_in(&1, [:params, :command]))

      assert "mix phx.server" in commands
    end

    test "adds a focus select_pane step for a focused window" do
      assert {:ok, result} = Planner.dry_run("generic_project")
      assert List.last(result.steps).action == "select_pane"
    end

    test "indexes steps sequentially" do
      assert {:ok, result} = Planner.dry_run("agent_pair")
      assert Enum.map(result.steps, & &1.index) == Enum.to_list(1..result.step_count)
    end

    test "carries pane roles in dry-run metadata" do
      assert {:ok, result} = Planner.dry_run("agent_pair")

      assert %{action: "new_window", metadata: %{role: "operator"}} =
               Enum.find(result.steps, &(Map.get(&1, :ref) == "window:work"))

      assert %{action: "split_pane", metadata: %{role: "agent"}} =
               Enum.find(result.steps, &(Map.get(&1, :ref) == "pane:work:agent"))

      assert %{action: "split_pane", metadata: %{role: "verify"}} =
               Enum.find(result.steps, &(Map.get(&1, :ref) == "pane:work:verify"))
    end

    test "rejects unknown ids and non-template inputs" do
      assert {:error, :template_not_found} = Planner.dry_run("nope")
      assert {:error, :template_not_found} = Planner.dry_run(123)
    end
  end

  describe "Planner with a custom template" do
    test "normalizes roles on custom windows and panes" do
      assert {:ok,
              %SessionTemplate{
                windows: [
                  %Window{
                    role: "operator",
                    panes: [%Pane{role: "agent"}]
                  }
                ]
              }} =
               SessionTemplate.new(%{
                 id: "custom",
                 name: "Custom",
                 windows: [
                   %{
                     name: "main",
                     role: "Operator",
                     panes: [%{id: "agent", role: "Agent"}]
                   }
                 ]
               })
    end

    test "rejects unsafe roles" do
      assert {:error, :invalid_role} =
               Pane.new(%{id: "bad", role: "agent pane"})

      assert {:error, :invalid_role} =
               Window.new(%{name: "bad", role: "operator|agent"})
    end

    test "honors a focused pane, size_percent, and per-pane cwd" do
      template = %SessionTemplate{
        id: "custom",
        name: "Custom",
        description: "custom",
        windows: [
          %Window{
            id: "main",
            name: "main",
            cwd: "/repo",
            panes: [
              %Pane{
                id: "right",
                split_direction: "v",
                command: "htop",
                cwd: "/repo/sub",
                size_percent: 40,
                focus: true
              }
            ]
          }
        ]
      }

      assert {:ok, steps} = Planner.plan(template)
      split = Enum.find(steps, &(&1.action == "split_pane"))
      assert split.params.direction == "v"
      assert split.params.size_percent == 40
      assert split.params.cwd == "/repo/sub"

      # Focused pane drives the trailing select_pane step onto that pane ref.
      focus = List.last(steps)
      assert focus.action == "select_pane"
      assert focus.target_ref == "pane:main:right"
    end
  end

  describe "Executor delegation" do
    test "plan/2 and dry_run/2 delegate to the Planner" do
      assert {:ok, steps} = Executor.plan("agent_pair")
      assert is_list(steps)
      assert {:ok, %{dry_run: true}} = Executor.dry_run("agent_pair")
    end

    test "execute/3 surfaces resolution errors before touching tmux" do
      assert {:error, :template_not_found} = Executor.execute("session", "unknown")
    end
  end
end
