defmodule CaseinWeb.WorkspaceLive.Show.TerminalEventsTest do
  use Casein.TestCase, async: false

  alias Casein.Workspace
  alias Casein.Terminals.AgentState
  alias Casein.Terminals.NextPrompt
  alias CaseinWeb.WorkspaceLive.Show.TerminalEvents
  alias TmuxCtl.Test.FakeState

  defmodule EmptyHistoryTmux do
    def capture_scrollback(_session, _opts), do: ""
  end

  defmodule EmbeddableChecker do
    def frame_blocked_url?(_url), do: false
    def frame_blocked_url?(_url, _opts), do: false
  end

  defmodule BlockedChecker do
    def frame_blocked_url?(_url), do: true
    def frame_blocked_url?(_url, _opts), do: true
  end

  test "terminal kill refuses tmux sessions outside the workspace prefix" do
    previous_adapter = Application.get_env(:casein, :tmux_adapter)
    previous_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)

    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())
    flush_mailbox()

    on_exit(fn ->
      restore_env(:casein, :tmux_adapter, previous_adapter)
      TmuxCtl.Test.FakeState.restore(:fake_tmux_test_pid, previous_pid)
    end)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        tmux_mutations_enabled?: true,
        workspace: %Workspace{id: "ws-1", name: "alpha"}
      }
    }

    other_session = Casein.Terminals.Tmux.session_name("beta", "u-dev")

    assert {:noreply, socket} =
             TerminalEvents.handle_event(
               "terminal:kill_session",
               %{"session-id" => "u-dev", "tmux-session" => other_session},
               socket
             )

    assert Phoenix.Flash.get(socket.assigns.flash, :error) =~ "outside this workspace"
    refute_received {:fake_tmux_kill_session, ^other_session}
  end

  describe "terminal:send_agent_text" do
    defp send_text_socket(assigns) do
      %Phoenix.LiveView.Socket{
        assigns:
          Map.merge(
            %{__changed__: %{}, flash: %{}, tmux_session: "casein_ws_test"},
            assigns
          )
      }
    end

    test "denied when tmux mutations are disabled" do
      socket = send_text_socket(%{tmux_mutations_enabled?: false})

      assert {:noreply, socket} =
               TerminalEvents.handle_event("terminal:send_agent_text", %{"text" => "hi"}, socket)

      assert Phoenix.Flash.get(socket.assigns.flash, :error) =~ "not allowed"
    end

    test "blank text is a no-op" do
      socket = send_text_socket(%{tmux_mutations_enabled?: true})

      assert {:noreply, socket} =
               TerminalEvents.handle_event(
                 "terminal:send_agent_text",
                 %{"text" => "   \n"},
                 socket
               )

      assert Phoenix.Flash.get(socket.assigns.flash, :error) == nil
    end

    test "oversized text is refused before touching tmux" do
      socket = send_text_socket(%{tmux_mutations_enabled?: true})
      big = String.duplicate("a", 32 * 1024 + 1)

      assert {:noreply, socket} =
               TerminalEvents.handle_event("terminal:send_agent_text", %{"text" => big}, socket)

      assert Phoenix.Flash.get(socket.assigns.flash, :error) =~ "too large"
    end
  end

  describe "terminal:compose_agent_message" do
    setup do
      previous_flag = Application.get_env(:casein, :mobile_agent_composer)
      previous_adapter = Application.get_env(:casein, :tmux_adapter)
      previous_pid = FakeState.get(:fake_tmux_test_pid)

      Application.put_env(:casein, :mobile_agent_composer, true)
      Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
      FakeState.put(:fake_tmux_test_pid, self())

      on_exit(fn ->
        NextPrompt.clear("casein_ws_agent", "%7")
        restore_env(:casein, :mobile_agent_composer, previous_flag)
        restore_env(:casein, :tmux_adapter, previous_adapter)
        FakeState.restore(:fake_tmux_test_pid, previous_pid)
      end)

      :ok
    end

    test "flag off refuses the event without touching the pane" do
      Application.put_env(:casein, :mobile_agent_composer, false)

      assert {:noreply, socket} =
               TerminalEvents.handle_event(
                 "terminal:compose_agent_message",
                 %{"pane_id" => "%7", "text" => "hello", "action" => "send"},
                 composer_socket()
               )

      assert Phoenix.Flash.get(socket.assigns.flash, :error) =~ "disabled"
      refute_received {:fake_tmux_paste_text, _, _, _, _}
    end

    test "a shell pane is refused server-side" do
      socket = composer_socket(%{role: nil})

      assert {:noreply, socket} =
               TerminalEvents.handle_event(
                 "terminal:compose_agent_message",
                 %{"pane_id" => "%7", "text" => "hello", "action" => "send"},
                 socket
               )

      assert Phoenix.Flash.get(socket.assigns.flash, :error) =~ "not an agent pane"
      refute_received {:fake_tmux_paste_text, _, _, _, _}
    end

    test "Send routes through confirmed PaneSubmit delivery" do
      assert {:noreply, socket} =
               TerminalEvents.handle_event(
                 "terminal:compose_agent_message",
                 %{"pane_id" => "%7", "text" => "ship the focused fix", "action" => "send"},
                 composer_socket()
               )

      assert Phoenix.Flash.get(socket.assigns.flash, :info) =~ "Message"
      assert_received {:fake_tmux_paste_text, "casein_ws_agent", "%7", text, opts}
      assert text =~ "ship the focused fix"
      refute Keyword.get(opts, :submit)
      assert_received {:fake_tmux_keys, "casein_ws_agent", "%7", "Enter", _}
    end

    test "Send later uses the existing coalescing slot and selected edge" do
      :ok =
        AgentState.report(
          "ws-1",
          "casein_ws_agent",
          "%7",
          :working,
          nil,
          agent_session_id: "agent-session-7"
        )

      _ = AgentState.get("casein_ws_agent", "%7")

      params = %{
        "pane_id" => "%7",
        "text" => "rebase before pushing",
        "action" => "later",
        "deliver_when" => "next_done"
      }

      assert {:noreply, socket} =
               TerminalEvents.handle_event(
                 "terminal:compose_agent_message",
                 params,
                 composer_socket()
               )

      assert Phoenix.Flash.get(socket.assigns.flash, :info) =~ "latest staged message wins"
      entry = NextPrompt.get("casein_ws_agent", "%7")
      assert entry.text == "rebase before pushing"
      assert entry.deliver_when == :next_done
      assert entry.coalesce_key == "mobile-agent-composer"
      assert entry.agent_session_id == "agent-session-7"
    end

    test "Send later preserves NextPrompt's refusal for a hook-less runtime" do
      params = %{
        "pane_id" => "%7",
        "text" => "wait for the next edge",
        "action" => "later",
        "deliver_when" => "next_done"
      }

      assert {:noreply, socket} =
               TerminalEvents.handle_event(
                 "terminal:compose_agent_message",
                 params,
                 composer_socket(%{current_command: "opencode", agent_state: :working})
               )

      assert Phoenix.Flash.get(socket.assigns.flash, :error) =~ "cannot report the state change"
      refute NextPrompt.get("casein_ws_agent", "%7")
    end

    test "the composer's server limit is exactly NextPrompt.text_limit/0 bytes" do
      too_large = String.duplicate("é", div(NextPrompt.text_limit(), 2) + 1)

      assert {:noreply, socket} =
               TerminalEvents.handle_event(
                 "terminal:compose_agent_message",
                 %{"pane_id" => "%7", "text" => too_large, "action" => "send"},
                 composer_socket()
               )

      assert Phoenix.Flash.get(socket.assigns.flash, :error) =~
               "#{NextPrompt.text_limit()} bytes max"

      refute_received {:fake_tmux_paste_text, _, _, _, _}
    end

    defp composer_socket(pane_overrides \\ %{}) do
      pane =
        Map.merge(
          %{
            id: "%7",
            role: "agent",
            active: true,
            agent_state: :working,
            agent_session_id: "agent-session-7"
          },
          pane_overrides
        )

      %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          tmux_session: "casein_ws_agent",
          workspace: %Workspace{id: "ws-1", name: "alpha"},
          tmux_windows: [%{id: "@0", active: true, pane_list: [pane]}]
        }
      }
    end
  end

  describe "terminal:send_agent_reference" do
    test "denied when tmux mutations are disabled" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          tmux_session: "casein_ws_test",
          tmux_mutations_enabled?: false
        }
      }

      assert {:noreply, socket} =
               TerminalEvents.handle_event(
                 "terminal:send_agent_reference",
                 %{"kind" => "session", "session_id" => "u-dev"},
                 socket
               )

      assert Phoenix.Flash.get(socket.assigns.flash, :error) =~ "not allowed"
    end

    test "ignores unknown reference kinds" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}, tmux_mutations_enabled?: true}
      }

      assert {:noreply, ^socket} =
               TerminalEvents.handle_event(
                 "terminal:send_agent_reference",
                 %{"kind" => "pane"},
                 socket
               )
    end
  end

  describe "tmux:move_window" do
    defp move_socket(assigns) do
      %Phoenix.LiveView.Socket{
        assigns:
          Map.merge(
            %{
              __changed__: %{},
              flash: %{},
              tmux_session: "casein_alpha_u-dev",
              tmux_mutations_enabled?: true,
              tmux_windows: [
                %{id: "@0", index: 0},
                %{id: "@1", index: 1},
                %{id: "@2", index: 2}
              ]
            },
            assigns
          )
      }
    end

    setup do
      previous_adapter = Application.get_env(:casein, :tmux_adapter)
      previous_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)

      Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
      TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())
      flush_mailbox()

      on_exit(fn ->
        restore_env(:casein, :tmux_adapter, previous_adapter)
        TmuxCtl.Test.FakeState.restore(:fake_tmux_test_pid, previous_pid)
      end)

      :ok
    end

    test "move right sends :after to the next neighbor" do
      socket = move_socket(%{})

      assert {:noreply, _socket} =
               TerminalEvents.handle_event(
                 "tmux:move_window",
                 %{"window-id" => "@0", "dir" => "right"},
                 socket
               )

      assert_receive {:fake_tmux_move_window, "casein_alpha_u-dev", "@0", "@1", :after}
    end

    test "move at the right edge is a no-op" do
      socket = move_socket(%{})

      assert {:noreply, ^socket} =
               TerminalEvents.handle_event(
                 "tmux:move_window",
                 %{"window-id" => "@2", "dir" => "right"},
                 socket
               )

      refute_received {:fake_tmux_move_window, _, _, _, _}
    end

    test "move is denied when mutations are disabled" do
      socket = move_socket(%{tmux_mutations_enabled?: false})

      assert {:noreply, socket} =
               TerminalEvents.handle_event(
                 "tmux:move_window",
                 %{"window-id" => "@0", "dir" => "right"},
                 socket
               )

      assert Phoenix.Flash.get(socket.assigns.flash, :error) =~ "not allowed"
      refute_received {:fake_tmux_move_window, _, _, _, _}
    end

    test "drag-drop before-window-id moves before the target window" do
      socket = move_socket(%{})

      assert {:noreply, _socket} =
               TerminalEvents.handle_event(
                 "tmux:move_window",
                 %{"window-id" => "@2", "before-window-id" => "@0"},
                 socket
               )

      assert_receive {:fake_tmux_move_window, "casein_alpha_u-dev", "@2", "@0", :before}
    end

    test "drag-drop past the end moves after the last window" do
      socket = move_socket(%{})

      assert {:noreply, _socket} =
               TerminalEvents.handle_event(
                 "tmux:move_window",
                 %{"window-id" => "@0", "before-window-id" => "@2", "dir" => "after"},
                 socket
               )

      assert_receive {:fake_tmux_move_window, "casein_alpha_u-dev", "@0", "@2", :after}
    end
  end

  describe "pane:history_open" do
    test "starts a pane-scoped history drawer with a stable scroll key" do
      previous_adapter = Application.get_env(:casein, :tmux_adapter)
      Application.put_env(:casein, :tmux_adapter, EmptyHistoryTmux)

      on_exit(fn -> restore_env(:casein, :tmux_adapter, previous_adapter) end)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          workspace: %Workspace{id: "ws-1", name: "alpha"},
          tmux_session: "casein_alpha_u-dev",
          tmux_windows: [
            %{
              id: "@1",
              active: true,
              pane_list: [
                %{
                  id: "%7",
                  window_id: "@1",
                  index: 0,
                  active: true,
                  left: 0,
                  top: 0,
                  width: 100,
                  height: 30,
                  current_path: "/work/casein",
                  current_command: "bash"
                }
              ]
            }
          ]
        }
      }

      assert {:noreply, socket} =
               TerminalEvents.handle_event("pane:history_open", %{"pane-id" => "%7"}, socket)

      assert %{
               pane_id: "%7",
               window_id: "@1",
               session: "casein_alpha_u-dev",
               key: "casein_alpha_u-dev:@1:%7",
               cols: 100,
               rows: 30,
               term: nil,
               worker: worker
             } = socket.assigns.pane_history

      assert is_pid(worker)
      assert socket.assigns.pane_history.title =~ "/work/casein"
      assert is_integer(socket.assigns.pane_history.refreshed_at)

      _socket = TerminalEvents.close_pane_history(socket)
    end
  end

  describe "terminal:open_web_link_preview" do
    defp preview_socket(assigns) do
      %Phoenix.LiveView.Socket{
        assigns:
          Map.merge(
            %{__changed__: %{}, flash: %{}, workspace: %Workspace{id: "ws-1", name: "alpha"}},
            assigns
          )
      }
    end

    setup do
      # Stub the network-touching embeddability probe; default = embeddable so
      # the URL flows to the normal preview-open path. Individual tests override.
      previous = Application.get_env(:casein, :embeddability_checker)
      Application.put_env(:casein, :embeddability_checker, EmbeddableChecker)
      on_exit(fn -> restore_env(:casein, :embeddability_checker, previous) end)
      :ok
    end

    test "an embeddable http(s) URL with no tmux session flashes the start-a-session hint" do
      socket = preview_socket(%{tmux_session: ""})

      assert {:noreply, socket, {:continue, {:open_web_link_preview, url}}} =
               TerminalEvents.handle_event(
                 "terminal:open_web_link_preview",
                 %{"url" => "https://example.com/x"},
                 socket
               )

      assert url == "https://example.com/x"

      assert {:noreply, socket} =
               TerminalEvents.handle_continue({:open_web_link_preview, url}, socket)

      assert Phoenix.Flash.get(socket.assigns.flash, :error) =~ "tmux terminal session"
    end

    test "a frame-blocking site falls back to opening a browser tab" do
      Application.put_env(:casein, :embeddability_checker, BlockedChecker)
      socket = preview_socket(%{tmux_session: "casein_alpha_u-dev"})

      assert {:noreply, socket, {:continue, {:open_web_link_preview, url}}} =
               TerminalEvents.handle_event(
                 "terminal:open_web_link_preview",
                 %{"url" => "https://blocks-framing.example/x"},
                 socket
               )

      assert {:noreply, socket} =
               TerminalEvents.handle_continue({:open_web_link_preview, url}, socket)

      assert Phoenix.Flash.get(socket.assigns.flash, :info) =~ "new browser tab"

      assert Enum.any?(socket.private.live_temp[:push_events] || [], fn
               ["casein:open_tab", %{url: url}] -> url == "https://blocks-framing.example/x"
               _ -> false
             end)
    end

    test "a non-http scheme is rejected before any preview open" do
      socket = preview_socket(%{tmux_session: ""})

      assert {:noreply, ^socket} =
               TerminalEvents.handle_event(
                 "terminal:open_web_link_preview",
                 %{"url" => "javascript:alert(1)"},
                 socket
               )

      assert Phoenix.Flash.get(socket.assigns.flash, :error) == nil
    end

    test "a missing url param is a no-op" do
      socket = preview_socket(%{})

      assert {:noreply, ^socket} =
               TerminalEvents.handle_event("terminal:open_web_link_preview", %{}, socket)
    end
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
