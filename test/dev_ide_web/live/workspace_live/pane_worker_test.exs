defmodule CaseinWeb.WorkspaceLive.PaneWorkerTest do
  use Casein.TestCase, async: false

  alias Casein.Test.FakeTerminalSession
  alias Casein.Test.FakeTerminals
  alias CaseinWeb.WorkspaceLive.PaneWorker

  defp start_worker do
    start_supervised!(
      {PaneWorker,
       parent: self(),
       pane_id: "pane-gen-1",
       tmux_session: "devide_test_pane_worker_gen",
       backend: :shared_session,
       session_module: FakeTerminalSession,
       workspace_key: "ws-key-gen",
       session_sid: "sid-gen",
       loc: {:fake, self()},
       cols: 20,
       rows: 5}
    )
  end

  test "frames carry the session content generation when payloads have one" do
    worker = start_worker()

    send(worker, {:terminal_payload, :data, %{data: "hi", gen: 7}})

    assert_receive {:pane_frame, "pane-gen-1", %{content_gen: 7}}, 1_000
  end

  test "frames omit content_gen when the backend does not provide one" do
    worker = start_worker()

    send(worker, {:terminal_payload, :data, %{data: "hi"}})

    assert_receive {:pane_frame, "pane-gen-1", payload}, 1_000
    refute Map.has_key?(payload, :content_gen)
  end

  test "later payload generations replace earlier ones on subsequent frames" do
    worker = start_worker()

    send(worker, {:terminal_payload, :data, %{data: "a", gen: 1}})
    assert_receive {:pane_frame, "pane-gen-1", %{content_gen: 1}}, 1_000

    send(worker, {:terminal_payload, :data, %{data: "b", gen: 2}})
    assert_receive {:pane_frame, "pane-gen-1", %{content_gen: 2}}, 1_000
  end

  test "empty incremental frames are skipped without advancing the visible frame stream" do
    worker = start_worker()
    handler_id = "pane-worker-frame-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:casein, :terminal, :pane_worker, :frame],
      fn event, measurements, metadata, _cfg ->
        send(test_pid, {:pane_worker_frame, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    send(worker, {:terminal_payload, :data, %{data: "a", gen: 1}})
    assert_receive {:pane_frame, "pane-gen-1", %{frame_seq: 0, frame_epoch: 1}}, 1_000

    assert_receive {:pane_worker_frame, [:casein, :terminal, :pane_worker, :frame],
                    %{changed_rows: 5}, %{status: :sent, frame_seq: 0, frame_epoch: 1}},
                   1_000

    send(worker, {:terminal_payload, :data, %{data: "", gen: 2}})

    assert_receive {:pane_worker_frame, [:casein, :terminal, :pane_worker, :frame],
                    %{changed_rows: 0}, %{status: :skipped, frame_seq: 1, frame_epoch: 1}},
                   1_000

    refute_receive {:pane_frame, "pane-gen-1", _}, 100

    send(worker, {:terminal_payload, :data, %{data: "b", gen: 3}})

    assert_receive {:pane_frame, "pane-gen-1", %{frame_seq: 1, frame_epoch: 1, content_gen: 3}},
                   1_000
  end

  test "flush scheduling stays low latency for small output and batches large output" do
    worker = start_worker()
    handler_id = "pane-worker-flush-schedule-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:casein, :terminal, :pane_worker, :flush_schedule],
      fn event, measurements, metadata, _cfg ->
        send(test_pid, {:flush_schedule, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    send(worker, {:terminal_payload, :data, %{data: "x", gen: 1}})

    assert_receive {:flush_schedule, [:casein, :terminal, :pane_worker, :flush_schedule],
                    %{interval_ms: 8, pending_bytes: 1},
                    %{pane_id: "pane-gen-1", burst?: false, burst_frames: 0}},
                   1_000

    assert_receive {:pane_frame, "pane-gen-1", _}, 1_000

    large = String.duplicate("y", 4 * 1024)
    send(worker, {:terminal_payload, :data, %{data: large, gen: 2}})

    assert_receive {:flush_schedule, [:casein, :terminal, :pane_worker, :flush_schedule],
                    %{interval_ms: 24, pending_bytes: 4096},
                    %{pane_id: "pane-gen-1", burst?: true}},
                   1_000
  end

  test "session_owner resize from a passive viewer does not reach the owner" do
    {:ok, worker} =
      PaneWorker.start_link(
        parent: self(),
        pane_id: "pane-passive-resize",
        tmux_session: "ignored",
        workspace_id: "ws-passive",
        workspace_key: "alpha",
        session_sid: "u-passive",
        loc: {:local, "/tmp"},
        backend: :session_owner,
        terminal_module: FakeTerminals,
        test_owner: self(),
        cols: 80,
        rows: 24
      )

    assert_receive {:fake_owner_attached, owner_pid, ^worker, _, _, _}, 1_000
    Process.unlink(worker)

    :ok = PaneWorker.set_active(worker, false)
    :ok = PaneWorker.resize(worker, 60, 20)
    refute_receive {:fake_owner_resize, ^owner_pid, _, _}, 100
    assert_receive {:pane_frame, "pane-passive-resize", _}, 1_000

    :ok = PaneWorker.set_active(worker, true)
    :ok = PaneWorker.resize(worker, 132, 44)
    assert_receive {:fake_owner_resize, ^owner_pid, 132, 44}, 1_000

    ref = Process.monitor(worker)
    assert :ok = GenServer.stop(worker, :normal)
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}
  end

  describe "terminal file links" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "pane-worker-links-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(root, "lib"))
      File.write!(Path.join(root, "lib/foo.ex"), "defmodule Foo do\nend\n")

      Casein.FilePanes.LinkResolver.clear_cache()

      on_exit(fn ->
        Casein.FilePanes.LinkResolver.clear_cache()
        File.rm_rf(root)
      end)

      {:ok, root: root}
    end

    defp start_link_worker(root, pane_id) do
      {:ok, worker} =
        PaneWorker.start_link(
          parent: self(),
          pane_id: pane_id,
          tmux_session: "ignored",
          workspace_id: "ws-links",
          workspace_key: "alpha",
          session_sid: "u-links",
          loc: {:local, root},
          backend: :session_owner,
          terminal_module: FakeTerminals,
          test_owner: self(),
          cols: 80,
          rows: 6
        )

      assert_receive {:fake_owner_attached, _owner_pid, ^worker, _, _, _}, 1_000
      Process.unlink(worker)
      worker
    end

    test "frames carry validated file_links for changed rows only", %{root: root} do
      worker = start_link_worker(root, "pane-links")

      handler_id = "pane-worker-link-scan-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:casein, :terminal, :link_scan],
        fn _event, measurements, metadata, _cfg ->
          send(test_pid, {:link_scan, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      send(worker, {:terminal_payload, :data, %{data: "lib/foo.ex:12 and lib/missing.ex:9"}})

      assert_receive {:pane_frame, "pane-links", %{file_links: links}}, 1_000
      assert [%{row: 0, path: "lib/foo.ex", line: 12, from: 0, to: 12}] = links

      assert_receive {:link_scan, measurements, %{id: "ghostty-pane-links"}}, 1_000
      assert measurements.candidates == 2
      assert measurements.links == 1
      assert is_integer(measurements.duration_us)

      # Output on another row that repaints only that row: the incremental
      # frame's file_links cover the changed row, not row 0 again.
      send(worker, {:terminal_payload, :data, %{data: "\r\nmix.exs ok"}})

      assert_receive {:pane_frame, "pane-links", payload}, 1_000

      case payload do
        %{file_links: more_links} ->
          assert Enum.all?(more_links, &(&1.row != 0))

        _ ->
          # mix.exs does not exist under this root — no links attached.
          refute Map.has_key?(payload, :file_links)
      end

      GenServer.stop(worker, :normal)
    end

    test "frames omit file_links when nothing on the changed rows resolves", %{root: root} do
      worker = start_link_worker(root, "pane-nolinks")

      send(worker, {:terminal_payload, :data, %{data: "hello lib/absent.ex world"}})

      assert_receive {:pane_frame, "pane-nolinks", payload}, 1_000
      refute Map.has_key?(payload, :file_links)

      GenServer.stop(worker, :normal)
    end

    test "workers without a local loc never scan" do
      worker = start_worker()

      send(worker, {:terminal_payload, :data, %{data: "lib/foo.ex:12"}})

      assert_receive {:pane_frame, "pane-gen-1", payload}, 1_000
      refute Map.has_key?(payload, :file_links)
    end

    test "frames carry web_links for changed rows", %{root: root} do
      worker = start_link_worker(root, "pane-weblinks")

      send(worker, {:terminal_payload, :data, %{data: "open https://example.com/x now"}})

      assert_receive {:pane_frame, "pane-weblinks", %{web_links: links}}, 1_000
      assert [%{row: 0, url: "https://example.com/x", from: 5, to: 25}] = links

      GenServer.stop(worker, :normal)
    end

    test "web_links need no local loc — remote sessions still linkify URLs" do
      worker = start_worker()

      send(worker, {:terminal_payload, :data, %{data: "see http://a.test/y"}})

      assert_receive {:pane_frame, "pane-gen-1", payload}, 1_000
      assert [%{row: 0, url: "http://a.test/y"}] = payload.web_links
      # A non-local worker linkifies URLs but never file paths.
      refute Map.has_key?(payload, :file_links)

      GenServer.stop(worker, :normal)
    end

    test "frames omit web_links when the changed rows carry no URL", %{root: root} do
      worker = start_link_worker(root, "pane-nourls")

      send(worker, {:terminal_payload, :data, %{data: "just some plain text"}})

      assert_receive {:pane_frame, "pane-nourls", payload}, 1_000
      refute Map.has_key?(payload, :web_links)

      GenServer.stop(worker, :normal)
    end
  end

  test "terminal_owner_size resizes the local grid without owner_resize" do
    {:ok, worker} =
      PaneWorker.start_link(
        parent: self(),
        pane_id: "pane-owner-size",
        tmux_session: "ignored",
        workspace_id: "ws-owner-size",
        workspace_key: "alpha",
        session_sid: "u-owner-size",
        loc: {:local, "/tmp"},
        backend: :session_owner,
        terminal_module: FakeTerminals,
        test_owner: self(),
        cols: 80,
        rows: 24
      )

    assert_receive {:fake_owner_attached, owner_pid, ^worker, _, _, _}, 1_000
    Process.unlink(worker)

    send(worker, {:terminal_owner_size, 200, 60})
    refute_receive {:fake_owner_resize, ^owner_pid, _, _}, 100
    assert_receive {:pane_frame, "pane-owner-size", _}, 1_000

    ref = Process.monitor(worker)
    assert :ok = GenServer.stop(worker, :normal)
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}
  end
end
