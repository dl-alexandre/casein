defmodule CaseinPreviewBrowser.ExternalBackend.ProtocolTest do
  use ExUnit.Case, async: true

  alias CaseinPreviewBrowser.Health
  alias CaseinPreviewBrowser.ExternalBackend.Protocol

  test "encodes requests for the sidecar" do
    assert {:ok, encoded} =
             Protocol.encode_request("1", "navigate", %{
               "browser_ref" => "browser-1",
               "url" => "http://example.test"
             })

    assert {:ok, decoded} = Jason.decode(encoded)

    assert decoded == %{
             "id" => "1",
             "command" => "navigate",
             "payload" => %{
               "browser_ref" => "browser-1",
               "url" => "http://example.test"
             }
           }
  end

  test "decodes successful responses" do
    line = ~s({"id":"1","ok":true,"result":{"url":"http://example.test","status":200}})

    assert {:ok, {:response, "1", {:ok, %{"url" => "http://example.test", "status" => 200}}}} =
             Protocol.decode_line(line)
  end

  test "decodes error responses" do
    assert {:ok, {:response, "2", {:error, "navigation_failed"}}} =
             Protocol.decode_line(~s({"id":"2","ok":false,"error":"navigation_failed"}))
  end

  test "decodes browser events" do
    assert {:ok, {:event, "browser-1", {:console, :info, "ready"}}} =
             Protocol.decode_line(
               ~s({"type":"event","browser_id":"browser-1","event":["console","info","ready"]})
             )

    assert {:ok, {:event, "browser-1", {:console, :log, "ready"}}} =
             Protocol.decode_line(
               ~s({"type":"event","browser_id":"browser-1","event":["console","log","ready"]})
             )

    assert {:ok, {:event, "browser-1", {:load_finished, "http://example.test", 200}}} =
             Protocol.decode_line(
               ~s({"type":"event","browser_id":"browser-1","event":["load_finished","http://example.test",200]})
             )
  end

  test "decodes preview bridge signal events with health snapshots" do
    line =
      Jason.encode!(%{
        "type" => "event",
        "browser_id" => "browser-1",
        "event" => [
          "preview_signal",
          "casein:preview:live_socket_connected",
          %{"request_id" => "pv-test", "timestamp" => 123},
          %{
            "state" => "liveview_stable",
            "bridge_ready" => true,
            "dom_loaded" => true,
            "live_socket_connected" => true,
            "last_event_type" => "casein:preview:live_socket_connected",
            "last_event_at" => 123,
            "client_errors" => []
          }
        ]
      })

    assert {:ok,
            {:event, "browser-1",
             {:preview_signal, "casein:preview:live_socket_connected",
              %{"request_id" => "pv-test", "timestamp" => 123},
              %Health{state: :liveview_stable, live_socket_connected: true}}}} =
             Protocol.decode_line(line)
  end

  test "decodes standalone health events" do
    line =
      ~s({"type":"event","browser_id":"browser-1","event":["health",{"state":"navigation_started","last_event_type":"casein:preview:page_loading_start"}]})

    assert {:ok,
            {:event, "browser-1",
             {:health,
              %Health{
                state: :navigation_started,
                last_event_type: "casein:preview:page_loading_start"
              }}}} =
             Protocol.decode_line(line)
  end

  test "ignores unknown but valid messages" do
    assert {:ok, :ignore} = Protocol.decode_line(~s({"hello":"world"}))
  end

  test "reports invalid JSON without raising" do
    assert {:error, {:decode_failed, %Jason.DecodeError{}}} = Protocol.decode_line("{")
  end
end
