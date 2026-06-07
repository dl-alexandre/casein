defmodule DevIDE.Terminals.SessionTemplateTest do
  use ExUnit.Case, async: false

  alias DevIDE.Terminals.SessionTemplate
  alias DevIDE.Terminals.SessionTemplate.Pane
  alias DevIDE.Terminals.SessionTemplate.Window

  setup do
    prev_windows = Application.get_env(:dev_ide, :fake_tmux_windows)
    prev_panes = Application.get_env(:dev_ide, :fake_tmux_panes)
    prev_next_window = Application.get_env(:dev_ide, :fake_tmux_next_window)
    prev_test_pid = Application.get_env(:dev_ide, :fake_tmux_test_pid)

    Application.put_env(:dev_ide, :fake_tmux_test_pid, self())

    on_exit(fn ->
      put_or_delete_env(:fake_tmux_windows, prev_windows)
      put_or_delete_env(:fake_tmux_panes, prev_panes)
      put_or_delete_env(:fake_tmux_next_window, prev_next_window)
      put_or_delete_env(:fake_tmux_test_pid, prev_test_pid)
    end)

    :ok
  end

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

  test "execute applies a template against tmux and resolves symbolic refs" do
    root = temp_workspace_root!()
    Application.put_env(:dev_ide, :fake_tmux_next_window, %{"template-session" => "@9"})

    assert {:ok, result} =
             SessionTemplate.execute("template-session", "generic_project",
               tmux: DevIDE.Test.FakeTmuxAdapter,
               workspace_root: root
             )

    assert result.template.id == "generic_project"
    assert result.step_count == 5
    assert result.refs["window:shell"] == "@9"
    assert result.refs["pane:shell:root"] == "%1"
    assert result.refs["pane:shell:git"] == "%2"
    assert result.refs["pane:shell:scratch"] == "%3"

    assert Enum.map(result.executed_steps, & &1.action) == [
             "new_window",
             "split_pane",
             "send_command",
             "split_pane",
             "select_pane"
           ]

    assert_receive {:fake_tmux_new_window, "template-session", new_window_opts}
    assert new_window_opts[:name] == "shell"
    assert new_window_opts[:cwd] == root

    assert_receive {:fake_tmux_split_pane, "template-session", "%1", "v", "%2"}
    assert_receive {:fake_tmux_send_command, "template-session", "%2", "git status --short", _}
    assert_receive {:fake_tmux_split_pane, "template-session", "%1", "h", "%3"}
    assert_receive {:fake_tmux_select_pane, "template-session", "%1"}

    assert [%{id: "%1", active: true}, %{id: "%2", active: false}, %{id: "%3", active: false}] =
             :dev_ide
             |> Application.get_env(:fake_tmux_panes)
             |> Map.fetch!("template-session")
             |> Enum.sort_by(& &1.id)
  end

  defp temp_workspace_root! do
    root =
      Path.join(System.tmp_dir!(), "devide-template-root-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp put_or_delete_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp put_or_delete_env(key, value), do: Application.put_env(:dev_ide, key, value)
end
