defmodule DevIDE.Agents.ToolActionTest do
  use ExUnit.Case, async: true

  alias DevIDE.Agents.ToolAction
  alias DevIDE.Test.ToolActionFixtures.{AliasedAction, FastAction, SlowAction}

  setup do
    handler = fn _event, measurements, metadata, _config ->
      events = Process.get(:tool_action_events, [])
      Process.put(:tool_action_events, [{measurements, metadata} | events])
    end

    :ok = :telemetry.attach("tool-action-test", [:dev_ide, :agents, :tool, :stop], handler, nil)
    on_exit(fn -> :telemetry.detach("tool-action-test") end)
    Process.delete(:tool_action_events)
    :ok
  end

  test "invoke runs the action and emits stop telemetry" do
    assert {:ok, %{value: 42}} =
             ToolAction.invoke(FastAction, %{"value" => 42})

    assert [{%{duration: duration}, %{tool: "fast_action", timed_out: false}}] =
             Process.get(:tool_action_events)

    assert is_integer(duration) and duration >= 0
  end

  test "invoke returns timeout error without retrying" do
    assert {:error, %{error: :timeout, message: message}} =
             ToolAction.invoke(SlowAction, %{})

    assert message =~ "timed out after 50ms"

    assert [{_measurements, %{tool: "slow_action", timed_out: true}}] =
             Process.get(:tool_action_events)
  end

  test "an explicit null does not stop the alias chain" do
    # Clients that serialize every schema field send nulls for the unused
    # aliases — {"target_id": null, "id": "abc"} must still resolve "abc".
    assert {:ok, %{target_id: "abc"}} =
             ToolAction.invoke(AliasedAction, %{"target_id" => nil, "id" => "abc"})
  end

  test "all-null aliases count as a missing argument" do
    assert {:error, {:missing_argument, "target_id"}} =
             ToolAction.invoke(AliasedAction, %{"target_id" => nil, "id" => nil})
  end

  test "validation path is unchanged and does not emit tool stop telemetry" do
    assert {:error, {:missing_argument, "value"}} =
             ToolAction.invoke(FastAction, %{})

    assert Process.get(:tool_action_events) == nil
  end
end
