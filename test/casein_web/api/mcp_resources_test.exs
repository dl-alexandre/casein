defmodule CaseinWeb.API.MCPResourcesTest do
  @moduledoc """
  The `resources/*` surface and the MCP Apps declaration built on it.

  Casein serves resources for exactly one reason today: the artifact viewer that
  hosts render inline.
  """

  use ExUnit.Case, async: false

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

  describe "servers without an app" do
    test "resources/list is empty and templates are never advertised" do
      assert {:reply, %{result: %{resources: []}}} =
               MCPEnvelope.handle(modern("resources/list"), TerminalMCP, [])

      assert {:reply, %{result: %{resourceTemplates: []}}} =
               MCPEnvelope.handle(modern("resources/templates/list"), TerminalMCP, [])
    end

    test "the ui extension is not declared without an app resource" do
      assert {:reply, %{result: result}} =
               MCPEnvelope.handle(modern("server/discover"), TerminalMCP, [])

      # "Has the resources methods" is not the same claim as "renders UI".
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
