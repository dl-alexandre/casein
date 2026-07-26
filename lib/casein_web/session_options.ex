defmodule CaseinWeb.SessionOptions do
  @moduledoc false

  @default_key "_casein_key"
  @default_same_site "Lax"

  def options do
    [
      store: :cookie,
      key: Application.get_env(:casein, :session_cookie_key, @default_key),
      signing_salt: "9/grDa2y",
      secure: secure_cookie?()
    ]
    |> maybe_put_same_site()
  end

  defp secure_cookie? do
    Application.get_env(:casein, :secure_session_cookie, false) and
      not Application.get_env(:casein, :lan_insecure_http, false)
  end

  defp maybe_put_same_site(opts) do
    case Application.get_env(:casein, :session_same_site, @default_same_site) do
      nil -> opts
      same_site -> Keyword.put(opts, :same_site, same_site)
    end
  end
end
