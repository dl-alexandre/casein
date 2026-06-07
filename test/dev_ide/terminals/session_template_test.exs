defmodule DevIDE.Terminals.SessionTemplateTest do
  use ExUnit.Case, async: true

  alias DevIDE.Terminals.SessionTemplate
  alias DevIDE.Terminals.SessionTemplate.Pane
  alias DevIDE.Terminals.SessionTemplate.Window

  test "lists built-in templates in stable id order" do
    templates = SessionTemplate.list()

    assert Enum.map(templates, & &1.id) == [
             "agent_pair",
             "generic_project",
             "phoenix_dev"
           ]

    assert {:ok, %SessionTemplate{name: "Phoenix Dev"}} = SessionTemplate.get("phoenix_dev")
    assert {:error, :template_not_found} = SessionTemplate.get("missing")
  end

  test "normalizes template maps into structs" do
    assert {:ok,
            %SessionTemplate{
              id: "custom",
              name: "Custom",
              windows: [
                %Window{
                  id: "ops",
                  name: "ops",
                  panes: [
                    %Pane{id: "logs", split_direction: "v", size_percent: 40}
                  ]
                }
              ]
            }} =
             SessionTemplate.new(%{
               "id" => "custom",
               "name" => "Custom",
               "windows" => [
                 %{
                   "name" => "ops",
                   "panes" => [
                     %{"id" => "logs", "split_direction" => "v", "size_percent" => "40"}
                   ]
                 }
               ]
             })
  end

  test "rejects invalid template shape" do
    assert {:error, :windows_required} =
             SessionTemplate.new(%{id: "empty", name: "Empty", windows: []})

    assert {:error, :invalid_direction} =
             SessionTemplate.new(%{
               id: "bad",
               name: "Bad",
               windows: [
                 %{name: "main", panes: [%{id: "bad-pane", split_direction: "diagonal"}]}
               ]
             })

    assert {:error, :invalid_size_percent} =
             SessionTemplate.new(%{
               id: "bad-size",
               name: "Bad Size",
               windows: [
                 %{name: "main", panes: [%{id: "bad-pane", size_percent: 100}]}
               ]
             })
  end

  test "dry run returns deterministic tmux plan steps" do
    assert {:ok, dry_run} = SessionTemplate.dry_run("phoenix_dev")

    assert dry_run.dry_run == true
    assert dry_run.template.id == "phoenix_dev"
    assert dry_run.step_count == length(dry_run.steps)
    assert Enum.map(dry_run.steps, & &1.index) == Enum.to_list(1..dry_run.step_count)

    assert Enum.any?(dry_run.steps, fn step ->
             step.action == "new_window" and step.ref == "window:server" and
               step.params == %{name: "server", cwd: "."}
           end)

    assert Enum.any?(dry_run.steps, fn step ->
             step.action == "split_pane" and step.ref == "pane:server:console" and
               step.target_ref == "pane:server:root" and step.params.direction == "v"
           end)

    assert Enum.any?(dry_run.steps, fn step ->
             step.action == "send_command" and step.target_ref == "pane:tests:logs" and
               step.params.command == "tail -n 200 -f log/dev.log"
           end)

    assert List.last(dry_run.steps) == %{
             index: dry_run.step_count,
             action: "select_pane",
             target_ref: "pane:server:root",
             params: %{}
           }
  end

  test "pane focus overrides window focus in dry-run plan" do
    assert {:ok, dry_run} = SessionTemplate.dry_run("agent_pair")

    assert List.last(dry_run.steps).action == "select_pane"
    assert List.last(dry_run.steps).target_ref == "pane:work:agent"
  end
end
