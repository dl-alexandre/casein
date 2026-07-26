defmodule Casein.Terminals.SessionTemplateTest do
  use Casein.DataCase, async: false

  alias Casein.Terminals.SessionTemplate
  alias Casein.Terminals.SessionTemplate.Pane
  alias Casein.Terminals.SessionTemplate.Window

  setup do
    prev_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)
    prev_next_window = TmuxCtl.Test.FakeState.get(:fake_tmux_next_window)
    prev_test_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)

    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

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
             "agent_preview_demo",
             "generic_project",
             "phoenix_dev"
           ]

    assert {:ok, %SessionTemplate{name: "Phoenix Dev"}} = SessionTemplate.get("phoenix_dev")
    assert {:error, :template_not_found} = SessionTemplate.get("missing")
  end

  test "built_in map exposes all starter templates by id" do
    built_in = SessionTemplate.built_in()

    assert map_size(built_in) == 4
    assert %SessionTemplate{id: "agent_pair"} = built_in["agent_pair"]
    assert %SessionTemplate{id: "phoenix_dev", windows: windows} = built_in["phoenix_dev"]
    assert length(windows) == 2
  end

  test "list/1 merges saved workspace exports after built-ins" do
    body = %{
      "version" => 2,
      "windows" => [
        %{
          "name" => "saved",
          "layout" => %{
            "direction" => "horizontal",
            "panes" => [%{"name" => "left"}, %{"name" => "right"}]
          }
        }
      ]
    }

    assert {:ok, saved} =
             Casein.Terminals.Templates.save(%{
               workspace_id: "ws-templates",
               name: "saved_layout",
               description: "Saved export",
               body: body,
               source_session: "casein_ws",
               schema_version: 2
             })

    templates = SessionTemplate.list("ws-templates")
    ids = Enum.map(templates, & &1.id)

    assert ids == ["agent_pair", "agent_preview_demo", "generic_project", "phoenix_dev", saved.id]

    [saved_template] = Enum.filter(templates, &(&1.id == saved.id))
    assert saved_template.name == "saved_layout"
    assert [%{panes: [%Pane{split_direction: "h"}]}] = saved_template.windows
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
    assert List.last(dry_run.steps).target_ref == "pane:work:root"
  end

  test "agent_preview_demo plan starts demo server in agent pane" do
    assert {:ok, dry_run} = SessionTemplate.dry_run("agent_preview_demo")

    assert dry_run.template.id == "agent_preview_demo"

    assert Enum.any?(dry_run.steps, fn step ->
             step.action == "send_command" and step.target_ref == "pane:work:agent" and
               step.params.command == "bash scripts/run-preview-demo.sh"
           end)
  end

  test "exports live topology as a v2 template map and yaml" do
    root = temp_workspace_root!()
    web_root = Path.join(root, "apps/web")

    topology = %{
      session: "casein_alpha_u-dev",
      version: 42,
      active_window_id: "@1",
      active_pane_id: "%2",
      windows: [
        %{
          id: "@1",
          index: 0,
          name: "server",
          active: true,
          pane_list: [
            %{
              id: "%1",
              index: 0,
              active: false,
              left: 0,
              top: 0,
              width: 60,
              height: 40,
              current_command: "mix",
              current_path: root
            },
            %{
              id: "%2",
              index: 1,
              active: true,
              left: 60,
              top: 0,
              width: 60,
              height: 20,
              current_command: "iex",
              current_path: web_root
            },
            %{
              id: "%3",
              index: 2,
              active: false,
              left: 60,
              top: 20,
              width: 60,
              height: 20,
              current_command: "tail",
              current_path: web_root
            }
          ]
        }
      ]
    }

    assert {:ok, template} =
             SessionTemplate.export_topology(topology,
               workspace_root: root,
               name: "current_layout"
             )

    assert template["version"] == 2
    assert template["name"] == "current_layout"
    assert template["root"] == "${workspace_root}"
    assert template["metadata"]["session"] == "casein_alpha_u-dev"
    assert template["metadata"]["topology_version"] == 42
    assert template["startup"] == %{"window" => "server", "pane" => "iex"}

    [window] = template["windows"]
    assert window["name"] == "server"
    assert window["root"] == "${workspace_root}/apps/web"
    assert window["focus"] == true
    assert window["layout"]["direction"] == "horizontal"

    [left, right] = window["layout"]["panes"]
    assert left["name"] == "mix"
    assert left["cwd"] == "${workspace_root}"
    assert left["command"] == "mix"
    assert right["direction"] == "vertical"

    assert [%{"name" => "iex", "focus" => true}, %{"name" => "tail"}] =
             right["panes"]
             |> Enum.map(&Map.take(&1, ["name", "focus"]))

    yaml = Casein.Terminals.SessionTemplate.Export.to_yaml(template)
    assert yaml =~ "version: 2"
    assert yaml =~ ~s(name: "current_layout")
    assert yaml =~ ~s(direction: "horizontal")
  end

  test "execute applies a template against tmux and resolves symbolic refs" do
    root = temp_workspace_root!()
    TmuxCtl.Test.FakeState.put(:fake_tmux_next_window, %{"template-session" => "@9"})

    assert {:ok, result} =
             SessionTemplate.execute("template-session", "generic_project",
               tmux: Casein.Test.FakeTmuxAdapter,
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
             :fake_tmux_panes
             |> TmuxCtl.Test.FakeState.get(%{})
             |> Map.fetch!("template-session")
             |> Enum.sort_by(& &1.id)
  end

  test "execute persists agent_pair pane roles in tmux metadata" do
    session = "casein_alpha_agent_pair"
    root = temp_workspace_root!()
    TmuxCtl.Test.FakeState.put(:fake_tmux_next_window, %{session => "@9"})

    assert {:ok, result} =
             SessionTemplate.execute(session, "agent_pair",
               tmux: Casein.Test.FakeTmuxAdapter,
               workspace_root: root
             )

    assert result.template.id == "agent_pair"
    assert result.refs["pane:work:root"] == "%1"
    assert result.refs["pane:work:agent"] == "%2"
    assert result.refs["pane:work:verify"] == "%3"

    assert Enum.find(result.executed_steps, &(&1.ref == "window:work")).metadata ==
             %{role: "operator"}

    assert Enum.find(result.executed_steps, &(&1.ref == "pane:work:agent")).metadata ==
             %{role: "agent"}

    assert_receive {:fake_tmux_set_pane_role, ^session, "%1", "operator"}
    assert_receive {:fake_tmux_set_pane_role, ^session, "%2", "agent"}
    assert_receive {:fake_tmux_set_pane_role, ^session, "%3", "verify"}

    roles =
      :fake_tmux_panes
      |> TmuxCtl.Test.FakeState.get(%{})
      |> Map.fetch!(session)
      |> Map.new(&{&1.id, Map.get(&1, :role)})

    assert roles == %{"%1" => "operator", "%2" => "agent", "%3" => "verify"}
  end

  defp temp_workspace_root! do
    root =
      Path.join(System.tmp_dir!(), "casein-template-root-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp put_or_delete_env(key, value), do: TmuxCtl.Test.FakeState.restore(key, value)
end
