defmodule Casein.Terminals.TemplatesReconcileExecutorTest do
  use Casein.TestCase, async: false

  alias Casein.Terminals.Templates.ReconcileExecutor
  alias Casein.Terminals.Templates.Reconciler

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

  test "executes additive reconcile diff by reusing matched panes" do
    root = "/workspace"
    web_root = Path.join(root, "apps/web")
    seed_fake_topology("api-session", root, web_root)

    assert {:ok, diff} =
             Reconciler.diff(topology(root, web_root), saved_template(), workspace_root: root)

    assert {:ok, result} =
             ReconcileExecutor.execute("api-session", diff,
               tmux: Casein.Test.FakeTmuxAdapter,
               workspace_root: root
             )

    assert result.strategy == "reconcile"
    assert result.step_count == length(diff.changes)
    assert result.reconciliation == diff.summary
    assert result.refs["window:server"] == "@1"
    assert result.refs["pane:server:root"] == "%1"
    assert result.refs["pane:server:console"] == "%2"
    assert result.refs["pane:server:logs"] == "%3"

    refute_received {:fake_tmux_new_window, "api-session", _opts}
    assert_receive {:fake_tmux_split_pane, "api-session", "%2", "v", "%3"}
    assert_receive {:fake_tmux_send_command, "api-session", "%3", "tail -f log/dev.log", _}
    assert_receive {:fake_tmux_select_pane, "api-session", "%2"}
  end

  test "creates missing windows and resolves downstream pane refs" do
    root = temp_workspace_root!()
    web_root = Path.join(root, "apps/web")
    File.mkdir_p!(web_root)
    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{"api-session" => []})
    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{"api-session" => []})
    TmuxCtl.Test.FakeState.put(:fake_tmux_next_window, %{"api-session" => "@9"})

    empty_topology = %{
      topology(root, web_root)
      | windows: [],
        panes: [],
        active_window_id: nil,
        active_pane_id: nil
    }

    assert {:ok, diff} =
             Reconciler.diff(empty_topology, saved_template(), workspace_root: root)

    assert {:ok, result} =
             ReconcileExecutor.execute("api-session", diff,
               tmux: Casein.Test.FakeTmuxAdapter,
               workspace_root: root
             )

    assert result.refs["window:server"] == "@9"
    assert result.refs["pane:server:root"] == "%1"
    assert result.refs["pane:server:console"] == "%2"
    assert result.refs["pane:server:logs"] == "%3"

    assert_receive {:fake_tmux_new_window, "api-session", new_window_opts}
    assert new_window_opts[:name] == "server"
    assert new_window_opts[:cwd] == root

    assert_receive {:fake_tmux_send_command, "api-session", "%1", "mix phx.server", _}
    assert_receive {:fake_tmux_split_pane, "api-session", "%1", "h", "%2"}
    assert_receive {:fake_tmux_send_command, "api-session", "%2", "iex -S mix", _}
    assert_receive {:fake_tmux_split_pane, "api-session", "%2", "v", "%3"}
    assert_receive {:fake_tmux_send_command, "api-session", "%3", "tail -f log/dev.log", _}
    assert_receive {:fake_tmux_select_pane, "api-session", "%2"}
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

  defp seed_fake_topology(session, root, web_root) do
    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [
        %{
          id: "@1",
          index: 0,
          name: "server",
          active: true,
          panes: 2,
          activity: 0,
          current_command: "mix"
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      session => [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: false,
          left: 0,
          top: 0,
          width: 80,
          height: 40,
          current_command: "mix",
          current_path: root
        },
        %{
          id: "%2",
          window_id: "@1",
          index: 1,
          active: true,
          left: 80,
          top: 0,
          width: 80,
          height: 40,
          current_command: "iex",
          current_path: web_root
        }
      ]
    })
  end

  defp temp_workspace_root! do
    root =
      Path.join(
        System.tmp_dir!(),
        "devide-reconcile-template-root-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp put_or_delete_env(key, value), do: TmuxCtl.Test.FakeState.restore(key, value)
end
