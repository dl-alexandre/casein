defmodule DevIdeWeb.PreviewRecordingControllerTest do
  use DevIdeWeb.ConnCase, async: false

  defmodule OwnedSource do
    alias DevIDE.Workspace
    def get(id, _auth), do: {:ok, %Workspace{id: id, name: id, user: "owner", status: :running}}
  end

  setup do
    artifacts = Path.join(System.tmp_dir!(), "rec-ctl-art-#{System.unique_integer([:positive])}")
    recordings = Path.join(System.tmp_dir!(), "rec-ctl-tmp-#{System.unique_integer([:positive])}")
    prev_art = Application.get_env(:dev_ide, :preview_artifacts_root)
    prev_rec = Application.get_env(:dev_ide, :preview_recordings_root)
    prev_source = Application.get_env(:dev_ide, :workspace_source)
    prev_fa = Application.get_env(:dev_ide, :forward_auth)

    Application.put_env(:dev_ide, :preview_artifacts_root, artifacts)
    Application.put_env(:dev_ide, :preview_recordings_root, recordings)
    Application.put_env(:dev_ide, :workspace_source, OwnedSource)
    Application.put_env(:dev_ide, :forward_auth, true)

    on_exit(fn ->
      File.rm_rf(artifacts)
      File.rm_rf(recordings)
      restore(:preview_artifacts_root, prev_art)
      restore(:preview_recordings_root, prev_rec)
      restore(:workspace_source, prev_source)
      restore(:forward_auth, prev_fa)
    end)

    :ok
  end

  test "owner can stream chunks and finalize into a servable webm", %{conn: conn} do
    ws = "ws-rec"
    rec = "rec-one"

    post_chunk(conn, ws, rec, 0, "AAA")
    post_chunk(conn, ws, rec, 1, "BBB")

    conn = conn |> owner() |> post("/preview-recordings/#{ws}/#{rec}/finalize")
    body = json_response(conn, 200)

    assert body["ok"] == true
    assert body["url"] == "/preview-artifacts/#{ws}/#{rec}.webm"

    artifacts = Application.get_env(:dev_ide, :preview_artifacts_root)
    assert File.read!(Path.join([artifacts, ws, "#{rec}.webm"])) == "AAABBB"
  end

  test "a non-owner is refused with 404", %{conn: conn} do
    conn =
      conn
      |> as("intruder@example.com")
      |> put_csrf()
      |> put_req_header("content-type", "application/octet-stream")
      |> post("/preview-recordings/ws-rec/rec-x/chunk?seq=0", "AAA")

    assert json_response(conn, 404)["error"] == "not found"
  end

  defp post_chunk(conn, ws, rec, seq, body) do
    conn =
      conn
      |> owner()
      |> put_req_header("content-type", "application/octet-stream")
      |> post("/preview-recordings/#{ws}/#{rec}/chunk?seq=#{seq}", body)

    assert json_response(conn, 200)["ok"] == true
  end

  defp owner(conn), do: conn |> as("owner@example.com") |> put_csrf()

  defp as(conn, email), do: put_req_header(conn, "x-auth-request-email", email)

  defp put_csrf(conn) do
    conn = Plug.Test.init_test_session(conn, %{})
    token = Plug.CSRFProtection.get_csrf_token()
    put_req_header(conn, "x-csrf-token", token)
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)
end
