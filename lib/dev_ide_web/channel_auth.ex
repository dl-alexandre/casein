defmodule DevIdeWeb.ChannelAuth do
  @moduledoc """
  Centralised auth helpers for Phoenix channels.

  All channel-related token signing/verification flows through this module so
  the salt and max-age live in one place. When real auth lands, this is the
  module to extend, not the LiveViews and channels.
  """

  @user_socket_salt "user socket"
  @max_age 86_400

  def sign_user_token(user_id),
    do: Phoenix.Token.sign(DevIdeWeb.Endpoint, @user_socket_salt, user_id)

  def verify_user_token(token) when is_binary(token) and byte_size(token) > 0 do
    Phoenix.Token.verify(DevIdeWeb.Endpoint, @user_socket_salt, token, max_age: @max_age)
  end

  def verify_user_token(_), do: {:error, :missing}
end
