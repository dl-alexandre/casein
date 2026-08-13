defmodule CaseinWeb.WorkspaceLive.Show.AfterMountTest do
  use Casein.TestCase, async: true

  alias CaseinWeb.WorkspaceLive.Show
  alias CaseinWeb.WorkspaceLive.Show.AfterMount
  alias CaseinWeb.WorkspaceLive.Show.CodexEvents

  # Behaviour-preserving extract of Show's three :after_mount_* handle_info
  # clauses. `:after_mount` itself stays on Show. Do not expand this module
  # into handle_async hydration or change-tracking "fixes".

  defp socket(assigns \\ %{}) do
    ws_id = "ws-after-mount-#{System.unique_integer([:positive])}"

    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            flash: %{},
            workspace: %{id: ws_id},
            host_path: {:error, :not_set},
            current_user: %{id: "u-#{System.unique_integer([:positive])}"},
            tab: "terminal",
            tree: %{}
          },
          assigns
        )
    }
  end

  test "Show.handle_info still dispatches the three :after_mount_* messages" do
    s = socket()
    assert {:noreply, ^s} = Show.handle_info(:after_mount_side_panels, s)
    assert {:noreply, ^s} = Show.handle_info(:after_mount_runs, s)
    assert {:noreply, ^s} = Show.handle_info(:after_mount_agents, s)
  end

  test "disconnected :after_mount_side_panels / :after_mount_runs do not enqueue the next step" do
    s = socket()
    assert {:noreply, ^s} = AfterMount.handle_info(:after_mount_side_panels, s)
    refute_receive :after_mount_runs, 20

    assert {:noreply, ^s} = AfterMount.handle_info(:after_mount_runs, s)
    refute_receive :after_mount_agents, 20
  end

  test "disconnected :after_mount_agents is a no-op (Codex stays unloaded)" do
    s = CodexEvents.assign_defaults(socket())
    assert {:noreply, s2} = AfterMount.handle_info(:after_mount_agents, s)
    assert s2.assigns.codex_loaded? == false
    assert s2.assigns.codex_subscribed? == false
  end
end
