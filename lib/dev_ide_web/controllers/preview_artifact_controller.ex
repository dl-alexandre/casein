defmodule DevIdeWeb.PreviewArtifactController do
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

  def show(conn, %{"workspace_id" => workspace_id, "filename" => filename}) do
    with {:ok, _workspace} <- authorize(conn, workspace_id) do
      path = DevIDE.Previews.Artifacts.safe_path!(workspace_id, filename)

      conn
      |> put_resp_content_type("image/png")
      |> send_file(200, path)
    else
      :forbidden -> conn |> put_status(404) |> text("not found")
    end
  rescue
    _ ->
      conn |> put_status(404) |> text("not found")
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
