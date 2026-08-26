defmodule CaseinWeb.API.MCPToolSurfaceTest do
  @moduledoc """
  Modern `server/discover` tool-surface identity: a deterministic inventory
  digest plus explicit scoped-vs-external metadata. Legacy `initialize` must
  stay free of these fields.
  """

  use ExUnit.Case, async: true

  alias CaseinWeb.API.MCPEnvelope

  defmodule StubHandler do
    @moduledoc false
    @behaviour CaseinWeb.API.MCPEnvelope

    @impl true
    def server_name, do: "Stub Tool Surface"

    @impl true
    def instructions(_opts), do: "stub instructions"

    @impl true
    def list_tools(opts) do
      Keyword.get(opts, :tools, [
        %{name: "zeta_tool"},
        %{name: "alpha_tool"}
      ])
    end

    @impl true
    def task_tools, do: []

    @impl true
    def list_resources(_opts), do: []

    @impl true
    def read_resource(_uri, _opts), do: {:error, :not_found}

    @impl true
    def call_tool(id, _params, _opts), do: MCPEnvelope.result(id, %{})
  end

  defp modern(method) do
    %{
      "jsonrpc" => "2.0",
      "id" => "surface-1",
      "method" => method,
      "params" => %{
        "_meta" => %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28"}
      }
    }
  end

  defp discover(opts \\ []) do
    assert {:reply, %{result: result}} =
             MCPEnvelope.handle(modern("server/discover"), StubHandler, opts)

    result
  end

  defp capability_opts(allowed) do
    [
      agent_capability: %{id: "cap-1", workspace_id: "ws-1"},
      agent_capability_surface: "terminal",
      agent_capability_tools: %{"terminal" => allowed}
    ]
  end

  test "toolSurface id is deterministic for the same caller-visible inventory" do
    first = discover()
    second = discover()

    assert first.toolSurface.id == second.toolSurface.id
    assert first.toolSurface.id =~ ~r/\Asha256:[0-9a-f]{64}\z/
    assert first.toolSurface.toolCount == 2
    assert is_binary(first.toolSurface.version)
  end

  test "toolSurface id is independent of handler list order" do
    a = discover(tools: [%{name: "alpha_tool"}, %{name: "zeta_tool"}])
    b = discover(tools: [%{name: "zeta_tool"}, %{name: "alpha_tool"}])

    assert a.toolSurface.id == b.toolSurface.id
  end

  test "toolSurface id changes when the exposed tool inventory changes" do
    full = discover(tools: [%{name: "alpha_tool"}, %{name: "zeta_tool"}])
    reduced = discover(tools: [%{name: "alpha_tool"}])

    assert full.toolSurface.toolCount == 2
    assert reduced.toolSurface.toolCount == 1
    refute full.toolSurface.id == reduced.toolSurface.id
  end

  test "capability filtering is part of the caller-visible inventory id" do
    unscoped = discover(tools: [%{name: "alpha_tool"}, %{name: "zeta_tool"}])

    scoped =
      discover(
        Keyword.merge(
          [tools: [%{name: "alpha_tool"}, %{name: "zeta_tool"}]],
          capability_opts(["alpha_tool"])
        )
      )

    assert scoped.toolSurface.toolCount == 1
    refute scoped.toolSurface.id == unscoped.toolSurface.id
  end

  test "external vs workspace vs capability scope is explicit" do
    external = discover()
    assert external.toolSurface.scope == "external"
    assert external.toolSurface.callerScoped == false
    assert external.toolSurface.workspaceScoped == false
    assert external.toolSurface.pinnedUntilReconnect == true

    workspace = discover(default_workspace_id: "ws-1")
    assert workspace.toolSurface.scope == "workspace"
    assert workspace.toolSurface.callerScoped == true
    assert workspace.toolSurface.workspaceScoped == true
    assert workspace.toolSurface.pinnedUntilReconnect == true

    # Same names, so inventories compare equal; scope metadata is the difference.
    assert workspace.toolSurface.id == external.toolSurface.id
    assert workspace.toolSurface.toolCount == external.toolSurface.toolCount

    capability =
      discover(
        Keyword.merge(
          [default_workspace_id: "ws-1"],
          capability_opts(["alpha_tool", "zeta_tool"])
        )
      )

    assert capability.toolSurface.scope == "capability"
    assert capability.toolSurface.callerScoped == true
    assert capability.toolSurface.workspaceScoped == true
    assert capability.toolSurface.pinnedUntilReconnect == false
  end

  test "legacy initialize does not grow toolSurface fields" do
    message = %{
      "jsonrpc" => "2.0",
      "id" => "init-1",
      "method" => "initialize",
      "params" => %{"protocolVersion" => "2025-03-26"}
    }

    assert {:reply, %{result: result}} =
             MCPEnvelope.handle(message, StubHandler, default_workspace_id: "ws-1")

    refute Map.has_key?(result, :toolSurface)
    refute Map.has_key?(result, :resultType)
    assert result.protocolVersion == "2025-03-26"
    assert result.capabilities.tools.listChanged == false
  end
end
