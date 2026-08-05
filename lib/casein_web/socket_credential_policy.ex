defmodule CaseinWeb.SocketCredentialPolicy do
  @moduledoc """
  Topic admission rules for credentials accepted by `CaseinWeb.UserSocket`.

  Pairing and durable device-link credentials exist for mobile projection and
  declared actions. They never inherit browser raw-terminal authority. A future
  mobile terminal topic must require its own short-lived child grant; until that
  integration lands, all credentials are denied that topic.
  """

  @type credential_kind :: :user_token | :pairing_token | :device_link_token

  @spec authorize_ordinary_terminal(map()) :: :ok | {:error, :terminal_access_denied}
  def authorize_ordinary_terminal(%{pairing_workspace_id: workspace_id})
      when is_binary(workspace_id),
      do: {:error, :terminal_access_denied}

  def authorize_ordinary_terminal(%{socket_credential: :user_token}), do: :ok

  def authorize_ordinary_terminal(%{socket_credential: kind})
      when kind in [:pairing_token, :device_link_token],
      do: {:error, :terminal_access_denied}

  def authorize_ordinary_terminal(%{socket_credential: _unknown}),
    do: {:error, :terminal_access_denied}

  def authorize_ordinary_terminal(_assigns), do: {:error, :terminal_access_denied}

  @spec authorize_mobile_terminal(map()) :: {:error, :terminal_child_grant_required}
  def authorize_mobile_terminal(_assigns), do: {:error, :terminal_child_grant_required}
end
