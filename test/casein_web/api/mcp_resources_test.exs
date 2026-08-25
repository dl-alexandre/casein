defmodule CaseinWeb.API.MCPResourcesTest do
  @moduledoc """
  The `resources/*` surface and the MCP Apps declaration built on it.

  Casein serves resources for the artifact viewer (MCP App) and the terminal
  fleet summary (`casein://fleet/summary`) and host health (`casein://host/health`).
  """

  use ExUnit.Case, async: false

  alias Casein.Terminals.FleetSnapshot
  alias CaseinWeb.API.{ArtifactMCP, MCPEnvelope, TerminalMCP}

  @ui_uri "ui://casein-artifact/artifact-app.html"
  @ui_mime "text/html;profile=mcp-app"
  @ui_ext "io.modelcontextprotocol/ui"

  defp modern(method, params \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "id" => "res-1",
      "method" => method,
      "params" =>
        Map.put(params, "_meta", %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28"
        })
    }
  end

  describe "artifact server" do
    test "resources/list publishes the app with cache hints" do
      assert {:reply, %{result: result}} =
               MCPEnvelope.handle(modern("resources/list"), ArtifactMCP, [])

      assert [resource] = result.resources
      assert resource.uri == @ui_uri
      assert resource.mimeType == @ui_mime
      assert result.ttlMs > 0
      assert result.cacheScope == "public"
    end

    test "resources/read returns the app HTML" do
      assert {:reply, %{result: result}} =
               MCPEnvelope.handle(modern("resources/read", %{"uri" => @ui_uri}), ArtifactMCP, [])

      assert [%{uri: @ui_uri, mimeType: @ui_mime, text: html}] = result.contents

      # It must be a self-contained app that speaks the ui/ postMessage dialect.
      assert html =~ "<!doctype html>"
      assert html =~ "ui/initialize"
      assert html =~ "ui/notifications/tool-result"
    end

    test "an unknown resource uri is Invalid Params, not the retired -32002" do
      assert {:reply, %{error: error}} =
               MCPEnvelope.handle(
                 modern("resources/read", %{"uri" => "ui://nope/missing.html"}),
                 ArtifactMCP,
                 []
               )

      assert error.code == -32_602
      assert error.data.code == "resource_not_found"
    end

    test "resources/read requires a uri" do
      assert {:reply, %{error: %{code: -32_602}}} =
               MCPEnvelope.handle(modern("resources/read"), ArtifactMCP, [])
    end

    test "artifact tools about a single artifact carry the UI template" do
      specs = ArtifactMCP.tool_specs()
      by_name = Map.new(specs, &{&1.name, &1})

      for name <-
            ~w(artifact_create artifact_update artifact_get artifact_serve artifact_snapshot) do
        assert get_in(by_name, [name, Access.key(:_meta), :ui, :resourceUri]) == @ui_uri,
               "#{name} should declare the artifact viewer"
      end

      # A list of artifacts and a retirement have nothing for the viewer to show.
      for name <- ~w(artifact_list artifact_retire) do
        refute Map.has_key?(by_name[name], :_meta), "#{name} should not declare a UI"
      end
    end

    test "server/discover declares the ui extension" do
      assert {:reply, %{result: result}} =
               MCPEnvelope.handle(modern("server/discover"), ArtifactMCP, [])

      assert Map.has_key?(result.capabilities.extensions, @ui_ext)
      assert is_map(result.capabilities.resources)
    end
  end

  describe "terminal fleet summary resource" do
    test "resources/list publishes casein://fleet/summary" do
      assert {:reply, %{result: result}} =
               MCPEnvelope.handle(modern("resources/list"), TerminalMCP, [])

      assert Enum.any?(result.resources, fn r ->
               r.uri == "casein://fleet/summary" and r.mimeType == "application/json"
             end)

      assert {:reply, %{result: %{resourceTemplates: []}}} =
               MCPEnvelope.handle(modern("resources/templates/list"), TerminalMCP, [])
    end

    test "resources/read returns JSON fleet summary text" do
      FleetSnapshot.ensure_table!()
      FleetSnapshot.delete()

      FleetSnapshot.put(%{
        generated_at: "2026-08-24T16:00:00Z",
        incomplete: false,
        incomplete_reason: nil,
        boards: %{},
        needs_you: %{},
        totals: %{},
        summary: %{
          uri: "casein://fleet/summary",
          workspace_id: "ws-scoped",
          generated_at: "2026-08-24T16:00:00Z",
          incomplete: false,
          incomplete_reason: nil,
          session_count: 0,
          pane_count: 0,
          sessions: [],
          note: "Read-only fleet summary from FleetSnapshot."
        }
      })

      on_exit(fn -> FleetSnapshot.delete() end)

      assert {:reply, %{result: result}} =
               MCPEnvelope.handle(
                 modern("resources/read", %{"uri" => "casein://fleet/summary"}),
                 TerminalMCP,
                 default_workspace_id: "ws-scoped"
               )

      assert [%{uri: "casein://fleet/summary", mimeType: "application/json", text: text}] =
               result.contents

      decoded = Jason.decode!(text)
      assert decoded["uri"] == "casein://fleet/summary"
      assert decoded["workspace_id"] == "ws-scoped"
      assert decoded["sessions"] == []
      assert decoded["generated_at"] == "2026-08-24T16:00:00Z"
      assert decoded["incomplete"] == false
      assert decoded["note"] =~ "FleetSnapshot"
    end

    test "resources/list publishes casein://host/health" do
      assert {:reply, %{result: result}} =
               MCPEnvelope.handle(modern("resources/list"), TerminalMCP, [])

      assert Enum.any?(result.resources, fn r ->
               r.uri == "casein://host/health" and r.mimeType == "application/json"
             end)
    end

    test "resources/read returns the same host-health snapshot as the tool" do
      previous = Application.get_env(:casein, :host_health)

      status_path =
        Path.join(
          System.tmp_dir!(),
          "casein-host-health-#{System.unique_integer([:positive])}.json"
        )

      sampled_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      Application.put_env(:casein, :host_health,
        status_path: status_path,
        alerts_path: status_path <> ".alerts",
        host: "milc-devbox",
        stale_after_seconds: 720,
        max_alerts: 5
      )

      on_exit(fn ->
        File.rm(status_path)

        if previous,
          do: Application.put_env(:casein, :host_health, previous),
          else: Application.delete_env(:casein, :host_health)
      end)

      File.write!(
        status_path,
        Jason.encode!(%{
          "timestamp" => sampled_at,
          "load1" => 3.88,
          "runnable" => 7,
          "cpu_idle_pct" => 87,
          "mem_available_kb" => 65_464_848,
          "swap_used_kb" => 0,
          "d_state_processes" => 0,
          "d_state_streak" => 0,
          "opencode_processes" => 45,
          "beam_processes" => 1,
          "warning" => 0,
          "alert" => "none"
        })
      )

      assert {:reply, %{result: result}} =
               MCPEnvelope.handle(
                 modern("resources/read", %{"uri" => "casein://host/health"}),
                 TerminalMCP,
                 []
               )

      assert [%{uri: "casein://host/health", mimeType: "application/json", text: text}] =
               result.contents

      decoded = Jason.decode!(text)
      assert decoded["uri"] == "casein://host/health"
      assert decoded["state"] == "healthy"
      assert decoded["sampled_at"] == sampled_at
      assert decoded["host"] == "milc-devbox"

      {:ok, tool} = Casein.Agents.TerminalTools.host_health(%{})
      assert tool.state == decoded["state"]
      assert tool.sampled_at == decoded["sampled_at"]
    end

    test "the ui extension is not declared for a JSON-only resource" do
      assert {:reply, %{result: result}} =
               MCPEnvelope.handle(modern("server/discover"), TerminalMCP, [])

      # Fleet summary is a resources/* entry, not an MCP App.
      refute Map.has_key?(result.capabilities.extensions, @ui_ext)
      assert is_map(result.capabilities.resources)
    end
  end

  test "legacy clients get no cache hints on resources/list" do
    legacy = %{"jsonrpc" => "2.0", "id" => 1, "method" => "resources/list"}

    assert {:reply, %{result: result}} = MCPEnvelope.handle(legacy, ArtifactMCP, [])
    refute Map.has_key?(result, :ttlMs)
    refute Map.has_key?(result, :cacheScope)
  end
end
