defmodule DevIDE.Terminals.TemplatesTest do
  use DevIde.DataCase, async: false

  alias DevIDE.Terminals.Templates

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

  test "saves and lists exported templates by workspace" do
    body = %{
      "version" => 2,
      "name" => "saved_layout",
      "windows" => [
        %{"name" => "server", "layout" => %{"name" => "mix"}},
        %{"name" => "tests", "layout" => %{"direction" => "tiled", "panes" => []}}
      ]
    }

    assert {:ok, saved} =
             Templates.save(%{
               workspace_id: "ws-1",
               name: "saved_layout",
               description: "A saved export",
               body: body,
               source_session: "devide_ws",
               schema_version: 2
             })

    assert saved.id
    assert saved.workspace_id == "ws-1"
    assert saved.name == "saved_layout"
    assert saved.description == "A saved export"
    assert saved.body == body
    assert saved.source_session == "devide_ws"
    assert saved.schema_version == 2
    assert %DateTime{} = saved.inserted_at

    assert [listed] = Templates.list_for_workspace("ws-1")
    assert listed.id == saved.id
    assert Templates.list_for_workspace("ws-2") == []

    assert {:ok, fetched} = Templates.get("ws-1", saved.id)
    assert fetched.id == saved.id
    assert {:error, :not_found} = Templates.get("ws-2", saved.id)
  end

  test "validates required saved template fields" do
    assert {:error, changeset} = Templates.save(%{workspace_id: "ws-1", body: %{}})
    assert %{name: ["can't be blank"]} = errors_on(changeset)
  end

  test "dry-run plans saved v2 exports" do
    root = temp_workspace_root!()
    {:ok, saved} = save_saved_template()

    assert {:ok, result} = Templates.dry_run("ws-1", saved.id, workspace_root: root)

    assert result.dry_run == true
    assert result.template.id == saved.id
    assert result.template.source == "exported"
    assert result.template.schema_version == 2
    assert result.step_count == length(result.steps)
    assert Enum.map(result.steps, & &1.index) == Enum.to_list(1..result.step_count)

    assert Enum.any?(result.steps, fn step ->
             step.action == "new_window" and step.ref == "window:server" and
               step.params == %{name: "server", cwd: "${workspace_root}"}
           end)

    assert Enum.any?(result.steps, fn step ->
             step.action == "split_pane" and step.ref == "pane:server:console" and
               step.target_ref == "pane:server:root" and step.params.direction == "h"
           end)

    assert Enum.any?(result.steps, fn step ->
             step.action == "send_command" and step.target_ref == "pane:server:logs" and
               step.params.command == "tail -f log/dev.log"
           end)

    assert List.last(result.steps).action == "select_pane"
    assert List.last(result.steps).target_ref == "pane:server:console"
  end

  test "executes saved v2 exports against tmux" do
    root = temp_workspace_root!()
    web_root = Path.join(root, "apps/web")
    File.mkdir_p!(web_root)

    {:ok, saved} = save_saved_template()
    Application.put_env(:dev_ide, :fake_tmux_next_window, %{"template-session" => "@9"})

    assert {:ok, result} =
             Templates.execute("ws-1", "template-session", saved.id,
               tmux: DevIDE.Test.FakeTmuxAdapter,
               workspace_root: root
             )

    assert result.template.id == saved.id
    assert result.template.source == "exported"
    assert result.step_count == 7
    assert result.refs["window:server"] == "@9"
    assert result.refs["pane:server:root"] == "%1"
    assert result.refs["pane:server:console"] == "%2"
    assert result.refs["pane:server:logs"] == "%3"

    assert Enum.map(result.executed_steps, & &1.action) == [
             "new_window",
             "send_command",
             "split_pane",
             "send_command",
             "split_pane",
             "send_command",
             "select_pane"
           ]

    assert_receive {:fake_tmux_new_window, "template-session", new_window_opts}
    assert new_window_opts[:name] == "server"
    assert new_window_opts[:cwd] == root

    assert_receive {:fake_tmux_send_command, "template-session", "%1", "mix phx.server", _}
    assert_receive {:fake_tmux_split_pane, "template-session", "%1", "h", "%2"}
    assert_receive {:fake_tmux_send_command, "template-session", "%2", "iex -S mix", _}
    assert_receive {:fake_tmux_split_pane, "template-session", "%2", "v", "%3"}
    assert_receive {:fake_tmux_send_command, "template-session", "%3", "tail -f log/dev.log", _}
    assert_receive {:fake_tmux_select_pane, "template-session", "%2"}

    assert [
             %{id: "%1", active: false, current_path: ^root},
             %{id: "%2", active: true, current_path: ^web_root},
             %{id: "%3", active: false, current_path: ^web_root}
           ] =
             :dev_ide
             |> Application.get_env(:fake_tmux_panes)
             |> Map.fetch!("template-session")
             |> Enum.sort_by(& &1.id)
  end

  defp save_saved_template(attrs \\ %{}) do
    Templates.save(
      Map.merge(
        %{
          workspace_id: "ws-1",
          name: "saved_layout",
          description: "A saved export",
          body: saved_template_body(),
          source_session: "devide_ws",
          schema_version: 2
        },
        attrs
      )
    )
  end

  defp saved_template_body do
    %{
      "version" => 2,
      "name" => "saved_layout",
      "root" => "${workspace_root}",
      "windows" => [
        %{
          "name" => "server",
          "root" => "${workspace_root}",
          "focus" => true,
          "layout" => %{
            "direction" => "horizontal",
            "panes" => [
              %{
                "name" => "app",
                "command" => "mix phx.server",
                "focus" => true
              },
              %{
                "direction" => "vertical",
                "panes" => [
                  %{
                    "name" => "console",
                    "cwd" => "${workspace_root}/apps/web",
                    "command" => "iex -S mix"
                  },
                  %{
                    "name" => "logs",
                    "cwd" => "${workspace_root}/apps/web",
                    "command" => "tail -f log/dev.log"
                  }
                ]
              }
            ]
          }
        }
      ],
      "startup" => %{"window" => "server", "pane" => "console"}
    }
  end

  defp temp_workspace_root! do
    root =
      Path.join(
        System.tmp_dir!(),
        "devide-saved-template-root-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp put_or_delete_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp put_or_delete_env(key, value), do: Application.put_env(:dev_ide, key, value)
end
