defmodule CaseinPreviewBrowser.HealthTest do
  use ExUnit.Case, async: true

  alias CaseinPreviewBrowser.Health

  test "normalizes wire snapshots" do
    assert %Health{
             state: :liveview_stable,
             bridge_ready: true,
             dom_loaded: true,
             live_socket_connected: true,
             last_event_type: "devide:preview:live_socket_connected",
             last_event_at: 123,
             client_errors: []
           } =
             Health.from_map(%{
               "state" => "liveview_stable",
               "bridge_ready" => true,
               "dom_loaded" => true,
               "live_socket_connected" => true,
               "last_event_type" => "devide:preview:live_socket_connected",
               "last_event_at" => 123
             })
  end

  test "transitions through LiveView-aware states" do
    health =
      Health.new()
      |> Health.transition({:preview_signal, "devide:preview:bridge_ready", %{"timestamp" => 1}})
      |> Health.transition({:preview_signal, "devide:preview:dom_loaded", %{"timestamp" => 2}})

    assert health.state == :dom_loaded
    assert health.bridge_ready
    assert health.dom_loaded

    health =
      Health.transition(
        health,
        {:preview_signal, "devide:preview:live_socket_connected", %{"timestamp" => 3}}
      )

    assert health.state == :liveview_stable
    assert health.live_socket_connected
  end

  test "client errors and disconnects degrade health" do
    health =
      Health.new()
      |> Health.transition(
        {:preview_signal, "devide:preview:client_error", %{"message" => "boom"}}
      )

    assert health.state == :degraded
    assert [%{"message" => "boom"}] = health.client_errors

    health =
      Health.transition(
        Health.new(),
        {:preview_signal, "devide:preview:live_socket_disconnected", %{}}
      )

    assert health.state == :degraded
    assert health.live_socket_connected == false
  end
end
