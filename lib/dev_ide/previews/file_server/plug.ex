defmodule DevIDE.Previews.FileServer.Plug do
  @moduledoc """
  Minimal Plug that serves workspace files from a root-jailed location.

  Reuses `DevIDE.Workspaces.FileAccess.stat/2` and `read/2` so path traversal
  and symlink escapes are refused the same way as the rest of the file stack.
  No auth here — the listener is `127.0.0.1`-only and the preview proxy
  authorizes before forwarding.
  """

  @behaviour Plug

  import Plug.Conn

  alias DevIDE.Files.BrowserViewable
  alias DevIDE.Previews.FileServer
  alias DevIDE.Workspaces.FileAccess

  @impl true
  def init(opts), do: opts

  @impl true
  # Re-serving workspace file bytes is the feature: root-jailed via FileAccess,
  # loopback-only Bandit listener, authorized by the preview proxy. The body is
  # never DevIDE-trusted markup and carries nosniff so it runs as the file's own
  # content-type — same posture as PreviewProxyController's XSS.SendResp skip.
  # sobelow_skip ["XSS.SendResp"]
  def call(conn, opts) do
    loc = Keyword.fetch!(opts, :loc)
    # Any hit (200 or 404) counts as activity so a live preview iframe/proxy
    # keeps the listener from idling out while the pane is still open.
    _ = FileServer.touch(Keyword.get(opts, :server))
    rel = request_rel(conn)

    with true <- is_binary(rel) and rel != "",
         {:ok, %{type: :regular}} <- FileAccess.stat(loc, rel),
         {:ok, body} <- FileAccess.read(loc, rel) do
      conn
      |> put_resp_header("content-type", BrowserViewable.content_type(rel))
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, body)
    else
      _ ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(404, "not found")
    end
  end

  # Prefer request_path so a whole-path URI.encode(rel) (which percent-encodes
  # "/") still round-trips: Bandit may keep "%2F" as one segment, and URI.decode
  # restores the workspace-relative path. Fall back to path_info join.
  defp request_rel(%Plug.Conn{request_path: path} = conn) when is_binary(path) and path != "" do
    rel =
      path
      |> String.trim_leading("/")
      |> URI.decode()

    if rel == "" do
      request_rel_from_path_info(conn)
    else
      rel
    end
  end

  defp request_rel(conn), do: request_rel_from_path_info(conn)

  defp request_rel_from_path_info(%Plug.Conn{path_info: segments})
       when is_list(segments) and segments != [] do
    Enum.map_join(segments, "/", &URI.decode/1)
  end

  defp request_rel_from_path_info(_conn), do: nil
end
