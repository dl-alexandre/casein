defmodule DevIDE.Previews.WorkspaceContextTest do
  use ExUnit.Case, async: true

  alias DevIDE.Previews.WorkspaceContext

  @workspace %{
    id: "ws-ctx",
    name: "demo-ws",
    metadata: %{
      type: :v3,
      domain_base: "demo.devbox.example.com",
      ports: %{"app" => 10_100}
    }
  }

  test "prepare attaches terminal output and detected ports from metadata" do
    output = "Serving HTTP on http://127.0.0.1:8765"

    ws =
      @workspace
      |> Map.update!(:metadata, &Map.put(&1, :terminal_output, output))
      |> WorkspaceContext.prepare()

    assert ws.metadata["terminal_output"] == output
    assert 8765 in ws.metadata["detected_ports"]
  end

  test "port_allowed? accepts metadata, common dev, and detected ports" do
    ws =
      WorkspaceContext.prepare(%{
        @workspace
        | metadata:
            Map.merge(@workspace.metadata, %{
              terminal_output: "http://localhost:8765",
              detected_ports: [8765]
            })
      })

    assert WorkspaceContext.port_allowed?(ws, 10_100)
    assert WorkspaceContext.port_allowed?(ws, 5173)
    assert WorkspaceContext.port_allowed?(ws, 8765)
    refute WorkspaceContext.port_allowed?(ws, 9999)
    assert 8765 in WorkspaceContext.allowed_ports(ws)
  end

  test "localhost_url normalizes paths" do
    assert WorkspaceContext.localhost_url(5173) == "http://localhost:5173/"

    assert WorkspaceContext.localhost_url(5173, "index.html") ==
             "http://localhost:5173/index.html"

    assert WorkspaceContext.localhost_url(5173, "/docs/") == "http://localhost:5173/docs/"
  end

  test "prepare is idempotent once terminal_output, detected_ports, and tidewave fingerprint are present" do
    prepared =
      @workspace
      |> Map.update!(:metadata, fn m ->
        m
        |> Map.put("terminal_output", "http://localhost:7000")
        |> Map.put("detected_ports", [7000])
        |> Map.put("tidewave_ports", [])
        |> Map.put("tidewave_probed_ports", [7000])
      end)

    assert WorkspaceContext.prepare(prepared) == prepared
  end

  test "prepare refreshes tidewave_ports when detected_ports change" do
    prepared =
      @workspace
      |> Map.update!(:metadata, fn m ->
        m
        |> Map.put("terminal_output", "http://localhost:7000")
        |> Map.put("detected_ports", [7000, 8765])
        |> Map.put("tidewave_ports", [%{"port" => 7000}])
        |> Map.put("tidewave_probed_ports", [7000])
      end)

    refreshed = WorkspaceContext.prepare(prepared)
    assert refreshed.metadata["tidewave_probed_ports"] == [7000, 8765]
  end
end
