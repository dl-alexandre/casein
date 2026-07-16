defmodule DevIdeWeb.API.CodexHookController do
  @moduledoc "Receives workspace-scoped Codex CLI hook events."

  use DevIdeWeb, :controller

  alias DevIDE.Codex.HookReceiver

  def create(conn, %{"id" => workspace_id} = params) do
    payload = Map.get(params, "event", %{})

    with :ok <- require_workspace_scope(conn, workspace_id),
         true <- is_map(payload) || {:error, :invalid_payload},
         {:ok, events} <-
           HookReceiver.ingest(workspace_id, payload,
             transport: transport(params["transport"]),
             pane: params["pane"],
             tmux_session: params["tmux_session"],
             session_id: params["session_id"]
           ) do
      conn
      |> put_status(:accepted)
      |> json(%{accepted: true, event_ids: Enum.map(events, & &1.id)})
    else
      {:error, :workspace_scope_required} ->
        conn |> put_status(:forbidden) |> json(%{error: "workspace_scoped_token_required"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  defp require_workspace_scope(%{assigns: %{api_workspace_id: workspace_id}}, workspace_id),
    do: :ok

  defp require_workspace_scope(_conn, _workspace_id), do: {:error, :workspace_scope_required}
  defp transport("notify"), do: :notify
  defp transport(_value), do: :hook
end
