defmodule Casein.Agents.McpTicketsTest do
  use Casein.DataCase, async: false

  alias Casein.Agents.{McpTicket, McpTickets}
  alias Casein.Repo

  @now ~U[2026-08-01 09:00:00.000000Z]

  setup do
    previous_clock = Application.fetch_env!(:casein, :mcp_ticket_clock)
    previous_ttl = Application.fetch_env!(:casein, :mcp_ticket_ttl_seconds)
    Application.put_env(:casein, :mcp_ticket_clock, fn -> @now end)
    Application.put_env(:casein, :mcp_ticket_ttl_seconds, 300)

    on_exit(fn ->
      Application.put_env(:casein, :mcp_ticket_clock, previous_clock)
      Application.put_env(:casein, :mcp_ticket_ttl_seconds, previous_ttl)
    end)

    :ok
  end

  test "ticket works exactly once and a replay is rejected" do
    assert {:ok, issued} = McpTickets.issue(claims(), "terminal", ["terminal_capture"])
    refute issued.ticket == Repo.get!(McpTicket, issued.id).ticket_hash
    assert issued.expires_in == 300
    assert issued.expires_at == DateTime.add(@now, 300, :second)

    assert {:ok, consumed} = McpTickets.consume(issued.ticket, "ws-ticket", "terminal")
    assert consumed.allowed_tools == %{"terminal" => ["terminal_capture"]}

    assert {:error, :ticket_replayed} =
             McpTickets.consume(issued.ticket, "ws-ticket", "terminal")
  end

  test "expired ticket is rejected using the injected clock" do
    assert {:ok, issued} = McpTickets.issue(claims(), "terminal", ["terminal_capture"])
    Application.put_env(:casein, :mcp_ticket_clock, fn -> DateTime.add(@now, 301, :second) end)

    assert {:error, :ticket_expired} =
             McpTickets.consume(issued.ticket, "ws-ticket", "terminal")
  end

  test "ticket cannot carry scopes the presenting credential lacked" do
    assert {:error, :scope_escalation} =
             McpTickets.issue(claims(), "terminal", ["terminal_send_command"])

    assert Repo.aggregate(McpTicket, :count) == 0
  end

  test "ticket is bound to its workspace and surface without being consumed on mismatch" do
    assert {:ok, issued} = McpTickets.issue(claims(), "terminal", ["terminal_capture"])

    assert {:error, :ticket_workspace_mismatch} =
             McpTickets.consume(issued.ticket, "ws-other", "terminal")

    assert {:error, :ticket_surface_mismatch} =
             McpTickets.consume(issued.ticket, "ws-ticket", "preview")

    assert {:ok, _claims} = McpTickets.consume(issued.ticket, "ws-ticket", "terminal")
  end

  defp claims do
    %{
      id: Ecto.UUID.generate(),
      workspace_id: "ws-ticket",
      runtime: "grok",
      tmux_session_id: "casein_ws-ticket_agent",
      pane_id: "%7",
      leader_id: String.duplicate("a", 24),
      bundle_digest: String.duplicate("b", 64),
      workspace_mode: "manual",
      allowed_tools: %{
        "terminal" => ["terminal_capture", "terminal_list_sessions"],
        "preview" => ["preview_screenshot"]
      },
      checkout_digest: String.duplicate("c", 64)
    }
  end
end
