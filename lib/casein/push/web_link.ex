defmodule Casein.Push.WebLink do
  @moduledoc """
  Builds the in-app URL a Web Push notification opens.

  Every notification carries a native `casein://` deep link for APNs/FCM, which
  a browser cannot open. Without a translation the web provider fell back to
  `/`, and `/` mounts the *scratch* workspace (`CockpitData.resolve_mount_workspace/3`)
  — so clicking any push landed the operator on a blank scratch page instead of
  the workspace that raised it.

  This rewrites the notification into a real workspace deep link
  (`docs/deep_links.md`), carrying whatever locator the card projected so the
  click lands on the exact session/window/pane the agent is waiting in.
  """

  # Ordered as docs/deep_links.md specifies Casein writes them.
  @locator_params [:session, :window, :pane, :tmux_session, :tab]

  @doc """
  Return an app-relative (or absolute http) URL for `notification`.

  Falls back to `/` only when there is no workspace to point at.
  """
  @spec build(map()) :: String.t()
  def build(notification) when is_map(notification) do
    case notification[:deep_link] || notification[:url] do
      "http" <> _ = url -> url
      _ -> workspace_url(notification)
    end
  end

  defp workspace_url(notification) do
    case notification[:workspace_id] do
      id when is_binary(id) and id != "" ->
        path = "/workspaces/" <> URI.encode_www_form(id)

        case query_string(notification) do
          "" -> path
          query -> path <> "?" <> query
        end

      _ ->
        "/"
    end
  end

  defp query_string(notification) do
    params = Enum.flat_map(@locator_params, &param(&1, notification))

    # An alert with no session to attach to still has somewhere useful to land:
    # the notifications drawer, where the durable row lives.
    params =
      if params == [] and is_binary(notification[:notification_id]) do
        [{"drawer", "notifications"}]
      else
        params
      end

    URI.encode_query(params)
  end

  defp param(:session, notification) do
    pair("session", notification[:session_id] || locator(notification, :session))
  end

  defp param(key, notification) do
    pair(Atom.to_string(key), locator(notification, key))
  end

  defp locator(notification, key) do
    case notification[:locator] do
      locator when is_map(locator) -> locator[key] || locator[Atom.to_string(key)]
      _ -> nil
    end
  end

  defp pair(_key, value) when value in [nil, ""], do: []
  defp pair(key, value) when is_binary(value), do: [{key, value}]
  defp pair(_key, _value), do: []
end
