defmodule DevIDE.Previews.FileServerTest do
  use DevIDE.DataCase, async: false

  alias DevIDE.Previews.FileServer
  alias DevIDE.Workspaces

  setup do
    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_idle = Application.get_env(:dev_ide, :file_server_idle_ms)
    # Keep idle high so tests are not interrupted by the belt-and-suspenders timer.
    Application.put_env(:dev_ide, :file_server_idle_ms, 60_000)

    on_exit(fn ->
      restore(:workspaces_root, prev_root)
      restore(:file_server_idle_ms, prev_idle)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)

  defp seed_workspace! do
    root = DevIDE.TmpWorkspace.root!("file-server")
    path = Path.join(root, "ws")
    File.mkdir_p!(path)
    Application.put_env(:dev_ide, :workspaces_root, root)
    {:ok, workspace} = Workspaces.attach_folder(path)
    {path, workspace}
  end

  defp get!(port, path) do
    url = "http://127.0.0.1:#{port}/#{path}"
    Req.get!(url, retry: false, receive_timeout: 2_000)
  end

  test "ensure_started assigns an ephemeral loopback port and serves files" do
    {ws_root, workspace} = seed_workspace!()
    File.write!(Path.join(ws_root, "shot.png"), <<137, 80, 78, 71>>)
    File.write!(Path.join(ws_root, "note.txt"), "hello-static")

    assert {:ok, port} = FileServer.ensure_started(workspace)
    assert is_integer(port) and port > 0 and port < 65_536

    # Reuse is idempotent — same port.
    assert {:ok, ^port} = FileServer.ensure_started(workspace)

    png = get!(port, "shot.png")
    assert png.status == 200
    assert png.body == <<137, 80, 78, 71>>

    assert png.headers["content-type"] == ["image/png"] or
             List.keyfind(png.headers, "content-type", 0)
             |> elem(1)
             |> String.starts_with?("image/png")

    assert header(png, "x-content-type-options") == "nosniff"
    assert header(png, "cache-control") == "no-store"

    txt = get!(port, "note.txt")
    assert txt.status == 200
    assert txt.body == "hello-static"

    assert header(txt, "content-type") in [
             "application/octet-stream",
             "application/octet-stream; charset=utf-8"
           ] or
             String.starts_with?(header(txt, "content-type") || "", "application/octet-stream")

    FileServer.stop(workspace)
  end

  test "serves identity even when the client offers gzip (proxy forwards bytes verbatim)" do
    {ws_root, workspace} = seed_workspace!()
    svg = ~s(<svg xmlns="http://www.w3.org/2000/svg"><text>#219</text></svg>)
    File.write!(Path.join(ws_root, "pic.svg"), svg)

    assert {:ok, port} = FileServer.ensure_started(workspace)

    # A browser sends `Accept-Encoding: gzip`. If Bandit compressed, the preview
    # proxy (decode_body: false) would relay gzip bytes the iframe parses as
    # text — rendering the SVG as an "Encoding error" / binary garbage. `raw:
    # true` keeps Req from decompressing, so we see exactly what the proxy would.
    resp =
      Req.get!("http://127.0.0.1:#{port}/pic.svg",
        retry: false,
        receive_timeout: 2_000,
        raw: true,
        headers: [{"accept-encoding", "gzip, deflate, br"}]
      )

    assert resp.status == 200
    assert header(resp, "content-encoding") in [nil, "identity"]
    # Not a gzip stream (magic 0x1f 0x8b) — the real file bytes travel through.
    refute match?(<<0x1F, 0x8B, _::binary>>, resp.body)
    assert resp.body == svg
    assert header(resp, "content-type") == "image/svg+xml"

    FileServer.stop(workspace)
  end

  test "path traversal and symlink escape are refused with 404" do
    {ws_root, workspace} = seed_workspace!()
    File.write!(Path.join(ws_root, "ok.txt"), "inside")

    outside =
      Path.join(System.tmp_dir!(), "file-server-out-#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret"), "nope")
    File.ln_s!(outside, Path.join(ws_root, "escape_link"))
    on_exit(fn -> File.rm_rf!(outside) end)

    assert {:ok, port} = FileServer.ensure_started(workspace)

    # ../ traversal — Bandit/HTTP will normalize or the plug/FileAccess refuses.
    trav =
      Req.get!("http://127.0.0.1:#{port}/../#{Path.basename(outside)}/secret",
        retry: false,
        receive_timeout: 2_000,
        redirect: false
      )

    assert trav.status in [404, 400]

    # Explicit percent-encoded traversal payload.
    enc =
      Req.get!(
        "http://127.0.0.1:#{port}/" <> URI.encode("../#{Path.basename(outside)}/secret"),
        retry: false,
        receive_timeout: 2_000,
        redirect: false
      )

    assert enc.status == 404

    # Symlink that escapes the workspace root.
    link =
      Req.get!("http://127.0.0.1:#{port}/escape_link/secret",
        retry: false,
        receive_timeout: 2_000
      )

    assert link.status == 404

    # Direct child still works.
    ok = get!(port, "ok.txt")
    assert ok.status == 200
    assert ok.body == "inside"

    FileServer.stop(workspace)
  end

  test "stop reaps the listener so the port is closed" do
    {_ws_root, workspace} = seed_workspace!()
    assert {:ok, port} = FileServer.ensure_started(workspace)
    assert {:ok, pid} = FileServer.whereis(workspace.id)
    ref = Process.monitor(pid)

    assert :ok = FileServer.stop(workspace)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
    refute Process.alive?(pid)

    # Port no longer accepts connections.
    assert {:error, _} =
             :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 500)
  end

  test "HTTP hits reset the idle timer so an open preview is not reaped mid-use" do
    {ws_root, workspace} = seed_workspace!()
    File.write!(Path.join(ws_root, "keep.png"), <<137, 80, 78, 71>>)
    # Short idle so the test stays fast, but wide enough that a single request
    # round-trip cannot race the timer.
    Application.put_env(:dev_ide, :file_server_idle_ms, 150)

    assert {:ok, port} = FileServer.ensure_started(workspace)
    assert {:ok, pid} = FileServer.whereis(workspace.id)
    ref = Process.monitor(pid)

    # Without HTTP activity the server would die by ~150ms. Hitting it every
    # ~60ms across several cycles proves the plug's touch cast resets the timer.
    for _ <- 1..5 do
      Process.sleep(60)
      assert get!(port, "keep.png").status == 200
      # Drain the :touch cast so the idle ref is definitely renewed before the
      # next sleep window.
      _ = :sys.get_state(pid)
      assert Process.alive?(pid)
    end

    # After the last hit, silence reaps the original process.
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 500
    refute Process.alive?(pid)
  end

  defp header(%Req.Response{headers: headers}, name) do
    name = String.downcase(name)

    case headers do
      %{} = map ->
        case Map.get(map, name) do
          [v | _] -> v
          v when is_binary(v) -> v
          _ -> nil
        end

      list when is_list(list) ->
        Enum.find_value(list, fn
          {k, v} -> if String.downcase(to_string(k)) == name, do: v
          _ -> nil
        end)
    end
  end
end
