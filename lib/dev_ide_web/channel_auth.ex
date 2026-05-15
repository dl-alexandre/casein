defmodule DevIdeWeb.ChannelAuth do
  @moduledoc """
  Centralised auth helpers for Phoenix channels.

  All channel-related token signing/verification flows through this module so
  the salt and max-age live in one place. When real auth lands, this is the
  module to extend, not the LiveViews and channels.
  """

  @user_socket_salt "user socket"
  @max_age 86_400

  @doc """
  Sign a channel token carrying the authenticated identity.

  Email is needed because channels forward auth to the milc-devbox manager
  (`Workspaces.get/2` etc.) as `x-auth-request-email`. The manager derives
  the username server-side, but only accepts the email — not a username — as
  the auth header. Without `email`, channel calls hit the manager unauthed
  and get rejected → `REFUSED JOIN`.
  """
  def sign_user_token(user_id, email \\ nil)
      when is_binary(user_id) and (is_binary(email) or is_nil(email)) do
    Phoenix.Token.sign(DevIdeWeb.Endpoint, @user_socket_salt, %{id: user_id, email: email})
  end

  @doc """
  Verify a channel token. Returns `{:ok, user_id, email}` on success.

  Tolerates legacy tokens that signed just the user_id binary (pre-email
  rollout) by returning `{:ok, id, nil}` — those still work for channels
  that don't need manager auth, and surface as a regular auth failure for
  those that do.
  """
  def verify_user_token(token) when is_binary(token) and byte_size(token) > 0 do
    case Phoenix.Token.verify(DevIdeWeb.Endpoint, @user_socket_salt, token, max_age: @max_age) do
      {:ok, %{id: id, email: email}} when is_binary(id) -> {:ok, id, email}
      # Legacy: token from before the email round-trip landed.
      {:ok, id} when is_binary(id) -> {:ok, id, nil}
      err -> err
    end
  end

  def verify_user_token(_), do: {:error, :missing}
end
