defmodule DevIdeWeb.PreviewArtifactControllerTest do
  use DevIdeWeb.ConnCase

  alias DevIDE.Previews.Artifacts

  setup do
    root =
      Path.join(System.tmp_dir!(), "preview-artifacts-test-#{System.unique_integer([:positive])}")

    previous = Application.get_env(:dev_ide, :preview_artifacts_root)
    Application.put_env(:dev_ide, :preview_artifacts_root, root)

    on_exit(fn ->
      File.rm_rf(root)

      if previous do
        Application.put_env(:dev_ide, :preview_artifacts_root, previous)
      else
        Application.delete_env(:dev_ide, :preview_artifacts_root)
      end
    end)

    :ok
  end

  test "serves raw artifact PNG", %{conn: conn} do
    path = Artifacts.store_png!("ws-preview-fit", 1, png_bytes())

    conn = get(conn, path)

    assert response(conn, 200) == png_bytes()
    assert get_resp_header(conn, "content-type") == ["image/png; charset=utf-8"]
  end

  test "serves fitted preview artifact HTML without horizontal overflow", %{conn: conn} do
    path = Artifacts.store_png!("ws-preview-fit", 2, png_bytes())

    conn = get(conn, path <> "?fit=preview")
    html = html_response(conn, 200)

    assert html =~ ~s(<img src="#{path}" alt="Preview snapshot">)
    assert html =~ "overflow-x: hidden"
    assert html =~ "width: 100%"
    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
  end

  defp png_bytes do
    Base.decode64!(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGA" <>
        "WjR9awAAAABJRU5ErkJggg=="
    )
  end
end
