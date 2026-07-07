defmodule DevIdeWeb.AuthHeader do
  @moduledoc false

  import Plug.Conn

  @doc """
  Returns the bearer token from `conn.private` (preserved before log scrubbing)
  or the live `Authorization` header.
  """
  def bearer_token(conn) do
    case conn.private[:dev_ide_bearer_token] do
      token when is_binary(token) -> token
      _ -> bearer_from_header(conn)
    end
  end

  defp bearer_from_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end
end
