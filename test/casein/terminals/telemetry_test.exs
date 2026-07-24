defmodule Casein.Terminals.TelemetryTest do
  use Casein.TestCase, async: false

  alias Casein.Terminals
  alias Casein.Terminals.Telemetry

  test "owner count increases while owner is attached and drops on stop" do
    unique = "telemetry-count-#{System.unique_integer([:positive])}"

    info = Terminals.new_agent("agent-#{unique}", workspace_id: "ws-telemetry-count")

    baseline = Telemetry.count_active_owners()

    {:ok, owner_pid, _} =
      Terminals.owner_attach(
        "ws-telemetry-count",
        info,
        mode: :raw,
        session_id: unique
      )

    monitor = Process.monitor(owner_pid)

    assert Telemetry.count_active_owners() > baseline
    assert :ok = Terminals.owner_detach(owner_pid, self())

    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 1_000
    assert Telemetry.count_active_owners() >= baseline
  end

  test "subscribers_per_owner reflects attachment fanout count changes" do
    unique = "telemetry-subscribers-#{System.unique_integer([:positive])}"
    agent_id = "agent-#{unique}"
    info = Terminals.new_agent(agent_id, workspace_id: "ws-telemetry-subscribers")
    expected_key = {:terminal_owner, :agent, info.id}

    parent = self()

    {:ok, owner_pid, _} =
      Terminals.owner_attach(
        "ws-telemetry-subscribers",
        info,
        mode: :raw,
        session_id: unique
      )

    assert count_for(subscribers_for_key(Telemetry.subscribers_per_owner(), expected_key)) == 1

    secondary =
      spawn(fn ->
        {:ok, _secondary_owner_pid, _} =
          Terminals.owner_attach(
            "ws-telemetry-subscribers",
            info,
            mode: :raw,
            session_id: unique
          )

        send(parent, :secondary_attached)

        receive do
          :release ->
            Terminals.owner_detach(owner_pid, self())
            send(parent, :secondary_released)
        end
      end)

    assert_receive :secondary_attached, 1_000
    assert count_for(subscribers_for_key(Telemetry.subscribers_per_owner(), expected_key)) == 2

    send(secondary, :release)
    assert_receive :secondary_released, 1_000
    assert count_for(subscribers_for_key(Telemetry.subscribers_per_owner(), expected_key)) == 1

    monitor = Process.monitor(owner_pid)
    assert :ok = Terminals.owner_detach(owner_pid, self())
    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 1_000
    assert subscribers_for_key(Telemetry.subscribers_per_owner(), expected_key) == nil
  end

  test "open attachment count does not go below zero on repeated close" do
    previous = Telemetry.count_open_attachments()
    :ets.insert(:casein_terminal_metrics, {:open_attachments, 0})

    on_exit(fn ->
      Telemetry.ensure_table!()
      :ets.insert(:casein_terminal_metrics, {:open_attachments, previous})
    end)

    Telemetry.owner_attachment_closed()
    assert Telemetry.count_open_attachments() == 0

    Telemetry.owner_attachment_closed()
    assert Telemetry.count_open_attachments() == 0
  end

  defp subscribers_for_key(list, key) do
    Enum.find_value(list, fn
      {^key, count} -> count
      _ -> nil
    end)
  end

  defp count_for(nil), do: 0
  defp count_for(value), do: value
end
