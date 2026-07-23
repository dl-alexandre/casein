defmodule DevIdeWeb.API.PushController do
  @moduledoc """
  Browser Web Push registration for the installed PWA. Session + ForwardAuth +
  CSRF authenticate the viewer (`:workspace_file` pipeline); the subscription is
  stored per workspace so this device receives that workspace's agent alerts.
  """
  use DevIdeWeb, :controller

  alias DevIDE.Push
  alias DevIDE.Push.WebPush

  # GET — the public VAPID key the browser subscribes with (null when unconfigured).
  def vapid_key(conn, _params) do
    json(conn, %{key: WebPush.public_key_b64()})
  end

  # POST — store a PushSubscription for the current user + workspace.
  def subscribe(conn, %{"subscription" => subscription, "workspace_id" => workspace_id})
      when is_map(subscription) and is_binary(workspace_id) do
    case Push.register_web(%{
           workspace_id: workspace_id,
           user_id: current_user_id(conn),
           subscription: subscription
         }) do
      :ok ->
        send_resp(conn, 204, "")

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  def subscribe(conn, _params), do: conn |> put_status(400) |> json(%{error: "invalid_request"})

  # POST — drop a subscription by its endpoint (e.g. permission revoked client-side).
  def unsubscribe(conn, %{"endpoint" => endpoint}) when is_binary(endpoint) do
    Push.unregister(endpoint)
    send_resp(conn, 204, "")
  end

  def unsubscribe(conn, _params), do: conn |> put_status(400) |> json(%{error: "invalid_request"})

  defp current_user_id(conn) do
    case conn.assigns[:current_user] do
      %{id: id} -> id
      _ -> nil
    end
  end
end
