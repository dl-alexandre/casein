defmodule DevIdeWeb.Plugs.ApiAuth do
  @moduledoc """
  Bearer-token gate for the read-only API.

  Token comes from `:dev_ide, :api_token` (preferred for tests) or the
  `DEV_IDE_API_TOKEN` environment variable. If neither is set the API
  refuses every request with 503 — there is no "open by default" mode.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case configured_token() do
      nil ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, ~s({"error":"api_token_not_configured"}))
        |> halt()

      expected ->
        case bearer(conn) do
          ^expected -> conn
          _ -> deny(conn)
        end
    end
  end

  defp configured_token do
    Application.get_env(:dev_ide, :api_token) ||
      System.get_env("DEV_IDE_API_TOKEN")
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end

  defp deny(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, ~s({"error":"unauthorized"}))
    |> halt()
  end
end
