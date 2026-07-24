defmodule Casein.Terminals.TemplatesReconcilerTest do
  use Casein.TestCase, async: true

  alias Casein.Terminals.Templates.Reconciler

  test "diff reuses matching windows and panes while planning missing splits" do
    root = "/workspace"
    web_root = Path.join(root, "apps/web")

    assert {:ok, diff} =
             Reconciler.diff(topology(root, web_root), saved_template(), workspace_root: root)

    assert diff.strategy == "reconcile"
    assert diff.session == "api-session"
    assert diff.template.source == "exported"
    assert diff.summary.reuse_windows == 1
    assert diff.summary.create_windows == 0
    assert diff.summary.reuse_panes == 2
    assert diff.summary.new_panes == 1
    assert diff.summary.send_commands == 1
    assert diff.summary.select_panes == 1
    assert diff.estimated_disruption == "medium"

    assert Enum.any?(diff.changes, fn change ->
             change.action == "reuse_window" and change.target_id == "@1" and
               change.reason == "name_match"
           end)

    assert Enum.any?(diff.changes, fn change ->
             change.action == "reuse_pane" and change.target_id == "%1" and
               change.template_ref.ref == "pane:server:root" and
               change.reason == "signature_match"
           end)

    assert Enum.any?(diff.changes, fn change ->
             change.action == "reuse_pane" and change.target_id == "%2" and
               change.template_ref.ref == "pane:server:console"
           end)

    assert Enum.any?(diff.changes, fn change ->
             change.action == "split_pane" and change.template_ref.ref == "pane:server:logs" and
               change.target_id == "%2"
           end)

    assert List.last(diff.changes).action == "select_pane"
    assert List.last(diff.changes).target_id == "%2"
  end

  test "diff falls back to create when the template window is missing" do
    root = "/workspace"
    topology = %{topology(root, Path.join(root, "apps/web")) | windows: [], panes: []}

    assert {:ok, diff} =
             Reconciler.diff(topology, saved_template(), workspace_root: root)

    assert diff.summary.reuse_windows == 0
    assert diff.summary.create_windows == 1
    assert diff.summary.reuse_panes == 0
    assert diff.summary.new_panes == 2
    assert diff.estimated_disruption == "medium"

    assert Enum.any?(diff.changes, &(&1.action == "create_window"))
    assert Enum.count(diff.changes, &(&1.action == "split_pane")) == 2
    assert Enum.count(diff.changes, &(&1.action == "send_command")) == 3
  end

  defp saved_template do
    %{
      id: "tpl-1",
      name: "saved_layout",
      description: "Saved v2 layout",
      source_session: "original-session",
      schema_version: 2,
      body: %{
        "version" => 2,
        "name" => "saved_layout",
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
      },
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
  end

  defp topology(root, web_root) do
    %{
      session: "api-session",
      version: 123,
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
              window_id: "@1",
              index: 0,
              active: false,
              current_command: "mix",
              current_path: root
            },
            %{
              id: "%2",
              window_id: "@1",
              index: 1,
              active: true,
              current_command: "iex",
              current_path: web_root
            }
          ]
        }
      ],
      panes: []
    }
  end
end
