defmodule CaseinWeb.WorkspaceLive.Show.ConnectEvents do
  # Events for the "Connect an external agent" drawer: issue a workspace-scoped
  # MCP credential and reveal a ready-to-paste pre-scoped .mcp.json. Leftover
  # orchestrator tokens can still be listed/revoked.
  #
  # These are function-component events, so they flow through the Show LV's
  # authz_gate hook (viewer authorization + @known_events whitelist) — no
  # PanelGate.gate_event call is needed here (that is only for LiveComponents
  # whose events bypass the hook).
  @moduledoc false

  import Phoenix.Component, only: [assign: 2]

  alias Casein.Agents.{MCPUrls, OrchestratorTokens, WorkspaceTokens}

  def handle_event("connect:toggle", _params, socket) do
    open? = not (socket.assigns[:connect_drawer_open] || false)
    socket = if open?, do: load_tokens(socket), else: socket
    {:noreply, assign(socket, connect_drawer_open: open?, connect_error: nil)}
  end

  # Populate the token list without a drawer — the connect UI lives in the
  # help overlay's Agents tab; selecting that tab pushes this to refresh tokens.
  def handle_event("connect:load", _params, socket) do
    {:noreply, load_tokens(socket)}
  end

  def handle_event("connect:close", _params, socket) do
    {:noreply,
     assign(socket,
       connect_drawer_open: false,
       connect_new_token: nil,
       connect_mcp_json: nil,
       connect_error: nil,
       connect_info: nil
     )}
  end

  def handle_event("connect:mint", _params, socket) do
    workspace = socket.assigns[:workspace]

    case issue_scoped_credential(workspace) do
      {:ok, token} ->
        workspace_id = workspace_id(workspace)

        {:noreply,
         socket
         |> assign(
           connect_new_token: token,
           connect_mcp_json: scoped_mcp_json(workspace, token),
           connect_info:
             "Workspace-scoped MCP credential ready — copy the .mcp.json. " <>
               "Rotate with POST /api/workspaces/#{workspace_id}/api-token/rotate " <>
               "(in-flight grokcap_* agents see stale_grant until relaunch).",
           connect_error: nil
         )
         |> load_tokens()}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           connect_error: "Could not issue a workspace-scoped token. Please try again."
         )}
    end
  end

  def handle_event("connect:revoke", %{"id" => id}, socket) do
    case OrchestratorTokens.revoke(id, socket.assigns.current_user) do
      {:ok, _record} ->
        {:noreply,
         socket
         |> assign(connect_info: "Token revoked.", connect_error: nil)
         |> maybe_clear_revoked(id)
         |> load_tokens()}

      {:error, _reason} ->
        {:noreply, assign(socket, connect_error: "Token not found.")}
    end
  end

  defp load_tokens(socket) do
    subject_id = OrchestratorTokens.subject_id(socket.assigns.current_user)
    assign(socket, connect_tokens: OrchestratorTokens.list_for_subject(subject_id))
  end

  # If the just-minted (still-revealed) token is the one being revoked, stop
  # showing its raw value / config.
  defp maybe_clear_revoked(socket, _id) do
    if socket.assigns[:connect_new_token] do
      assign(socket, connect_new_token: nil, connect_mcp_json: nil)
    else
      socket
    end
  end

  defp issue_scoped_credential(workspace) do
    case workspace_id(workspace) do
      id when is_binary(id) and id != "" -> WorkspaceTokens.ensure_for(id)
      _ -> {:error, :workspace_id_missing}
    end
  end

  defp scoped_mcp_json(workspace, token) do
    MCPUrls.client_mcp_json(workspace, token, base_url: public_base())
  end

  defp public_base, do: String.trim_trailing(CaseinWeb.Endpoint.url(), "/")

  defp workspace_id(%{id: id}) when is_binary(id), do: id
  defp workspace_id(%{"id" => id}) when is_binary(id), do: id
  defp workspace_id(_), do: nil
end
