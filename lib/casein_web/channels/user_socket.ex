defmodule CaseinWeb.UserSocket do
  @moduledoc """
  Phoenix socket for the browser terminal stream. Verifies the signed user
  token (`ChannelAuth.verify_user_token/1`) on connect, assigns `:current_user`,
  and routes `terminal:*` topics to `CaseinWeb.TerminalChannel` and
  `session:*` / `mobile:user:*` topics to the mobile companion channels.
  """
  use Phoenix.Socket

  alias Casein.DeviceLinks
  alias Casein.Mobile.FeedTiming
  alias Casein.Origin

  channel "terminal:*", CaseinWeb.TerminalChannel
  channel "session:*", CaseinWeb.SessionChannel
  channel "mobile:user:*", CaseinWeb.MobileUserChannel

  @impl true
  def connect(params, socket, _connect_info) do
    token = params["token"]
    timing = FeedTiming.new(params)

    case CaseinWeb.ChannelAuth.verify_user_token(token) do
      {:ok, user_id, email} when is_binary(user_id) ->
        # The token carries the authenticated user id + email. Email is
        # needed because channels forward auth to the workspace source
        # (Workspaces.get/2 etc.) using `x-auth-request-email` — without
        # it, the source rejects unauthenticated lookups and channel
        # joins refuse.
        user = %{id: user_id, username: user_id, email: email, role: :owner}

        timing =
          FeedTiming.emit(timing, :token_verified,
            outcome: :succeeded,
            reason_code: :user_token
          )

        {:ok,
         socket
         |> assign(:current_user, user)
         |> assign(:mobile_feed_timing, timing)}

      _ ->
        connect_scoped_token(token, socket, timing)
    end
  end

  defp connect_scoped_token(token, socket, timing) do
    case CaseinWeb.ChannelAuth.verify_pairing_token(token) do
      {:ok, %{workspace_id: workspace_id} = claims} ->
        user = Map.take(claims, [:id, :username, :email, :role])

        timing =
          FeedTiming.emit(timing, :token_verified,
            outcome: :succeeded,
            reason_code: :pairing_token
          )

        {:ok,
         socket
         |> assign(:current_user, user)
         |> assign(:pairing_workspace_id, workspace_id)
         |> assign(:mobile_origin_id, Origin.id())
         |> assign(:mobile_origin_name, Origin.display_name())
         |> assign(:mobile_feed_timing, timing)}

      _ ->
        connect_device_link_token(token, socket, timing)
    end
  end

  defp connect_device_link_token(token, socket, timing) do
    case DeviceLinks.verify_token(token) do
      {:ok, %{workspace_id: workspace_id} = claims} when is_binary(workspace_id) ->
        user = Map.take(claims, [:id, :username, :email, :role])

        timing =
          timing
          |> FeedTiming.with_platform(Map.get(claims, :platform))
          |> FeedTiming.emit(:token_verified,
            outcome: :succeeded,
            reason_code: :device_link_token
          )

        {:ok,
         socket
         |> assign(:current_user, user)
         |> assign(:pairing_workspace_id, workspace_id)
         |> assign(:device_link_id, claims.device_link_id)
         |> assign(:mobile_platform, Map.get(claims, :platform))
         |> assign(:mobile_origin_id, claims.origin_id)
         |> assign(:mobile_origin_name, claims.origin_name)
         |> assign(:mobile_feed_timing, timing)}

      _ ->
        # Unauthenticated callers choose the generation query value. Do not
        # let rejected tokens inject attacker-correlated rows into the bounded
        # authenticated feed cohort.
        :error
    end
  end

  @impl true
  def id(socket), do: "users_socket:#{socket.assigns.current_user.id}"
end
