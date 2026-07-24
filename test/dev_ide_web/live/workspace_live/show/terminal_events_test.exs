defmodule CaseinWeb.WorkspaceLive.Show.TerminalEventsTest do
  use Casein.TestCase, async: false

  alias Casein.Workspace
  alias CaseinWeb.WorkspaceLive.Show.TerminalEvents

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
    previous_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    previous_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)

    Application.put_env(:dev_ide, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())
    flush_mailbox()

    on_exit(fn ->
      restore_env(:dev_ide, :tmux_adapter, previous_adapter)
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
            %{__changed__: %{}, flash: %{}, tmux_session: "devide_ws_test"},
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

  describe "tmux:move_window" do
    defp move_socket(assigns) do
      %Phoenix.LiveView.Socket{
        assigns:
          Map.merge(
            %{
              __changed__: %{},
              flash: %{},
              tmux_session: "devide_alpha_u-dev",
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
      previous_adapter = Application.get_env(:dev_ide, :tmux_adapter)
      previous_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)

      Application.put_env(:dev_ide, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
      TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())
      flush_mailbox()

      on_exit(fn ->
        restore_env(:dev_ide, :tmux_adapter, previous_adapter)
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

      assert_receive {:fake_tmux_move_window, "devide_alpha_u-dev", "@0", "@1", :after}
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

      assert_receive {:fake_tmux_move_window, "devide_alpha_u-dev", "@2", "@0", :before}
    end

    test "drag-drop past the end moves after the last window" do
      socket = move_socket(%{})

      assert {:noreply, _socket} =
               TerminalEvents.handle_event(
                 "tmux:move_window",
                 %{"window-id" => "@0", "before-window-id" => "@2", "dir" => "after"},
                 socket
               )

      assert_receive {:fake_tmux_move_window, "devide_alpha_u-dev", "@0", "@2", :after}
    end
  end

  describe "pane:history_open" do
    test "starts a pane-scoped history drawer with a stable scroll key" do
      previous_adapter = Application.get_env(:dev_ide, :tmux_adapter)
      Application.put_env(:dev_ide, :tmux_adapter, EmptyHistoryTmux)

      on_exit(fn -> restore_env(:dev_ide, :tmux_adapter, previous_adapter) end)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          workspace: %Workspace{id: "ws-1", name: "alpha"},
          tmux_session: "devide_alpha_u-dev",
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
                  current_path: "/work/dev_ide",
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
               session: "devide_alpha_u-dev",
               key: "devide_alpha_u-dev:@1:%7",
               cols: 100,
               rows: 30,
               term: nil,
               worker: worker
             } = socket.assigns.pane_history

      assert is_pid(worker)
      assert socket.assigns.pane_history.title =~ "/work/dev_ide"
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
      previous = Application.get_env(:dev_ide, :embeddability_checker)
      Application.put_env(:dev_ide, :embeddability_checker, EmbeddableChecker)
      on_exit(fn -> restore_env(:dev_ide, :embeddability_checker, previous) end)
      :ok
    end

    test "an embeddable http(s) URL with no tmux session flashes the start-a-session hint" do
      socket = preview_socket(%{tmux_session: ""})

      assert {:noreply, socket} =
               TerminalEvents.handle_event(
                 "terminal:open_web_link_preview",
                 %{"url" => "https://example.com/x"},
                 socket
               )

      assert Phoenix.Flash.get(socket.assigns.flash, :error) =~ "tmux terminal session"
    end

    test "a frame-blocking site falls back to opening a browser tab" do
      Application.put_env(:dev_ide, :embeddability_checker, BlockedChecker)
      socket = preview_socket(%{tmux_session: "devide_alpha_u-dev"})

      assert {:noreply, socket} =
               TerminalEvents.handle_event(
                 "terminal:open_web_link_preview",
                 %{"url" => "https://blocks-framing.example/x"},
                 socket
               )

      assert Phoenix.Flash.get(socket.assigns.flash, :info) =~ "new browser tab"

      assert Enum.any?(socket.private.live_temp[:push_events] || [], fn
               ["devide:open_tab", %{url: url}] -> url == "https://blocks-framing.example/x"
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
