defmodule CaseinWeb.Plugs.McpTicketRateLimitTest do
  use ExUnit.Case, async: true

  # Discoverability: the deny path (429 + retry-after) is asserted at
  # test/casein_web/controllers/api/mcp_ticket_controller_test.exs.
  # Keep this file so path-mirroring coverage checks find the plug.

  test "plug module is a discoverable Plug" do
    assert {:module, _} = Code.ensure_loaded(CaseinWeb.Plugs.McpTicketRateLimit)
    assert function_exported?(CaseinWeb.Plugs.McpTicketRateLimit, :call, 2)
  end
end
