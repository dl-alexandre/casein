defmodule Casein.Signals.PublishDomainTest do
  use ExUnit.Case, async: false

  alias Casein.Runtimes
  alias Casein.SignalBus
  alias Casein.Signals
  alias Casein.Signals.Publish
  alias Casein.Test.RuntimeSeed
  alias Jido.Signal.Bus

  test "from_domain_event builds a devide.* CloudEvents envelope" do
    signal =
      Signals.from_domain_event(
        "deploy.failed",
        %{phase: "gate", reason: "pre-push gate failed"},
        workspace_id: "ws-1"
      )

    assert signal.type == "devide.deploy.failed"
    assert signal.source == "/devide/domain/ws-1"
    assert signal.data.event == "deploy.failed"
    assert signal.data.workspace_id == "ws-1"
    assert signal.data.phase == "gate"
  end

  test "domain_event publishes to the signal bus" do
    {:ok, sub_id} =
      Bus.subscribe(SignalBus.name(), Publish.domain_subscription_pattern(),
        dispatch: {:pid, target: self()}
      )

    on_exit(fn -> Bus.unsubscribe(SignalBus.name(), sub_id) end)

    assert :ok =
             Publish.domain_event(
               "runtime.preview_failed",
               %{runtime_id: "rt-1", failure_reason: "port closed"},
               workspace_id: "ws-1",
               subject: "rt-1"
             )

    assert_receive {:signal, signal}
    assert signal.type == "devide.runtime.preview_failed"
    assert signal.subject == "rt-1"
    assert signal.data.runtime_id == "rt-1"
  end

  test "mark_preview_server failed also publishes a runtime domain signal" do
    prev = Application.get_env(:casein, :runtimes_adapter)
    Application.put_env(:casein, :runtimes_adapter, Casein.Runtimes.MemoryAdapter)
    on_exit(fn -> restore_adapter(prev) end)
    Runtimes.clear()

    {:ok, sub_id} =
      Bus.subscribe(SignalBus.name(), Publish.domain_subscription_pattern(),
        dispatch: {:pid, target: self()}
      )

    on_exit(fn -> Bus.unsubscribe(SignalBus.name(), sub_id) end)

    {:ok, runtime} =
      RuntimeSeed.seed_runtime("ws-preview-fail",
        metadata: %{
          "preview_server" => %{
            "id" => "ps-1",
            "runtime_id" => "rt-preview-fail",
            "status" => "starting",
            "port" => 41_001,
            "cwd" => "/tmp",
            "command" => ["echo", "ok"],
            "env" => %{"PORT" => "41001"},
            "url" => "http://127.0.0.1:41001"
          }
        }
      )

    assert {:ok, _updated} = Runtimes.mark_preview_server(runtime, "failed", "port closed")

    assert_receive {:signal,
                    %{type: "devide.runtime.preview_failed", subject: subject, data: data}}

    assert subject == runtime.id
    assert data.failure_reason == "port closed"
    assert data.workspace_id == "ws-preview-fail"
  end

  defp restore_adapter(nil), do: Application.delete_env(:casein, :runtimes_adapter)
  defp restore_adapter(value), do: Application.put_env(:casein, :runtimes_adapter, value)
end
