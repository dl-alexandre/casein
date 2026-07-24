defmodule Casein.Signals.AlertsRouterTest do
  use Casein.DataCase, async: false

  alias Casein.Audit.Event
  alias Casein.SignalBus
  alias Casein.Signals
  alias Casein.Signals.AlertsRouter
  alias Jido.Signal.Bus

  setup do
    prev = Application.get_env(:dev_ide, :push_test_pid)
    Application.put_env(:dev_ide, :push_provider, Casein.Push.TestProvider)
    Application.put_env(:dev_ide, :push_test_pid, self())
    Casein.Push.Registry.clear()

    on_exit(fn ->
      Casein.Push.Registry.clear()
      Application.delete_env(:dev_ide, :push_test_pid)

      if prev,
        do: Application.put_env(:dev_ide, :push_test_pid, prev),
        else: Application.delete_env(:dev_ide, :push_test_pid)
    end)

    :ok
  end

  test "routes alert-worthy bus signals to push for watched workspaces" do
    :ok =
      Casein.Push.register(%{
        workspace_id: "ws-signal",
        token: "tok-signal",
        platform: "ios"
      })

    signal =
      Event.new(%{
        workspace_id: "ws-signal",
        action: "agent.blocked",
        reason: :needs_permission
      })
      |> Signals.from_audit_event()

    assert {:ok, _} = Bus.publish(SignalBus.name(), [signal])

    assert_receive {:pushed, "tok-signal", "ios", notification}, 2_000
    assert notification.workspace_id == "ws-signal"
    assert notification.title == "Agent blocked"
  end

  test "ignores alert signals for unwatched workspaces" do
    signal =
      Event.new(%{workspace_id: "ws-other", action: "policy.blocked", decision: :deny})
      |> Signals.from_audit_event()

    :ok = AlertsRouter.watch("ws-watched-only")
    assert {:ok, _} = Bus.publish(SignalBus.name(), [signal])
    refute_receive {:pushed, _, _, _}, 300
  end
end
