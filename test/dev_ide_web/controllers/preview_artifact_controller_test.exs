defmodule DevIdeWeb.PreviewArtifactControllerTest do
  use DevIdeWeb.ConnCase, async: false

  alias DevIDE.Previews.Artifacts

  # Fake workspace source returning a workspace owned by "owner" for any id, so
  # the controller's ownership gate can be exercised without the manager backend.
  defmodule OwnedSource do
    alias DevIDE.Workspace
    def get(id, _auth), do: {:ok, %Workspace{id: id, name: id, user: "owner", status: :running}}
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "preview-artifacts-test-#{System.unique_integer([:positive])}")

    previous = Application.get_env(:dev_ide, :preview_artifacts_root)
    prev_source = Application.get_env(:dev_ide, :workspace_source)
    prev_fa = Application.get_env(:dev_ide, :forward_auth)

    Application.put_env(:dev_ide, :preview_artifacts_root, root)
    Application.put_env(:dev_ide, :workspace_source, OwnedSource)
    # Enable forward-auth so identity comes from the X-Auth-Request-Email header.
    Application.put_env(:dev_ide, :forward_auth, true)

    on_exit(fn ->
      File.rm_rf(root)
      restore(:preview_artifacts_root, previous)
      restore(:workspace_source, prev_source)
      restore(:forward_auth, prev_fa)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)

  defp as(conn, email), do: put_req_header(conn, "x-auth-request-email", email)

  test "serves raw artifact PNG to the workspace owner", %{conn: conn} do
    path = Artifacts.store_png!("ws-preview-fit", 1, png_bytes())

    conn = conn |> as("owner@example.com") |> get(path)

    assert response(conn, 200) == png_bytes()
    assert get_resp_header(conn, "content-type") == ["image/png; charset=utf-8"]
  end

  test "serves fitted preview artifact HTML without horizontal overflow", %{conn: conn} do
    path = Artifacts.store_png!("ws-preview-fit", 2, png_bytes())

    conn = conn |> as("owner@example.com") |> get(path <> "?fit=preview")
    html = html_response(conn, 200)

    assert html =~ ~s(<img src="#{path}" alt="Preview snapshot">)
    assert html =~ "overflow-x: hidden"
    assert html =~ "width: 100%"
    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
  end

  test "escapes artifact paths in fitted preview HTML attributes", %{conn: conn} do
    {:ok, path} =
      DevIDE.Previews.Storage.put(
        "ws-preview-fit",
        ~s(bad"onerror="alert),
        "png",
        {:bytes, png_bytes()}
      )

    conn = conn |> as("owner@example.com") |> get(path <> "?fit=preview")
    html = html_response(conn, 200)

    refute html =~ ~s(src="#{path}")
    assert html =~ ~s(src="/preview-artifacts/ws-preview-fit/bad&quot;onerror=&quot;alert.png")
  end

  test "serves a recording webm with a video content type", %{conn: conn} do
    path = store_webm!("ws-preview-fit", "recone", "WEBMDATA")

    conn = conn |> as("owner@example.com") |> get(path)

    assert response(conn, 200) == "WEBMDATA"
    assert get_resp_header(conn, "content-type") == ["video/webm; charset=utf-8"]
  end

  test "wraps a recording in a <video> playback page", %{conn: conn} do
    path = store_webm!("ws-preview-fit", "rectwo", "WEBMDATA")

    conn = conn |> as("owner@example.com") |> get(path <> "?fit=playback")
    html = html_response(conn, 200)

    assert html =~ ~s(<video src="#{path}")
    assert html =~ "controls"
    refute html =~ " loop"
    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
  end

  test "wraps a recording in a looping playback page when requested", %{conn: conn} do
    path = store_webm!("ws-preview-fit", "recthree", "WEBMDATA")

    conn = conn |> as("owner@example.com") |> get(path <> "?fit=playback&loop=1")
    html = html_response(conn, 200)

    assert html =~ ~s(<video src="#{path}")
    assert html =~ "playsinline loop"
    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
  end

  test "serves preview artifacts to any authenticated peer (flat peer model)", %{conn: conn} do
    path = Artifacts.store_png!("ws-preview-fit", 3, png_bytes())

    # Peers share the same access tier as the workspace owner once authenticated.
    conn = conn |> as("peer@example.com") |> get(path)

    assert response(conn, 200)
  end

  defp store_webm!(workspace_id, id, bytes) do
    {:ok, ref} = DevIDE.Previews.Storage.put(workspace_id, id, "webm", {:bytes, bytes})
    ref
  end

  defp png_bytes do
    Base.decode64!(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGA" <>
        "WjR9awAAAABJRU5ErkJggg=="
    )
  end
end
