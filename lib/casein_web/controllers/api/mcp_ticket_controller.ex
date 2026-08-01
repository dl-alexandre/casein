defmodule CaseinWeb.API.McpTicketController do
  @moduledoc "HTTP exchange from an authenticated agent capability to an MCP ticket."

  use CaseinWeb, :controller

  alias Casein.Agents.{McpTickets, MCPUrls}

  def exchange(%{assigns: %{api_agent_capability: claims}} = conn, params) do
    with {:ok, workspace_id} <- required_string(params, "workspace_id"),
         true <- workspace_id == claims.workspace_id,
         {:ok, surface} <- surface(params["surface"]),
         {:ok, scopes} <- scopes(params["scopes"]),
         {:ok, ticket} <- McpTickets.issue(claims, surface, scopes) do
      conn
      |> put_status(:created)
      |> json(%{
        ticket: ticket.ticket,
        ticket_id: ticket.id,
        workspace_id: ticket.workspace_id,
        surface: ticket.surface,
        scopes: ticket.scopes,
        expires_at: ticket.expires_at,
        expires_in: ticket.expires_in,
        url:
          MCPUrls.ticket_url(
            ticket.surface,
            ticket.workspace_id,
            claims.tmux_session_id,
            ticket.ticket
          )
      })
    else
      false -> forbidden(conn, "ticket_workspace_mismatch")
      {:error, :scope_escalation} -> forbidden(conn, "ticket_scope_escalation")
      {:error, :surface_not_granted} -> forbidden(conn, "ticket_surface_not_granted")
      {:error, %Ecto.Changeset{} = changeset} -> invalid(conn, errors(changeset))
      {:error, reason} when is_atom(reason) -> invalid(conn, Atom.to_string(reason))
      {:error, reason} -> invalid(conn, inspect(reason))
    end
  end

  def exchange(conn, _params), do: forbidden(conn, "agent_capability_required")

  defp required_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_ticket_request}
    end
  end

  defp surface(surface) when surface in ~w(terminal preview artifact), do: {:ok, surface}
  defp surface(_surface), do: {:error, :invalid_ticket_surface}

  defp scopes(scopes) when is_list(scopes) and scopes != [], do: {:ok, scopes}
  defp scopes(_scopes), do: {:error, :invalid_ticket_scopes}

  defp forbidden(conn, error) do
    conn |> put_status(:forbidden) |> json(%{error: error})
  end

  defp invalid(conn, detail) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "invalid_mcp_ticket", detail: detail})
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
