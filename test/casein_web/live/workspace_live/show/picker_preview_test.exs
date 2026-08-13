defmodule CaseinWeb.WorkspaceLive.Show.PickerPreviewTest do
  use Casein.TestCase, async: true

  alias CaseinWeb.WorkspaceLive.Show.AgentStateChrome
  alias CaseinWeb.WorkspaceLive.Show.PickerPreview

  # #951: picker preview names its source and reuses AgentStateChrome.
  # Unknown paints identity only. Blocked scrolls to the prompt. Capture stays
  # at 18 lines and no poller is added.

  defp socket(assigns) do
    ws = %{id: "ws-picker", name: "alpha"}

    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            workspace: ws,
            tmux_session: "casein_alpha_main",
            terminal_sid: "main",
            tmux_windows: [],
            tmux_window_tabs: [],
            session_tabs: []
          },
          assigns
        )
    }
  end

  test "preview_lines stays at the existing 18-line capture cap" do
    assert PickerPreview.preview_lines() == 18
  end

  test "no picker preview poller is added to the supervision tree" do
    application = File.read!("lib/casein/application.ex")

    refute application =~ "PickerPreview",
           "picker preview must reuse the existing capture path — do not add a poller"
  end

  test "forbidden session returns unavailable source and no identity leak" do
    s = socket(%{tmux_session: "casein_alpha_main"})

    reply =
      PickerPreview.reply(s, %{"tmux-session" => "casein_other_main", "window-id" => "@1"})

    assert reply.source == "forbidden"
    assert reply.text == ""
    assert reply.session == nil
    assert reply.chrome == %{known: false}
    refute reply.scroll_to_prompt
  end

  test "unknown pane paints identity only — no invented idle/ready chrome" do
    s =
      socket(%{
        tmux_window_tabs: [
          %{
            id: "@1",
            name: "work",
            display_name: "work",
            active?: true,
            agent_state: :unknown,
            panes: [%{id: "%3", label: "bash", active?: true}]
          }
        ],
        session_tabs: [
          %{id: "main", tmux_session: "casein_alpha_main", label: "alpha", cwd: "/tmp/ws"}
        ]
      })

    prov = PickerPreview.provenance(s, %{"window-id" => "@1", "pane-id" => "%3"})

    assert prov.session == "alpha"
    assert prov.window == "work"
    assert prov.pane == "bash"
    assert prov.chrome == %{known: false}
    refute Map.has_key?(prov.chrome, :chip_text)
    assert AgentStateChrome.present(:unknown).known? == false
  end

  test "reporting pane includes AgentStateChrome chip and stalled stays warning" do
    s =
      socket(%{
        tmux_window_tabs: [
          %{
            id: "@2",
            name: "agent",
            display_name: "agent",
            agent_state: :stalled,
            agent_state_message: nil,
            liveness: %{quiet_for_seconds: 900},
            panes: [
              %{
                id: "%9",
                label: "opencode",
                agent_state: :stalled,
                agent_runtime: "opencode",
                current_path: "/tmp/ws/worktree",
                liveness: %{quiet_for_seconds: 900}
              }
            ]
          }
        ]
      })

    prov = PickerPreview.provenance(s, %{"window-id" => "@2", "pane-id" => "%9"})
    stalled = AgentStateChrome.present(:stalled)

    assert prov.runtime == "OpenCode"
    assert prov.cwd == "/tmp/ws/worktree"
    assert prov.quiet_for_seconds == 900
    assert prov.chrome.known
    assert prov.chrome.state == "stalled"
    assert prov.chrome.chip_text == stalled.chip_text
    assert prov.chrome.dot_class == stalled.dot_class
    assert prov.chrome.dot_class =~ "status-warning"
    refute prov.chrome.dot_class == AgentStateChrome.present(:working).dot_class
  end

  test "blocked pane requests scroll-to-prompt and indexes the question line" do
    s =
      socket(%{
        tmux_window_tabs: [
          %{
            id: "@3",
            name: "agent",
            display_name: "agent",
            agent_state: :blocked,
            panes: [%{id: "%4", label: "claude", agent_state: :blocked, agent_runtime: "claude"}]
          }
        ]
      })

    reply = PickerPreview.reply(s, %{"window-id" => "@3", "pane-id" => "%4"})

    assert reply.scroll_to_prompt
    assert reply.chrome.state == "blocked"
    assert reply.runtime == "Claude"
    assert PickerPreview.prompt_line("ls\nAllow this command?\nmore output") == 1
    assert PickerPreview.prompt_line("no question here") == nil
  end

  test "empty authorized capture is named empty, not live" do
    s = socket(%{})
    reply = PickerPreview.reply(s, %{"window-id" => "@1"})
    assert reply.source == "empty"
    refute reply.source == "live"
  end
end
