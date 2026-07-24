defmodule CaseinWeb.WorkspaceLive.Show.CodexEventsTest do
  # Codex.Store.MemoryAdapter is a process-global GenServer.
  use Casein.TestCase, async: false

  import Phoenix.Component, only: [assign: 2]

  alias Casein.Codex.Event
  alias Casein.Codex.Store
  alias CaseinWeb.WorkspaceLive.Show
  alias CaseinWeb.WorkspaceLive.Show.CodexEvents

  # Pure / memory-store: assign_defaults, disconnected open/subscribe,
  # select_thread, start_exec empty/unavailable, cancel_exec no-op,
  # invalid resolve_approval, delta buffer/flush, exec data/exit/event infos.
  # SKIPPED (ExecRun/Runtime brokers): successful start_exec, runtime resolve_approval.

  setup do
    Store.clear()
    :ok
  end

  defp socket(assigns \\ %{}) do
    ws_id = "ws-codex-#{System.unique_integer([:positive])}"

    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            flash: %{},
            workspace: %{id: ws_id},
            host_path: {:error, :not_set},
            current_user: %{id: "u-#{System.unique_integer([:positive])}"}
          },
          assigns
        )
    }
  end

  # assign_defaults overwrites panel keys — apply fixture overrides after it.
  defp panel(assigns \\ %{}) do
    socket()
    |> CodexEvents.assign_defaults()
    |> assign(assigns)
  end

  defp event(type, attrs) do
    context = %{
      workspace_id: attrs[:workspace_id] || "ws",
      runtime_id: attrs[:runtime_id] || "rt-1",
      transport: :app_server,
      sequence: attrs[:sequence] || 1
    }

    Event.new!(type, context,
      thread_id: attrs[:thread_id],
      payload: attrs[:payload] || %{},
      metadata: attrs[:metadata] || %{}
    )
  end

  test "assign_defaults seeds shared Notifications, History, and Run assigns" do
    s = CodexEvents.assign_defaults(socket())

    assert s.assigns.codex_loaded? == false
    assert s.assigns.codex_subscribed? == false
    assert s.assigns.codex_threads == []
    assert s.assigns.codex_approvals == []
    assert s.assigns.codex_pending_approval_count == 0
    assert s.assigns.codex_selected_thread_id == nil
    assert s.assigns.codex_timeline == []
    assert s.assigns.codex_live_delta == ""
    assert s.assigns.codex_delta_buffer == []
    assert s.assigns.codex_delta_timer == nil
    assert s.assigns.codex_exec_run == nil
    assert s.assigns.codex_error == nil
    assert is_struct(s.assigns.codex_exec_form, Phoenix.HTML.Form)
  end

  test "subscribe_once is a no-op when the socket is not connected" do
    s = panel()
    s2 = CodexEvents.subscribe_once(s)
    assert s2.assigns.codex_subscribed? == false
  end

  test "open is a no-op when the socket is not connected" do
    s = panel()
    s2 = CodexEvents.open(s)
    assert s2.assigns.codex_loaded? == false
  end

  test "after-mount agent setup subscribes outside History so global approvals stay live" do
    s = panel(%{tab: "terminal"})
    s = %{s | transport_pid: self()}

    assert {:noreply, s2} = Show.handle_info(:after_mount_agents, s)
    assert s2.assigns.codex_loaded?
    assert s2.assigns.codex_subscribed?
  end

  test "codex:select_thread selects a known thread and loads its timeline" do
    ws_id = "ws-codex-#{System.unique_integer([:positive])}"

    :ok =
      Store.record(
        event(:thread_started,
          workspace_id: ws_id,
          thread_id: "thr-1",
          runtime_id: "rt-a",
          sequence: 1,
          payload: %{title: "one"}
        )
      )

    :ok =
      Store.record(
        event(:agent_message_delta,
          workspace_id: ws_id,
          thread_id: "thr-1",
          runtime_id: "rt-a",
          sequence: 2,
          payload: %{delta: "hi"}
        )
      )

    s =
      socket(%{workspace: %{id: ws_id}})
      |> CodexEvents.assign_defaults()
      |> assign(
        codex_threads: [%{thread_id: "thr-1"}, %{thread_id: "thr-2"}],
        workspace: %{id: ws_id}
      )

    assert {:noreply, s2} =
             CodexEvents.handle_event("codex:select_thread", %{"thread-id" => "thr-1"}, s)

    assert s2.assigns.codex_selected_thread_id == "thr-1"
    assert s2.assigns.codex_live_delta == ""
    assert is_list(s2.assigns.codex_timeline)
    assert Enum.any?(s2.assigns.codex_timeline, &(&1.thread_id == "thr-1"))
  end

  test "codex:select_thread flashes when the thread is missing" do
    s = panel(%{codex_threads: [%{thread_id: "thr-1"}]})

    assert {:noreply, s2} =
             CodexEvents.handle_event("codex:select_thread", %{"thread-id" => "gone"}, s)

    assert s2.assigns.flash["error"] == "That Codex thread is no longer available."
    assert s2.assigns.codex_selected_thread_id == nil
  end

  test "codex:select_thread with a blank thread-id raises FunctionClauseError" do
    s = panel()

    assert_raise FunctionClauseError, fn ->
      CodexEvents.handle_event("codex:select_thread", %{"thread-id" => ""}, s)
    end
  end

  test "codex:resolve_approval with an invalid decision hits the nil else branch" do
    # decision_atom/1 returns nil; the with/else clause matches `nil` first
    # (shared with "no pending approval"), so the message is the pending one.
    s = panel(%{codex_approvals: []})

    assert {:noreply, s2} =
             CodexEvents.handle_event(
               "codex:resolve_approval",
               %{"approval-id" => "a1", "decision" => "maybe"},
               s
             )

    assert s2.assigns.flash["error"] == "Approval is no longer pending."
  end

  test "codex:resolve_approval for a missing pending approval flashes an error" do
    s =
      panel(%{
        codex_approvals: [%{id: "a1", status: "resolved", runtime_id: "rt"}]
      })

    assert {:noreply, s2} =
             CodexEvents.handle_event(
               "codex:resolve_approval",
               %{"approval-id" => "a1", "decision" => "accept"},
               s
             )

    assert s2.assigns.flash["error"] == "Approval is no longer pending."
  end

  test "codex:start_exec rejects an empty prompt" do
    s = panel(%{host_path: {:ok, "/tmp"}})

    assert {:noreply, s2} =
             CodexEvents.handle_event(
               "codex:start_exec",
               %{"codex_exec" => %{"prompt" => "   "}},
               s
             )

    assert s2.assigns.flash["error"] == "Enter a task for Codex."
  end

  test "codex:start_exec rejects when the workspace path is unavailable" do
    s = panel(%{host_path: {:error, :not_set}})

    assert {:noreply, s2} =
             CodexEvents.handle_event(
               "codex:start_exec",
               %{"codex_exec" => %{"prompt" => "list files"}},
               s
             )

    assert s2.assigns.flash["error"] == "Workspace path is unavailable."
  end

  test "codex:cancel_exec is a no-op without a running exec" do
    s = panel(%{codex_exec_run: nil})
    assert {:noreply, s2} = CodexEvents.handle_event("codex:cancel_exec", %{}, s)
    assert s2.assigns.codex_exec_run == nil
    assert s2.assigns.flash == %{}
  end

  test "codex:cancel_exec is a no-op for a non-running exec" do
    run = %{run_id: "r1", status: :exited}
    s = panel(%{codex_exec_run: run})
    assert {:noreply, s2} = CodexEvents.handle_event("codex:cancel_exec", %{}, s)
    assert s2.assigns.codex_exec_run == run
  end

  test "handle_info agent_message_delta buffers for the selected thread and arms a timer" do
    s =
      panel(%{
        tab: "history",
        codex_selected_thread_id: "thr-1",
        codex_delta_buffer: [],
        codex_delta_timer: nil
      })

    ev =
      event(:agent_message_delta,
        workspace_id: s.assigns.workspace.id,
        thread_id: "thr-1",
        payload: %{delta: "hello"}
      )

    assert {:noreply, s2} = CodexEvents.handle_info(ev, s)
    assert s2.assigns.codex_delta_buffer == ["hello"]
    assert is_reference(s2.assigns.codex_delta_timer)

    # A second delta while the timer is armed only grows the buffer.
    ev2 = %{ev | payload: %{delta: " world"}, sequence: 2}
    assert {:noreply, s3} = CodexEvents.handle_info(ev2, s2)
    assert s3.assigns.codex_delta_buffer == [" world", "hello"]
    assert s3.assigns.codex_delta_timer == s2.assigns.codex_delta_timer

    if is_reference(s2.assigns.codex_delta_timer),
      do: Process.cancel_timer(s2.assigns.codex_delta_timer)
  end

  test "handle_info agent_message_delta for another thread is ignored" do
    s =
      panel(%{
        tab: "history",
        codex_selected_thread_id: "thr-1",
        codex_delta_buffer: ["keep"],
        codex_delta_timer: nil
      })

    ev =
      event(:agent_message_delta,
        workspace_id: s.assigns.workspace.id,
        thread_id: "thr-other",
        payload: %{delta: "nope"}
      )

    assert {:noreply, s2} = CodexEvents.handle_info(ev, s)
    assert s2.assigns.codex_delta_buffer == ["keep"]
    assert s2.assigns.codex_delta_timer == nil
  end

  test "handle_info agent_message_delta stays dormant outside History" do
    s =
      panel(%{
        tab: "terminal",
        codex_selected_thread_id: "thr-1",
        codex_delta_buffer: [],
        codex_delta_timer: nil
      })

    ev =
      event(:agent_message_delta,
        workspace_id: s.assigns.workspace.id,
        thread_id: "thr-1",
        payload: %{delta: "hidden"}
      )

    assert {:noreply, s2} = CodexEvents.handle_info(ev, s)
    assert s2.assigns.codex_delta_buffer == []
    assert s2.assigns.codex_delta_timer == nil
  end

  test "approval events refresh the global projection outside History" do
    s = panel(%{tab: "terminal"})

    ev =
      event(:approval_requested,
        workspace_id: s.assigns.workspace.id,
        thread_id: "thr-approval",
        payload: %{
          approval_id: "approval-global",
          approval_kind: :command_execution,
          command: "mix test"
        }
      )

    assert :ok = Store.record(ev)
    assert {:noreply, s2} = CodexEvents.handle_info(ev, s)
    assert s2.assigns.codex_pending_approval_count == 1
    assert [%{id: "approval-global", status: "pending"}] = s2.assigns.codex_approvals
  end

  test "handle_info :flush_codex_deltas concatenates the buffer into live delta" do
    s =
      panel(%{
        codex_live_delta: "pre-",
        codex_delta_buffer: ["b", "a"],
        codex_delta_timer: make_ref()
      })

    assert {:noreply, s2} = CodexEvents.handle_info(:flush_codex_deltas, s)
    assert s2.assigns.codex_live_delta == "pre-ab"
    assert s2.assigns.codex_delta_buffer == []
    assert s2.assigns.codex_delta_timer == nil
  end

  test "handle_info :flush_codex_deltas retains only the last 32_000 live bytes" do
    tail = String.duplicate("x", 100)
    # live + flush would exceed the max — only the tail should remain.
    live = String.duplicate("y", 32_000)
    s = panel(%{codex_live_delta: live, codex_delta_buffer: [tail]})

    assert {:noreply, s2} = CodexEvents.handle_info(:flush_codex_deltas, s)
    assert byte_size(s2.assigns.codex_live_delta) == 32_000
    assert String.ends_with?(s2.assigns.codex_live_delta, tail)
  end

  test "handle_info {:codex_exec_event, ...} is a pure no-op" do
    s = panel()
    assert {:noreply, s2} = CodexEvents.handle_info({:codex_exec_event, "r1", :tick}, s)
    assert s2.assigns.codex_exec_run == nil
  end

  test "handle_info codex_exec_data updates stderr for the matching run" do
    s = panel(%{codex_exec_run: %{run_id: "r1", status: :running, stderr: ""}})

    assert {:noreply, s2} =
             CodexEvents.handle_info({:codex_exec_data, "r1", :stderr, "boom\n"}, s)

    assert s2.assigns.codex_exec_run.stderr == "boom\n"
  end

  test "handle_info codex_exec_data ignores a mismatched run_id" do
    run = %{run_id: "r1", status: :running, stderr: "keep"}
    s = panel(%{codex_exec_run: run})

    assert {:noreply, s2} =
             CodexEvents.handle_info({:codex_exec_data, "other", :stderr, "x"}, s)

    assert s2.assigns.codex_exec_run == run
  end

  test "handle_info codex_exec_exit merges status for the matching run" do
    s = panel(%{codex_exec_run: %{run_id: "r1", status: :running, exit_code: nil}})

    assert {:noreply, s2} =
             CodexEvents.handle_info({:codex_exec_exit, "r1", 0, :exited}, s)

    assert s2.assigns.codex_exec_run.exit_code == 0
    assert s2.assigns.codex_exec_run.status == :exited
  end

  test "handle_info Event for another workspace leaves projections untouched" do
    s =
      panel(%{
        codex_threads: [%{thread_id: "keep"}],
        codex_selected_thread_id: "keep"
      })

    ev =
      event(:turn_completed,
        workspace_id: "other-ws",
        thread_id: "keep",
        payload: %{}
      )

    assert {:noreply, s2} = CodexEvents.handle_info(ev, s)
    assert s2.assigns.codex_threads == [%{thread_id: "keep"}]
    assert s2.assigns.codex_selected_thread_id == "keep"
  end

  test "codex:refresh loads an empty snapshot for an unknown workspace" do
    s = panel()
    assert {:noreply, s2} = CodexEvents.handle_event("codex:refresh", %{}, s)
    assert s2.assigns.codex_threads == []
    assert s2.assigns.codex_approvals == []
    assert s2.assigns.codex_pending_approval_count == 0
    assert s2.assigns.codex_error == nil
  end
end
