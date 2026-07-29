defmodule Casein.Mobile.LiveWorkTest do
  use ExUnit.Case, async: true

  alias Casein.Mobile.{AttentionInbox, LiveWork}
  alias Casein.Terminals.Session.Info

  @now ~U[2026-07-28 21:30:00Z]

  test "projects one privacy-bounded card per authoritative agent session" do
    tab =
      %Info{
        id: "shell_ws_runtime-1",
        kind: :shell,
        workspace_id: "ws",
        sid: "runtime-1",
        tmux_session: "casein_ws_runtime-1",
        status: :active,
        metadata: %{
          runtime_id: "runtime-1",
          agent: "codex",
          git_branch: "agent/live-work",
          git_head_sha: "abc123",
          cwd: "/sensitive/private/path",
          windows: [
            %{
              id: "@1",
              agent_state: :working,
              conversation_title: "Fix mobile visibility",
              task_summary: "raw prompt-derived summary"
            }
          ],
          agent_state_messages: %{"@1" => "private output"}
        }
      }

    assert [card] = LiveWork.project("user", "ws", "Devbox", [tab], @now)
    assert card.source == "live_work"
    assert card.kind == "live_work"
    assert card.title == "Fix mobile visibility"
    assert card.body == "codex · Agent working"
    assert card.meta.run_phase == "executing"
    assert card.meta.agent == "codex"
    assert card.meta.branch == "agent/live-work"
    assert card.meta.head_sha == "abc123"
    assert card.meta.progress == %{windows: 1, working: 1, waiting: 0, ready: 0, unknown: 0}
    assert card.actions |> Enum.map(& &1.id) == ["open"]
    assert card.context.locator == %{tmux_session: "casein_ws_runtime-1", tab: "terminal"}

    serialized = inspect(card)
    refute serialized =~ "/sensitive/private/path"
    refute serialized =~ "raw prompt-derived summary"
    refute serialized =~ "private output"
  end

  test "excludes ordinary operator shells without an authoritative agent marker" do
    operator =
      %Info{
        id: "shell_ws_operator",
        kind: :shell,
        workspace_id: "ws",
        sid: "operator",
        tmux_session: "casein_ws_operator",
        status: :active,
        metadata: %{
          windows: [
            %{id: "@1", pane_state: :working, task_summary: "must not make this eligible"}
          ]
        }
      }

    assert LiveWork.project("user", "ws", "Devbox", [operator], @now) == []
  end

  test "admits a scanned shell only when explicit agent role and typed state agree" do
    exact =
      %Info{
        id: "shell_ws_disposable",
        kind: :shell,
        workspace_id: "ws",
        sid: "disposable",
        tmux_session: "casein_ws_disposable",
        status: :active,
        metadata: %{
          windows: [%{id: "@1", agent_state: :blocked}],
          pane_summaries: [
            %{id: "%1", window_id: "@1", role: "operator"},
            %{id: "%2", window_id: "@1", role: "agent"}
          ]
        }
      }

    state_without_role =
      put_in(exact, [Access.key!(:metadata), :pane_summaries], [%{id: "%2", active: true}])

    role_without_state =
      put_in(exact, [Access.key!(:metadata), :windows], [%{id: "@1", pane_state: :working}])

    assert [card] = LiveWork.project("user", "ws", "Devbox", [exact], @now)
    assert card.status == "waiting"
    assert card.context.locator.pane == "%2"
    assert AttentionInbox.project(card).reason_code == "human_blocked"
    assert LiveWork.project("user", "ws", "Devbox", [state_without_role], @now) == []
    assert LiveWork.project("user", "ws", "Devbox", [role_without_state], @now) == []
  end

  test "does not correlate an operator window state with an agent pane in another window" do
    mismatched =
      %Info{
        id: "shell_ws_mismatched",
        kind: :shell,
        workspace_id: "ws",
        sid: "mismatched",
        tmux_session: "casein_ws_mismatched",
        status: :active,
        metadata: %{
          windows: [
            %{id: "@1", pane_state: :idle},
            %{id: "@2", agent_state: :blocked}
          ],
          pane_summaries: [
            %{id: "%2", window_id: "@1", role: "agent"},
            %{id: "%1", window_id: "@2", role: "operator"}
          ]
        }
      }

    assert LiveWork.project("user", "ws", "Devbox", [mismatched], @now) == []
  end

  test "operator window state cannot override a correlated agent window" do
    correlated =
      %Info{
        id: "shell_ws_correlated",
        kind: :shell,
        workspace_id: "ws",
        sid: "correlated",
        tmux_session: "casein_ws_correlated",
        status: :active,
        metadata: %{
          windows: [
            %{id: "@1", agent_state: :working},
            %{id: "@2", agent_state: :blocked}
          ],
          pane_summaries: [
            %{id: "%2", window_id: "@1", role: "agent"},
            %{id: "%1", window_id: "@2", role: "operator"}
          ]
        }
      }

    assert [card] = LiveWork.project("user", "ws", "Devbox", [correlated], @now)
    assert card.status == "running"
    assert card.meta.run_phase == "executing"
    assert card.meta.activity == "Agent working"
    assert card.meta.progress == %{windows: 1, working: 1, waiting: 0, ready: 0, unknown: 0}
    assert card.context.locator.pane == "%2"
  end

  test "conversation title is an authoritative marker but never grants mutation" do
    tab =
      %Info{
        id: "shell_ws_codex",
        kind: :shell,
        workspace_id: "ws",
        sid: "codex",
        status: :active,
        metadata: %{
          windows: [%{conversation_title: "Investigate deploy", pane_state: :working}]
        }
      }

    assert [card] = LiveWork.project("user", "ws", "Devbox", [tab], @now)
    assert card.title == "Investigate deploy"
    assert card.meta.agent == "Codex"
    assert Enum.all?(card.actions, &Map.has_key?(&1, :route))
    refute Enum.any?(card.actions, &(&1.id in ~w(continue approve deny request_changes)))
  end

  test "state precedence is deterministic and unknown remains explicit" do
    blocked = agent_tab([%{agent_state: :working}, %{agent_state: :blocked}])
    failed = agent_tab([%{agent_state: :error}])
    unknown = agent_tab([%{pane_state: :idle}])

    assert [blocked_card] = LiveWork.project("u", "ws", "Devbox", [blocked], @now)
    assert blocked_card.status == "waiting"
    assert blocked_card.meta.run_phase == "waiting"
    assert blocked_card.meta.activity == "Waiting for user"
    assert AttentionInbox.project(blocked_card).reason_code == "human_blocked"
    assert AttentionInbox.project(blocked_card).required_decision == "Respond"

    assert [failed_card] = LiveWork.project("u", "ws", "Devbox", [failed], @now)
    assert failed_card.status == "failed"
    assert failed_card.meta.run_phase == "failed"

    assert [unknown_card] = LiveWork.project("u", "ws", "Devbox", [unknown], @now)
    assert unknown_card.meta.run_phase == "unknown"
    assert unknown_card.meta.partial
  end

  test "failure outranks concurrent working state" do
    mixed = agent_tab([%{agent_state: :working}, %{agent_state: :failed}])

    assert [card] = LiveWork.project("u", "ws", "Devbox", [mixed], @now)
    assert card.status == "failed"
    assert card.meta.run_phase == "failed"
  end

  test "session replacement changes identity without promoting pane identity" do
    first = agent_tab([%{id: "@1", pane_state: :working}], id: "runtime-1")
    replacement = agent_tab([%{id: "@9", pane_state: :working}], id: "runtime-2")

    assert [first_card, replacement_card] =
             LiveWork.project("u", "ws", "Devbox", [first, replacement], @now)

    assert first_card.id != replacement_card.id
    refute inspect(first_card.context) =~ "@1"
    refute inspect(replacement_card.context) =~ "@9"
  end

  test "includes only one explicitly role-marked agent pane in the locator" do
    exact =
      agent_tab([%{id: "@1", agent_state: :blocked}],
        tmux_session: "casein_ws_exact",
        pane_summaries: [
          %{id: "%1", window_id: "@1", role: "operator", active: true},
          %{id: "%2", window_id: "@1", role: "verify"},
          %{id: "%3", window_id: "@1", role: "agent"}
        ]
      )

    ambiguous =
      agent_tab([%{id: "@2", agent_state: :working}],
        tmux_session: "casein_ws_ambiguous",
        pane_summaries: [
          %{id: "%4", window_id: "@2", role: "agent"},
          %{id: "%5", window_id: "@2", role: "agent"}
        ]
      )

    active_only =
      agent_tab([%{id: "@3", agent_state: :working}],
        tmux_session: "casein_ws_active",
        pane_summaries: ["malformed", %{id: "%6", active: true}]
      )

    assert [exact_card, ambiguous_card, active_card] =
             LiveWork.project("u", "ws", "Devbox", [exact, ambiguous, active_only], @now)

    assert exact_card.context.locator.pane == "%3"
    refute Map.has_key?(ambiguous_card.context.locator, :pane)
    refute Map.has_key?(active_card.context.locator, :pane)
  end

  defp agent_tab(windows, opts \\ []) do
    id = Keyword.get(opts, :id, "runtime")

    %Info{
      id: "agent_#{id}",
      kind: :agent,
      workspace_id: "ws",
      runner_id: id,
      tmux_session: Keyword.get(opts, :tmux_session),
      status: :active,
      metadata: %{
        agent: "codex",
        windows: windows,
        pane_summaries: Keyword.get(opts, :pane_summaries, [])
      }
    }
  end
end
