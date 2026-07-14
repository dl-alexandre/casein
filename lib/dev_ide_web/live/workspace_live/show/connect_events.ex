defmodule DevIdeWeb.WorkspaceLive.Show.ConnectEvents do
  # Events for the "Connect an external agent" drawer: mint/revoke self-serve
  # orchestrator MCP tokens and reveal a ready-to-paste durable .mcp.json.
  #
  # These are function-component events, so they flow through the Show LV's
  # authz_gate hook (viewer authorization + @known_events whitelist) — no
  # PanelGate.gate_event call is needed here (that is only for LiveComponents
  # whose events bypass the hook).
  @moduledoc false

  import Phoenix.Component, only: [assign: 2]

  alias DevIDE.Agents.OrchestratorTokens

  def handle_event("connect:toggle", _params, socket) do
    open? = not (socket.assigns[:connect_drawer_open] || false)
    socket = if open?, do: load_tokens(socket), else: socket
    {:noreply, assign(socket, connect_drawer_open: open?, connect_error: nil)}
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

  def handle_event("connect:mint", params, socket) do
    case OrchestratorTokens.create_for_subject(socket.assigns.current_user,
           label: params["label"]
         ) do
      {:ok, raw, _record} ->
        {:noreply,
         socket
         |> assign(
           connect_new_token: raw,
           connect_mcp_json: durable_mcp_json(raw),
           connect_info: "Token minted — copy it now; it is not shown again.",
           connect_error: nil
         )
         |> load_tokens()}

      {:error, _changeset} ->
        {:noreply, assign(socket, connect_error: "Could not mint a token. Please try again.")}
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

  # Durable, workspace-agnostic config: no ?workspace_id in the URL — the agent
  # picks workspace_id per call, so this one config outlives any workspace. Uses
  # the public endpoint URL (Door 2) since the panel is reached over it.
  defp durable_mcp_json(token) do
    base = String.trim_trailing(DevIdeWeb.Endpoint.url(), "/")
    auth = %{"Authorization" => "Bearer " <> token}

    Jason.encode!(
      %{
        "mcpServers" => %{
          "devide-terminal" => %{"url" => base <> "/api/terminals/mcp", "headers" => auth},
          "devide-preview" => %{"url" => base <> "/api/preview/mcp", "headers" => auth},
          "devide-artifact" => %{"url" => base <> "/api/artifacts/mcp", "headers" => auth}
        }
      },
      pretty: true
    )
  end
end
