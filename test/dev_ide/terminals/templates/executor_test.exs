defmodule Casein.Terminals.Templates.ExecutorTest do
  use Casein.TestCase, async: true

  alias Casein.Terminals.Templates.Executor

  defp saved(body) do
    %{
      id: "tpl-1",
      name: "dev",
      description: "Dev layout",
      schema_version: 2,
      body: body
    }
  end

  describe "dry_run/2 planning" do
    setup do
      body = %{
        "version" => 2,
        "root" => "/repo",
        "startup" => %{"window" => "editor", "pane" => "shell"},
        "windows" => [
          %{
            "name" => "editor",
            "root" => "/repo/app",
            "layout" => %{
              "direction" => "horizontal",
              "panes" => [
                %{"command" => "vim", "name" => "edit", "cwd" => "/repo/app"},
                %{"command" => "iex -S mix", "name" => "shell", "size" => "30%"}
              ]
            }
          },
          %{
            "name" => "logs",
            "focus" => true,
            "layout" => %{"command" => "tail -f log/dev.log", "name" => "tail"}
          },
          %{
            "name" => "grid",
            "layout" => %{
              "direction" => "tiled",
              "panes" => [%{"command" => "htop"}, %{"command" => "watch ls"}]
            }
          }
        ]
      }

      {:ok, result} = Executor.dry_run(saved(body))
      %{result: result, steps: result.steps}
    end

    test "summarizes the template", %{result: result} do
      assert result.dry_run == true
      assert result.template.name == "dev"
      assert result.template.windows == 3
      assert result.template.source == "exported"
      assert result.step_count == length(result.steps)
    end

    test "creates one new_window step per window", %{steps: steps} do
      assert Enum.count(steps, &(&1.action == "new_window")) == 3
    end

    test "plans splits, tiled panes, and send_command leaves", %{steps: steps} do
      assert Enum.any?(steps, &(&1.action == "split_pane"))
      assert Enum.any?(steps, &(&1.action == "send_command"))

      commands =
        steps
        |> Enum.filter(&(&1.action == "send_command"))
        |> Enum.map(&get_in(&1, [:params, :command]))

      assert "vim" in commands
      assert "tail -f log/dev.log" in commands
      assert "htop" in commands
    end

    test "indexes every step sequentially", %{steps: steps} do
      indexes = Enum.map(steps, & &1.index)
      assert indexes == Enum.to_list(1..length(steps))
    end

    test "appends a focus select_pane step when a startup pane matches", %{steps: steps} do
      assert List.last(steps).action == "select_pane"
    end
  end

  describe "dry_run/2 edge cases" do
    test "normalizes vertical direction and tolerates unnamed leaves" do
      body = %{
        "version" => 2,
        "windows" => [
          %{
            "layout" => %{
              "direction" => "vertical",
              "panes" => [%{"command" => "a"}, %{"command" => "b"}]
            }
          }
        ]
      }

      assert {:ok, result} = Executor.dry_run(saved(body))
      split = Enum.find(result.steps, &(&1.action == "split_pane"))
      assert split.params.direction == "v"
    end

    test "requires windows for a v2 template" do
      assert {:error, :windows_required} = Executor.dry_run(saved(%{"version" => 2}))

      assert {:error, :windows_required} =
               Executor.dry_run(saved(%{"version" => 2, "windows" => []}))
    end

    test "rejects unsupported template bodies" do
      assert {:error, :unsupported_template} = Executor.dry_run(saved(%{"version" => 1}))
      assert {:error, :unsupported_template} = Executor.dry_run(saved(nil))
    end
  end

  describe "execute/3" do
    test "surfaces planning errors before touching tmux" do
      assert {:error, :unsupported_template} =
               Executor.execute("session", saved(%{"version" => 1}))
    end
  end
end
