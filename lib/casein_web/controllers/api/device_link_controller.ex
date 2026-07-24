defmodule CaseinWeb.API.DeviceLinkController do
  @moduledoc """
  Exchanges a short-lived pairing token for a persistent device credential.
  """

  use CaseinWeb, :controller

  alias Casein.DeviceLinks
  alias CaseinWeb.ChannelAuth

  def exchange(conn, params) do
    token = params["token"] || params["pairing_token"]

    with {:ok, claims} <- ChannelAuth.verify_pairing_token(token),
         {:ok, result} <- DeviceLinks.create_from_pairing_claims(claims, params) do
      json(conn, exchange_payload(conn, result))
    else
      {:error, :missing} -> error(conn, :unprocessable_entity, "missing_token")
      {:error, :invalid_pairing_claims} -> error(conn, :unprocessable_entity, "invalid_claims")
      {:error, :invalid_pairing_token} -> error(conn, :unauthorized, "invalid_pairing_token")
      {:error, :expired} -> error(conn, :unauthorized, "pairing_token_expired")
      {:error, :not_found} -> error(conn, :not_found, "resource_not_found")
      {:error, :unauthorized} -> error(conn, :forbidden, "resource_forbidden")
      {:error, %Ecto.Changeset{}} -> error(conn, :unprocessable_entity, "invalid_device_link")
      {:error, _reason} -> error(conn, :unauthorized, "invalid_pairing_token")
    end
  end

  def rotate(conn, params) do
    case device_link_token(params) do
      token when is_binary(token) ->
        case DeviceLinks.rotate_token(token) do
          {:ok, result} -> json(conn, exchange_payload(conn, result))
          {:error, reason} -> rotate_error(conn, reason)
        end

      _ ->
        error(conn, :unprocessable_entity, "missing_token")
    end
  end

  def revoke(conn, params) do
    case device_link_token(params) do
      token when is_binary(token) ->
        case DeviceLinks.revoke_token(token) do
          {:ok, _link} -> json(conn, %{status: "revoked"})
          {:error, :not_found} -> error(conn, :not_found, "resource_not_found")
          {:error, :missing} -> error(conn, :unprocessable_entity, "missing_token")
          {:error, %Ecto.Changeset{}} -> error(conn, :unprocessable_entity, "invalid_device_link")
          {:error, _reason} -> error(conn, :unauthorized, "invalid_token")
        end

      _ ->
        error(conn, :unprocessable_entity, "missing_token")
    end
  end

  defp device_link_token(params),
    do: params["token"] || params["device_link_token"]

  defp rotate_error(conn, :missing), do: error(conn, :unprocessable_entity, "missing_token")
  defp rotate_error(conn, :invalid_token), do: error(conn, :unauthorized, "invalid_token")
  defp rotate_error(conn, :revoked), do: error(conn, :unauthorized, "token_revoked")
  defp rotate_error(conn, :expired), do: error(conn, :unauthorized, "token_expired")
  defp rotate_error(conn, :not_found), do: error(conn, :not_found, "resource_not_found")
  defp rotate_error(conn, :unauthorized), do: error(conn, :forbidden, "resource_forbidden")

  defp rotate_error(conn, %Ecto.Changeset{}),
    do: error(conn, :unprocessable_entity, "invalid_device_link")

  defp rotate_error(conn, _reason), do: error(conn, :unauthorized, "invalid_token")

  defp exchange_payload(conn, %{
         token: token,
         link: link,
         workspace: workspace,
         capabilities: caps
       }) do
    base = base_url(conn)
    workspace_id = workspace_id(workspace, link)
    workspace_label = workspace_label(workspace, link)

    %{
      origin: origin_payload(base),
      credential: %{
        token: token,
        token_type: "device_link",
        expires_at: datetime(link.expires_at)
      },
      resources: [
        %{
          kind: link.resource_kind,
          id: workspace_id,
          label: workspace_label
        }
      ],
      capabilities: caps,
      url: base,
      token: token,
      token_type: "device_link",
      workspace_id: workspace_id
    }
  end

  defp origin_payload(base) do
    %{
      id: "dev_ide",
      name: "Casein",
      base_url: base,
      socket_url: base <> "/socket/websocket",
      token_exchange_url: base <> "/api/device-links/exchange",
      audience: "dev_ide"
    }
  end

  defp workspace_id(workspace, link) do
    Map.get(workspace, :id) || Map.get(workspace, "id") || link.resource_id
  end

  defp workspace_label(workspace, link) do
    Map.get(workspace, :name) || Map.get(workspace, "name") || link.resource_label ||
      workspace_id(workspace, link)
  end

  defp datetime(nil), do: nil
  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp base_url(conn) do
    port = if conn.port in [80, 443], do: "", else: ":#{conn.port}"
    "#{conn.scheme}://#{conn.host}#{port}"
  end

  defp error(conn, status, error) do
    conn
    |> put_status(status)
    |> json(%{error: error})
  end
end
