defmodule DevIdeWeb.Plugs.AgentCapabilityAuthzTest do
  use DevIDE.TestCase, async: false

  import Plug.Conn
  import Plug.Test

  alias DevIdeWeb.Plugs.AgentCapabilityAuthz

  @workspace_id "ws-cap-authz"
  @tmux_session "devide_ws-cap-authz_agent"
  @token_id "cap-token-1"

  @claims %{
    workspace_id: @workspace_id,
    tmux_session_id: @tmux_session,
    allowed_tools: %{
      "terminal" => ["terminal_list_sessions"],
      "preview" => ["preview_surfaces"],
      "artifact" => ["artifact_list"]
    }
  }

  defp capability_conn(path, query) do
    qs =
      query
      |> Enum.map(fn {k, v} -> "#{k}=#{URI.encode_www_form(to_string(v))}" end)
      |> Enum.join("&")

    url = if qs == "", do: path, else: path <> "?" <> qs

    :post
    |> conn(url)
    |> assign(:api_token_scope, {:agent_capability, @token_id})
    |> assign(:api_agent_capability, @claims)
  end

  defp assert_allowed(conn) do
    refute conn.halted
    refute conn.status == 403
    assert conn.assigns[:api_agent_capability_surface] in ~w(terminal preview artifact)
    assert is_map(conn.assigns[:api_agent_capability_tools])
    assert is_map(conn.assigns[:api_agent_capability_policy])
  end

  defp assert_denied(conn, reason) do
    assert conn.halted
    assert conn.status == 403

    body = Jason.decode!(conn.resp_body)
    assert body["error"] == reason
    assert body["code"] == "agent_capability_forbidden"
    assert body["error_version"] == "mcp-capability-v1"
  end

  describe "pass-through" do
    test "leaves non-capability bearers untouched" do
      conn =
        :post
        |> conn("/api/terminals/mcp?workspace_id=#{@workspace_id}&tmux_session=#{@tmux_session}")
        |> assign(:api_token_scope, {:workspace, @workspace_id})
        |> AgentCapabilityAuthz.call([])

      refute conn.halted
      refute Map.has_key?(conn.assigns, :api_agent_capability_surface)
    end
  end

  describe "workspace confinement" do
    test "allows when workspace_id matches the capability claim" do
      conn =
        capability_conn("/api/terminals/mcp", %{
          "workspace_id" => @workspace_id,
          "tmux_session" => @tmux_session
        })
        |> AgentCapabilityAuthz.call([])

      assert_allowed(conn)
      assert conn.assigns.api_agent_capability_surface == "terminal"
    end

    test "denies when workspace_id does not match the capability claim" do
      conn =
        capability_conn("/api/terminals/mcp", %{
          "workspace_id" => "ws-other",
          "tmux_session" => @tmux_session
        })
        |> AgentCapabilityAuthz.call([])

      assert_denied(conn, "capability_workspace_mismatch")
    end
  end

  describe "session confinement" do
    test "allows when tmux_session matches the capability claim on terminal" do
      conn =
        capability_conn("/api/terminals/mcp", %{
          "workspace_id" => @workspace_id,
          "tmux_session" => @tmux_session
        })
        |> AgentCapabilityAuthz.call([])

      assert_allowed(conn)
    end

    test "allows when tmux_session matches the capability claim on preview" do
      conn =
        capability_conn("/api/preview/mcp", %{
          "workspace_id" => @workspace_id,
          "tmux_session" => @tmux_session
        })
        |> AgentCapabilityAuthz.call([])

      assert_allowed(conn)
      assert conn.assigns.api_agent_capability_surface == "preview"
    end

    test "denies when tmux_session does not match on terminal" do
      conn =
        capability_conn("/api/terminals/mcp", %{
          "workspace_id" => @workspace_id,
          "tmux_session" => "devide_ws-cap-authz_other"
        })
        |> AgentCapabilityAuthz.call([])

      assert_denied(conn, "capability_session_mismatch")
    end

    test "denies when tmux_session is missing on terminal" do
      conn =
        capability_conn("/api/terminals/mcp", %{"workspace_id" => @workspace_id})
        |> AgentCapabilityAuthz.call([])

      assert_denied(conn, "capability_session_mismatch")
    end

    test "artifact surface skips tmux_session confinement" do
      conn =
        capability_conn("/api/artifacts/mcp", %{"workspace_id" => @workspace_id})
        |> AgentCapabilityAuthz.call([])

      assert_allowed(conn)
      assert conn.assigns.api_agent_capability_surface == "artifact"
    end
  end

  describe "surface confinement" do
    test "allows terminal, preview, and artifact MCP paths" do
      for path <- ["/api/terminals/mcp", "/api/preview/mcp", "/api/artifacts/mcp"] do
        query =
          if path == "/api/artifacts/mcp" do
            %{"workspace_id" => @workspace_id}
          else
            %{"workspace_id" => @workspace_id, "tmux_session" => @tmux_session}
          end

        conn =
          capability_conn(path, query)
          |> AgentCapabilityAuthz.call([])

        assert_allowed(conn)
      end
    end

    test "denies managed-agent bearer on a non-MCP path" do
      conn =
        capability_conn("/api/workspaces/#{@workspace_id}/sessions", %{
          "workspace_id" => @workspace_id,
          "tmux_session" => @tmux_session
        })
        |> AgentCapabilityAuthz.call([])

      assert_denied(conn, "capability_surface_forbidden")
    end
  end

  describe "handler_opts/1" do
    test "returns capability assigns after a successful authorize" do
      conn =
        capability_conn("/api/terminals/mcp", %{
          "workspace_id" => @workspace_id,
          "tmux_session" => @tmux_session
        })
        |> AgentCapabilityAuthz.call([])

      opts = AgentCapabilityAuthz.handler_opts(conn)

      assert opts[:agent_capability] == @claims
      assert opts[:agent_capability_surface] == "terminal"
      assert is_map(opts[:agent_capability_tools])
      assert is_map(opts[:agent_capability_policy])
    end

    test "returns empty list without capability claims" do
      conn = conn(:post, "/api/terminals/mcp")
      assert AgentCapabilityAuthz.handler_opts(conn) == []
    end
  end
end
