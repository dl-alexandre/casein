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
    token = bearer(conn)

    if fleet_runner_path?(conn.request_path) do
      authorize(conn, token, runner_tokens())
    else
      authorize(conn, token, api_tokens())
    end
  end

  defp authorize(conn, token, tokens) do
    case Enum.reject(tokens, &is_nil/1) do
      [] ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, ~s({"error":"api_token_not_configured"}))
        |> halt()

      configured_tokens ->
        if Enum.any?(configured_tokens, &secure_match?(token, &1)), do: conn, else: deny(conn)
    end
  end

  defp api_tokens do
    [
      Application.get_env(:dev_ide, :api_token),
      System.get_env("DEV_IDE_API_TOKEN")
    ]
  end

  defp runner_tokens do
    [
      Application.get_env(:dev_ide, :runner_token),
      System.get_env("DEV_IDE_RUNNER_TOKEN")
      | api_tokens()
    ]
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end

  defp fleet_runner_path?(path) when is_binary(path),
    do: String.starts_with?(path, "/api/fleet/v1/")

  defp fleet_runner_path?(_path), do: false

  defp secure_match?(token, expected) when is_binary(token) and is_binary(expected) do
    byte_size(token) == byte_size(expected) and Plug.Crypto.secure_compare(token, expected)
  end

  defp secure_match?(_token, _expected), do: false

  defp deny(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, ~s({"error":"unauthorized"}))
    |> halt()
  end
end
