defmodule CaseinWeb.LiveDiffMeasureTest do
  use ExUnit.Case, async: true

  alias CaseinWeb.LiveDiffMeasure
  alias CaseinWeb.LiveDiffMeasure.Serializer
  alias Phoenix.Socket.Message
  alias Phoenix.Socket.Reply

  setup do
    previous = Application.get_env(:casein, :live_diff_measure)
    Application.put_env(:casein, :live_diff_measure, true)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:casein, :live_diff_measure)
      else
        Application.put_env(:casein, :live_diff_measure, previous)
      end
    end)

    :ok
  end

  describe "rank_changed/2" do
    test "ranks dirty assign keys by term byte size, largest first" do
      assigns = %{
        small: :ok,
        medium: String.duplicate("m", 200),
        large: String.duplicate("L", 5_000),
        __changed__: %{small: true, medium: true, large: true}
      }

      changed = assigns.__changed__
      {total, ranked} = LiveDiffMeasure.rank_changed(assigns, changed)

      assert total > 5_000
      assert Enum.map(ranked, & &1.key) == [:large, :medium, :small]
      assert hd(ranked).bytes > Enum.at(ranked, 1).bytes
      assert Enum.at(ranked, 1).bytes > Enum.at(ranked, 2).bytes
    end

    test "empty changed map yields zero" do
      assert {0, []} = LiveDiffMeasure.rank_changed(%{a: 1}, %{})
    end
  end

  describe "classify_message/1" do
    test "measures live diff pushes" do
      msg = %Message{
        topic: "lv:phx-test",
        event: "diff",
        payload: %{"0" => "hello", "c" => %{}},
        ref: nil,
        join_ref: "1"
      }

      assert {:measure, "diff_push", "diff", _} = LiveDiffMeasure.classify_message(msg)
    end

    test "measures phx_reply that carries a diff" do
      msg = %Message{
        topic: "lv:phx-test",
        event: "phx_reply",
        payload: %{status: :ok, response: %{diff: %{"0" => "x"}}},
        ref: "2",
        join_ref: "1"
      }

      assert {:measure, "reply_diff", "phx_reply", _} = LiveDiffMeasure.classify_message(msg)
    end

    test "skips non-live topics and non-diff events" do
      assert :skip =
               LiveDiffMeasure.classify_message(%Message{
                 topic: "room:lobby",
                 event: "diff",
                 payload: %{},
                 ref: nil,
                 join_ref: nil
               })

      assert :skip =
               LiveDiffMeasure.classify_message(%Message{
                 topic: "lv:phx-test",
                 event: "e",
                 payload: %{},
                 ref: nil,
                 join_ref: nil
               })
    end
  end

  describe "Serializer" do
    test "encode! of a live diff emits wire telemetry with positive payload_bytes" do
      handler_id = "live-diff-wire-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:casein, :live_view, :diff_wire],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:wire, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      msg = %Message{
        topic: "lv:phx-measure",
        event: "diff",
        payload: %{
          "0" => String.duplicate("row-", 50),
          "1" => String.duplicate("cell-", 80),
          "c" => %{"1" => %{"0" => "pane-data-blob"}}
        },
        ref: nil,
        join_ref: "jr1"
      }

      encoded = Serializer.encode!(msg)
      assert match?({:socket_push, :text, _}, encoded)
      bytes = LiveDiffMeasure.iodata_bytes(encoded)
      assert bytes > 100

      assert_receive {:wire, [:casein, :live_view, :diff_wire], measurements, metadata}
      assert measurements.payload_bytes == bytes
      assert measurements.count == 1
      assert metadata.kind == "diff_push"
      assert metadata.event == "diff"
    end

    test "encode! of a reply with diff measures reply_diff kind" do
      handler_id = "live-diff-reply-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:casein, :live_view, :diff_wire],
        fn _e, m, meta, _ -> send(test_pid, {:wire, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      reply = %Reply{
        topic: "lv:phx-measure",
        status: :ok,
        payload: %{diff: %{"0" => String.duplicate("x", 200)}},
        ref: "r1",
        join_ref: "j1"
      }

      _ = Serializer.encode!(reply)
      assert_receive {:wire, measurements, metadata}
      assert measurements.payload_bytes > 200
      assert metadata.kind == "reply_diff"
    end

    test "disabled config emits nothing" do
      Application.put_env(:casein, :live_diff_measure, false)
      handler_id = "live-diff-off-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:casein, :live_view, :diff_wire],
        fn _, m, meta, _ -> send(test_pid, {:wire, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      msg = %Message{
        topic: "lv:phx-measure",
        event: "diff",
        payload: %{"0" => "x"},
        ref: nil,
        join_ref: "1"
      }

      _ = Serializer.encode!(msg)
      refute_receive {:wire, _, _}, 50
    end
  end

  describe "after_render probe" do
    test "emits changed_assigns telemetry ranked by term size" do
      handler_id = "live-diff-assigns-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:casein, :live_view, :changed_assigns],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:assigns, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      socket = %Phoenix.LiveView.Socket{
        view: CaseinWeb.WorkspaceLive.Show,
        assigns: %{
          __changed__: %{pane_data: true, focused_pane_id: true, tmux_window_tabs: true},
          pane_data: %{String.duplicate("p", 1000) => true},
          focused_pane_id: "%3",
          tmux_window_tabs: Enum.map(1..20, &%{id: "w#{&1}", name: "win-#{&1}"})
        }
      }

      assert %Phoenix.LiveView.Socket{} = LiveDiffMeasure.after_render(socket)

      assert_receive {:assigns, [:casein, :live_view, :changed_assigns], measurements, metadata}
      assert measurements.changed_count == 3
      assert measurements.payload_bytes > 0
      assert metadata.view =~ "WorkspaceLive.Show"
      assert is_list(metadata.top_keys)

      assert :pane_data in metadata.top_keys or
               hd(metadata.top_keys) in [:pane_data, :tmux_window_tabs]
    end
  end
end
