defmodule DevIdeWeb.Plugs.ScrubLoggedHeaders do
  @moduledoc """
  Preserve bearer tokens for auth plugs while scrubbing `Authorization` from
  `conn.req_headers` so Phoenix request logging never emits raw secrets.
  """

  import Plug.Conn

  @scrubbed "[FILTERED]"

  def init(opts), do: opts

  def call(%{req_headers: headers} = conn, _opts) do
    {scrubbed_headers, token} = scrub_headers(headers)

    conn =
      if is_binary(token) do
        put_private(conn, :dev_ide_bearer_token, token)
      else
        conn
      end

    %{conn | req_headers: scrubbed_headers}
  end

  defp scrub_headers(headers) do
    Enum.map_reduce(headers, nil, fn
      {"authorization", "Bearer " <> token}, _acc ->
        {{"authorization", @scrubbed}, token}

      {"Authorization", "Bearer " <> token}, _acc ->
        {{"Authorization", @scrubbed}, token}

      pair, acc ->
        {pair, acc}
    end)
  end
end
