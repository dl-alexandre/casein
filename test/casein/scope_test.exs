defmodule Casein.ScopeTest do
  use ExUnit.Case, async: true

  alias Casein.Scope

  test "from_conn builds a web scope from connection assigns" do
    identity = %{id: "web-user"}

    conn =
      Plug.Test.conn(:get, "/workspaces/ws-1")
      |> Plug.Conn.assign(:current_user, identity)
      |> Plug.Conn.assign(:workspace_id, "ws-1")
      |> Plug.Conn.assign(:capabilities, [:read])

    assert Scope.from_conn(conn) == %Scope{
             identity: identity,
             workspace_id: "ws-1",
             source: :web,
             capabilities: [:read]
           }
  end

  test "from_mcp builds an MCP scope from its workspace binding" do
    identity = %{token_id: "token-1"}

    assert Scope.from_mcp("ws-1", identity: identity, capabilities: [:terminal]) == %Scope{
             identity: identity,
             workspace_id: "ws-1",
             source: :mcp,
             capabilities: [:terminal]
           }

    assert Scope.from_mcp("").workspace_id == nil
  end

  test "from_socket builds a channel scope from socket assigns" do
    identity = %{id: "channel-user"}

    socket = %Phoenix.Socket{
      assigns: %{
        current_user: identity,
        pairing_workspace_id: "ws-1",
        capabilities: [:observe]
      }
    }

    assert Scope.from_socket(socket) == %Scope{
             identity: identity,
             workspace_id: "ws-1",
             source: :channel,
             capabilities: [:observe]
           }
  end

  test "system builds a trusted internal scope" do
    assert Scope.system() == %Scope{
             identity: :system,
             workspace_id: nil,
             source: :system,
             capabilities: :all
           }
  end

  test "authorizes same workspace and denies a different workspace" do
    scope = Scope.from_mcp("ws-1")

    assert Scope.authorizes_workspace?(scope, "ws-1")
    refute Scope.authorizes_workspace?(scope, "ws-2")
  end

  test "system scope authorizes every workspace" do
    assert Scope.authorizes_workspace?(Scope.system(), "ws-1")
    assert Scope.authorizes_workspace?(Scope.system(), "ws-2")
  end
end
