defmodule CaseinWeb.WorkspaceLive.Show.PtyEventsTest do
  use Casein.TestCase, async: true

  alias CaseinWeb.WorkspaceLive.Show
  alias CaseinWeb.WorkspaceLive.Show.PtyEvents

  # Behaviour-preserving extract of Show handle_info PTY/recovery clauses.
  # These tests pin the moved clauses and the split constraints — do not
  # "fix" tracking or change recovery/reattach policy here.

  defp socket(assigns) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            flash: %{},
            pane_data: %{},
            osc52_clipboard_buffers: %{},
            tmux_session: "casein_ws_main",
            workspace: %{id: "ws-pty-#{System.unique_integer([:positive])}"}
          },
          assigns
        )
    }
  end

  defp pane(attrs) do
    Map.merge(
      %{
        ghostty_pty: self(),
        ghostty_term: self(),
        worker: self(),
        backend: :ghostty_pty,
        error: nil,
        auto_retry_count: 0
      },
      attrs
    )
  end

  test "Show.handle_info delegates :pty_data / :pane_frame / :pty_exit to PtyEvents" do
    s = socket(%{pane_data: %{}})

    assert {:noreply, ^s} = Show.handle_info({:pty_data, "missing", "plain"}, s)
    assert {:noreply, ^s} = Show.handle_info({:pane_frame, "missing", %{id: "x"}}, s)
    assert {:noreply, ^s} = Show.handle_info({:pty_exit, "missing", :process_died}, s)
  end

  test "{:pty_data, _, data} without OSC52 is a side-channel no-op" do
    s = socket(%{})
    assert {:noreply, s2} = PtyEvents.handle_info({:pty_data, "pane-1", "hello"}, s)
    assert s2.assigns.osc52_clipboard_buffers == %{}
    assert s2.assigns.pane_data == %{}
  end

  test "{:pane_frame, pane_id, _} drops frames for an unknown pane" do
    s = socket(%{pane_data: %{}})
    assert {:noreply, ^s} = PtyEvents.handle_info({:pane_frame, "gone", %{id: "ghostty-gone"}}, s)
  end

  test "{:pty_exit, pane_id, status} clears handles and records the error" do
    s = socket(%{pane_data: %{"pane-1" => pane(%{})}})

    assert {:noreply, s2} = PtyEvents.handle_info({:pty_exit, "pane-1", :process_died}, s)
    updated = Show.get_pane_data(s2, "pane-1")
    assert updated.ghostty_pty == nil
    assert updated.ghostty_term == nil
    assert updated.worker == nil
    assert updated.backend == nil
    assert updated.error == :process_died
    assert updated.auto_retry_count == 1
  end

  test "{:pty_exit, pane_id, {:exit_status, n}} normalizes to the integer and does not auto-reattach" do
    s = socket(%{pane_data: %{"pane-1" => pane(%{})}})

    assert {:noreply, s2} = PtyEvents.handle_info({:pty_exit, "pane-1", {:exit_status, 0}}, s)
    updated = Show.get_pane_data(s2, "pane-1")
    assert updated.error == 0
    assert updated.auto_retry_count == 0
  end

  test "{:pty_exit, _, _} for an unknown pane does not insert a nil entry" do
    s = socket(%{pane_data: %{}})
    assert {:noreply, s2} = PtyEvents.handle_info({:pty_exit, "gone", :process_died}, s)
    assert s2.assigns.pane_data == %{}
  end

  test "{:terminal_recovery, _} for another session is ignored" do
    s = socket(%{tmux_session: "casein_ws_main", flash: %{}})

    notice = %{
      type: :session_recreated,
      tmux_session: "casein_other_main",
      template_id: "agent_pair",
      history_restored?: false
    }

    assert {:noreply, s2} = Show.handle_info({:terminal_recovery, notice}, s)
    assert s2.assigns.flash == %{}
    refute_receive {:auto_apply_recovery_template, _}, 20
  end

  test "{:terminal_recovery, _} for this session flashes and schedules template apply" do
    s = socket(%{tmux_session: "casein_ws_main"})

    notice = %{
      type: :session_recreated,
      tmux_session: "casein_ws_main",
      template_id: "agent_pair",
      history_restored?: true
    }

    assert {:noreply, s2} = PtyEvents.handle_info({:terminal_recovery, notice}, s)
    assert Phoenix.Flash.get(s2.assigns.flash, :error) =~ "tmux reset"
    assert Phoenix.Flash.get(s2.assigns.flash, :error) =~ "scrollback was restored"
    assert_receive {:auto_apply_recovery_template, "agent_pair"}, 1_000
  end

  test "{:auto_apply_recovery_template, _} is a no-op when mutations are disabled" do
    s = socket(%{tmux_mutations_enabled?: false, tmux_session: "casein_ws_main"})
    assert {:noreply, ^s} = Show.handle_info({:auto_apply_recovery_template, "agent_pair"}, s)
  end

  test "{:auto_reattach_pane, _, _} is a no-op when the pane is gone or already healthy" do
    missing = socket(%{pane_data: %{}})
    assert {:noreply, ^missing} = PtyEvents.handle_info({:auto_reattach_pane, "gone", 1}, missing)

    healthy = socket(%{pane_data: %{"pane-1" => pane(%{error: nil, auto_retry_count: 1})}})

    assert {:noreply, ^healthy} =
             PtyEvents.handle_info({:auto_reattach_pane, "pane-1", 1}, healthy)
  end
end
