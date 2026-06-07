defmodule DevIdeWeb.PreviewArtifactController do
  use DevIdeWeb, :controller

  def show(conn, %{"workspace_id" => workspace_id, "filename" => filename}) do
    path = DevIDE.Previews.Artifacts.safe_path!(workspace_id, filename)

    conn
    |> put_resp_content_type("image/png")
    |> send_file(200, path)
  rescue
    _ ->
      conn |> put_status(404) |> text("not found")
  end
end
