defmodule CaseinWeb.API.MCPResourcesTest do
  @moduledoc """
  The `resources/*` surface and the MCP Apps declaration built on it.

  Casein serves resources for the artifact viewer (MCP App) and the terminal
  fleet summary (`casein://fleet/summary`).
  """

  use ExUnit.Case, async: false

  alias CaseinWeb.API.{ArtifactMCP, MCPEnvelope, TerminalMCP}

  defmodule EmptyTmux do
    def list_sessions, do: []
    def session_topology(_), do: {[], []}
    def list_session_windows(_), do: []
    def list_session_panes(_), do: []
  end

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
      previous = Application.get_env(:casein, :tmux_adapter)
      Application.put_env(:casein, :tmux_adapter, EmptyTmux)
      on_exit(fn -> Application.put_env(:casein, :tmux_adapter, previous) end)

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
      assert decoded["note"] =~ "process/CPU"
    end

    test "the ui extension is not declared for a JSON-only resource" do
      assert {:reply, %{result: result}} =
               MCPEnvelope.handle(modern("server/discover"), TerminalMCP, [])

      # Fleet summary is a resources/* entry, not an MCP App.
      refute Map.has_key?(result.capabilities.extensions, @ui_ext)
      assert is_map(result.capabilities.resources)
    end
  end

  describe "terminal host health resource" do
    test "resources/list publishes casein://host/health" do
      assert {:reply, %{result: result}} =
               MCPEnvelope.handle(modern("resources/list"), TerminalMCP, [])

      assert Enum.any?(result.resources, fn r ->
               r.uri == "casein://host/health" and r.mimeType == "application/json"
             end)
    end

    test "resources/read and host_health tool share one unknown snapshot when missing" do
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
      assert decoded["state"] == "unknown"
      assert decoded["reason"] == "unavailable"

      assert {:reply, %{result: tool}} =
               MCPEnvelope.handle(
                 modern("tools/call", %{"name" => "host_health", "arguments" => %{}}),
                 TerminalMCP,
                 []
               )

      assert tool.structuredContent["state"] == decoded["state"]
      assert tool.structuredContent["reason"] == decoded["reason"]
      assert tool.structuredContent["sampled_at"] == decoded["sampled_at"]
    end
  end

  test "legacy clients get no cache hints on resources/list" do
    legacy = %{"jsonrpc" => "2.0", "id" => 1, "method" => "resources/list"}

    assert {:reply, %{result: result}} = MCPEnvelope.handle(legacy, ArtifactMCP, [])
    refute Map.has_key?(result, :ttlMs)
    refute Map.has_key?(result, :cacheScope)
  end
end
