defmodule CaseinWeb.LegacyHostRedirect do
  @moduledoc """
  Permanently redirects browser navigations that arrive on a retired public
  host to the canonical origin.

  A retired host still resolves and is still served, but
  `Casein.Origin.authorize_request_base/1` rejects it, so a page loaded there
  renders and then fails its socket connect — the client sees a reconnect
  error before it lands anywhere useful. Redirecting the navigation keeps that
  failure from reaching the client at all.

  Only `GET` and `HEAD` are redirected. A 301 on a credential-bearing API or
  MCP request would invite the client to replay it against the canonical host,
  so those keep their existing fail-closed rejection instead.

  Installations without a canonical origin (desktop and LAN, where the
  reachable address is chosen by the operator at pairing time) are unaffected.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: method} = conn, _opts) when method in ~w(GET HEAD) do
    with canonical when is_binary(canonical) <- Casein.Origin.canonical_base_url(),
         true <- deprecated_host?(conn.host) do
      conn
      |> put_resp_header("location", canonical <> forwarded_suffix(conn))
      |> put_resp_content_type("text/plain")
      |> send_resp(301, "Moved Permanently")
      |> halt()
    else
      _ -> conn
    end
  end

  def call(conn, _opts), do: conn

  defp deprecated_host?(host) when is_binary(host) do
    normalized = String.downcase(host)

    :casein
    |> Application.get_env(:deprecated_public_hosts, [])
    |> Enum.any?(&(String.downcase(&1) == normalized))
  end

  defp deprecated_host?(_host), do: false

  defp forwarded_suffix(%Plug.Conn{query_string: ""} = conn), do: conn.request_path
  defp forwarded_suffix(conn), do: conn.request_path <> "?" <> conn.query_string
end
