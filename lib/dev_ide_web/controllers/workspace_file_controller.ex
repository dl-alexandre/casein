defmodule DevIdeWeb.WorkspaceFileController do
  @moduledoc """
  Serves verified workspace files for rendered Markdown and explicit browser
  fetches.

  This endpoint is browser-authenticated with ForwardAuth and still checks the
  viewer owns the workspace. It deliberately serves user-controlled workspace
  bytes with `no-store`, `nosniff`, and conservative inline content types.
  """
  use DevIdeWeb, :controller

  alias DevIDE.Workspaces
  alias DevIDE.Workspaces.FileAccess

  @max_file_bytes 2 * 1024 * 1024

  @raster_image_types %{
    ".avif" => "image/avif",
    ".bmp" => "image/bmp",
    ".gif" => "image/gif",
    ".ico" => "image/x-icon",
    ".jpeg" => "image/jpeg",
    ".jpg" => "image/jpeg",
    ".png" => "image/png",
    ".webp" => "image/webp"
  }

  @plain_text_exts ~w(
    .c .cc .conf .cpp .css .csv .ex .exs .go .heex .html .js .json .jsx .log .md .markdown
    .py .rb .rs .sh .sql .svg .toml .ts .tsx .txt .xml .yaml .yml
  )

  # Bytes are owner-authorized, root-confined by FileAccess, and emitted with
  # allowlisted content types plus nosniff so workspace HTML/SVG cannot execute.
  # sobelow_skip ["XSS.SendResp", "XSS.ContentType"]
  def show(conn, %{"id" => workspace_id, "path" => path_parts}) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-content-type-options", "nosniff")

    rel_path = Enum.join(path_parts, "/")

    with {:ok, workspace} <- authorize(conn, workspace_id),
         {:ok, loc} <- Workspaces.safe_host_loc(workspace),
         {:ok, %{type: :regular, size: size}} <- FileAccess.stat(loc, rel_path),
         :ok <- check_size(size),
         {:ok, bytes} <- FileAccess.read(loc, rel_path) do
      {content_type, charset} = content_type_for(rel_path)

      conn
      |> put_resp_content_type(content_type, charset)
      |> send_resp(200, bytes)
    else
      :too_large ->
        conn |> put_status(413) |> text("file too large")

      _ ->
        conn |> put_status(404) |> text("not found")
    end
  end

  defp authorize(conn, workspace_id) do
    viewer = conn.assigns[:current_user]
    auth = viewer && Map.get(viewer, :email)

    case Workspaces.get(workspace_id, auth) do
      {:ok, workspace} ->
        if Workspaces.viewer_terminal_owner?(workspace, viewer || %{}),
          do: {:ok, workspace},
          else: :forbidden

      _ ->
        :forbidden
    end
  end

  defp check_size(nil), do: :ok
  defp check_size(size) when is_integer(size) and size <= @max_file_bytes, do: :ok
  defp check_size(_), do: :too_large

  defp content_type_for(path) do
    ext = path |> Path.extname() |> String.downcase()

    cond do
      Map.has_key?(@raster_image_types, ext) ->
        {Map.fetch!(@raster_image_types, ext), nil}

      ext in @plain_text_exts ->
        {"text/plain", "utf-8"}

      true ->
        {"application/octet-stream", nil}
    end
  end
end
