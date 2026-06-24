defmodule DevIdeWeb.PreviewArtifactController do
  @moduledoc """
  Serves saved preview artifacts (PNG snapshots and webm recordings) for a
  workspace, path-validated via `DevIDE.Previews.Artifacts.safe_path!/2`. With
  `?fit=preview` it wraps a snapshot in a responsive HTML page for iframe
  embedding, `?fit=playback` wraps a recording in a `<video>` page; otherwise it
  streams the raw bytes with a content type derived from the extension.
  """
  use DevIdeWeb, :controller

  alias DevIDE.Workspaces

  def show(conn, %{"workspace_id" => workspace_id, "filename" => filename, "fit" => "preview"}) do
    with {:ok, _workspace} <- authorize(conn, workspace_id) do
      _path = DevIDE.Previews.Artifacts.safe_path!(workspace_id, filename)
      image_path = conn.request_path

      html = """
      <!doctype html>
      <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            html,
            body {
              margin: 0;
              min-width: 0;
              width: 100%;
              min-height: 100%;
              overflow-x: hidden;
              background: #fff;
            }

            img {
              display: block;
              width: 100%;
              max-width: 100%;
              height: auto;
            }
          </style>
        </head>
        <body>
          <img src="#{image_path}" alt="Preview snapshot">
        </body>
      </html>
      """

      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, html)
    else
      :forbidden -> conn |> put_status(404) |> text("not found")
    end
  rescue
    _ ->
      conn |> put_status(404) |> text("not found")
  end

  def show(conn, %{"workspace_id" => workspace_id, "filename" => filename, "fit" => "playback"}) do
    with {:ok, _workspace} <- authorize(conn, workspace_id) do
      _path = DevIDE.Previews.Artifacts.safe_path!(workspace_id, filename)
      video_path = conn.request_path

      html = """
      <!doctype html>
      <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            html,
            body {
              margin: 0;
              width: 100%;
              height: 100%;
              background: #000;
            }

            video {
              display: block;
              width: 100%;
              height: 100%;
              object-fit: contain;
            }
          </style>
        </head>
        <body>
          <video src="#{video_path}" controls autoplay muted playsinline></video>
        </body>
      </html>
      """

      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, html)
    else
      :forbidden -> conn |> put_status(404) |> text("not found")
    end
  rescue
    _ ->
      conn |> put_status(404) |> text("not found")
  end

  def show(conn, %{"workspace_id" => workspace_id, "filename" => filename}) do
    with {:ok, _workspace} <- authorize(conn, workspace_id) do
      path = DevIDE.Previews.Artifacts.safe_path!(workspace_id, filename)

      conn
      |> put_resp_content_type(content_type_for(filename))
      |> send_file(200, path)
    else
      :forbidden -> conn |> put_status(404) |> text("not found")
    end
  rescue
    _ ->
      conn |> put_status(404) |> text("not found")
  end

  defp content_type_for(filename) do
    case filename |> Path.extname() |> String.downcase() do
      ".webm" -> "video/webm"
      ".mp4" -> "video/mp4"
      _ -> "image/png"
    end
  end

  # Identity comes from ForwardAuth, but the artifact endpoint must still verify
  # the viewer owns the workspace before serving its screenshots — otherwise any
  # authenticated user can read another user's snapshots by enumerating ids.
  # Mirrors PreviewProxyController.load_authorized/2. Returns 404 (via :forbidden
  # at the call site) rather than 403 so we don't leak which workspace ids exist.
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
end
