defmodule Casein.PreviousSessionsTest do
  use Casein.TestCase, async: true

  alias Casein.Audit.Event
  alias Casein.PreviousSessions
  alias Casein.Terminals.Session.Info, as: SessionInfo

  @workspace_id "ws-alpha"

  test "searches prompt text from recent MCP activity" do
    inserted_at = ~U[2026-06-29 12:00:00Z]

    activity = %{
      id: "activity-1",
      workspace_id: @workspace_id,
      source: :terminal_mcp,
      tool: "terminal_paste_agent_text",
      summary: "session=devide_alpha_agent - pane=%3",
      metadata: %{
        session: "devide_alpha_agent",
        pane: "%3",
        text: "Restart Phoenix and verify preview routing"
      },
      status: :ok,
      inserted_at: inserted_at
    }

    assert %{results: [result]} =
             PreviousSessions.search(@workspace_id,
               query: "phoenix",
               sessions: [],
               audit_events: [],
               activity_entries: [activity],
               labels_by_session: %{}
             )

    assert result.source == :activity
    assert result.session == "devide_alpha_agent"
    assert result.pane == "%3"

    assert_href(result.href, "/workspaces/ws-alpha", %{
      "session" => "devide_alpha_agent",
      "pane" => "%3"
    })

    assert result.occurred_at == inserted_at
    assert "title" in result.matched_fields
    assert "metadata.text" in result.matched_fields
  end

  test "searches nested timestamp metadata without treating structs as maps" do
    activity = %{
      id: "activity-time",
      workspace_id: @workspace_id,
      source: :terminal_mcp,
      tool: "terminal_send_agent_prompt",
      summary: "session=devide_alpha_agent",
      metadata: %{
        session: "devide_alpha_agent",
        nested: %{seen_at: ~U[2026-06-29 12:01:00Z]}
      },
      status: :ok,
      inserted_at: ~U[2026-06-29 12:00:00Z]
    }

    assert %{results: [result]} =
             PreviousSessions.search(@workspace_id,
               query: "12:01",
               sessions: [],
               audit_events: [],
               activity_entries: [activity],
               labels_by_session: %{}
             )

    assert result.id == "activity:activity-time"
    assert "metadata.nested.seen_at" in result.matched_fields
  end

  test "filters by workspace aliases without leaking mixed workspace rows" do
    alpha_activity = %{
      id: "activity-alpha",
      workspace_id: @workspace_id,
      source: :terminal_mcp,
      tool: "terminal_send_agent_prompt",
      summary: "session=devide_alpha_agent",
      metadata: %{
        session: "devide_alpha_agent",
        workspace_name: "alpha",
        text: "Alpha workspace prompt"
      },
      status: :ok,
      inserted_at: ~U[2026-06-29 12:00:00Z]
    }

    other_activity = %{
      id: "activity-other",
      workspace_id: "ws-other",
      source: :terminal_mcp,
      tool: "terminal_send_agent_prompt",
      summary: "session=devide_other_agent",
      metadata: %{
        session: "devide_other_agent",
        workspace_name: "beta",
        text: "Other workspace prompt"
      },
      status: :ok,
      inserted_at: ~U[2026-06-29 12:01:00Z]
    }

    shared_opts = [
      sessions: [],
      audit_events: [],
      activity_entries: [alpha_activity, other_activity],
      labels_by_session: %{},
      workspace_aliases: ["alpha"]
    ]

    assert %{workspace: "alpha", results: [%{id: "activity:activity-alpha"}]} =
             PreviousSessions.search(@workspace_id, Keyword.put(shared_opts, :workspace, "alpha"))

    assert %{workspace: "beta", results: []} =
             PreviousSessions.search(@workspace_id, Keyword.put(shared_opts, :workspace, "beta"))
  end

  test "searches session-directory metadata and exposes session status" do
    session =
      SessionInfo.new_shell(@workspace_id, "api-session",
        status: :active,
        metadata: %{
          session_alias: "Agent repair shell",
          cwd: "/workspace/dev_ide",
          git_branch: "feature/session-search",
          activity: 1_782_736_000
        }
      )
      |> Map.put(:tmux_session, "devide_alpha_api-session")

    assert %{results: [result]} =
             PreviousSessions.search(@workspace_id,
               query: "feature/session-search",
               sessions: [session],
               audit_events: [],
               activity_entries: [],
               labels_by_session: %{}
             )

    assert result.source == :session
    assert result.session == "devide_alpha_api-session"
    assert result.title == "Agent repair shell"
    assert result.status == "active"
    assert_href(result.href, "/workspaces/ws-alpha", %{"session" => "devide_alpha_api-session"})
    assert result.summary =~ "branch=feature/session-search"
    assert result.occurred_at == DateTime.from_unix!(1_782_736_000)
    assert "metadata.git_branch" in result.matched_fields

    assert %{results: [%{id: "session:shell_ws-alpha_api-session"} = status_result]} =
             PreviousSessions.search(@workspace_id,
               query: "active",
               sessions: [session],
               audit_events: [],
               activity_entries: [],
               labels_by_session: %{}
             )

    assert "status" in status_result.matched_fields
  end

  test "filters audit rows by session pane and date" do
    older =
      audit_event("audit-old", ~U[2026-06-27 12:00:00Z], %{
        "session" => "devide_alpha_agent",
        "pane" => "%4",
        "command" => "mix test test/dev_ide/old_test.exs"
      })

    newer =
      audit_event("audit-new", ~U[2026-06-29 12:00:00Z], %{
        "session" => "devide_alpha_agent",
        "pane" => "%4",
        "command" => "mix test test/dev_ide/previous_sessions_test.exs"
      })

    other_pane =
      audit_event("audit-pane", ~U[2026-06-29 12:00:01Z], %{
        "session" => "devide_alpha_agent",
        "pane" => "%5",
        "command" => "mix test test/dev_ide/previous_sessions_test.exs"
      })

    assert %{results: [result]} =
             PreviousSessions.search(@workspace_id,
               query: "previous_sessions",
               session: "alpha_agent",
               pane: "%4",
               since: ~U[2026-06-28 00:00:00Z],
               sessions: [],
               audit_events: [older, newer, other_pane],
               activity_entries: [],
               labels_by_session: %{}
             )

    assert result.id == "audit:audit-new"
    assert result.source == :audit
    assert result.session == "devide_alpha_agent"
    assert result.pane == "%4"
  end

  test "searches occurrence timestamps by date text" do
    activity = %{
      id: "activity-date",
      workspace_id: @workspace_id,
      source: :terminal_mcp,
      tool: "terminal_capture",
      summary: "session=devide_alpha_agent",
      metadata: %{session: "devide_alpha_agent"},
      status: :ok,
      inserted_at: ~U[2026-06-29 12:05:00Z]
    }

    assert %{results: [%{id: "activity:activity-date"} = result]} =
             PreviousSessions.search(@workspace_id,
               query: "2026-06-29T12:05",
               sessions: [],
               audit_events: [],
               activity_entries: [activity],
               labels_by_session: %{}
             )

    assert "occurred_at" in result.matched_fields
  end

  test "searches prompt audit titles excerpts and status metadata" do
    event =
      audit_event("audit-prompt", ~U[2026-06-29 12:00:00Z], %{
        "session" => "devide_alpha_agent",
        "pane" => "%2",
        "title" => "Fix preview auth",
        "prompt_excerpt" => "Fix preview auth\n\nRun focused tests",
        "status" => "done",
        "title_source" => "first_prompt",
        "tool" => "send_agent_prompt"
      })
      |> Map.put(:action, "terminal.agent_prompt_done")

    assert %{results: [result]} =
             PreviousSessions.search(@workspace_id,
               query: "preview auth",
               session: "alpha_agent",
               pane: "%2",
               sessions: [],
               audit_events: [event],
               activity_entries: [],
               labels_by_session: %{}
             )

    assert result.source == :audit
    assert result.title == "Fix preview auth"
    assert result.summary =~ "terminal.agent_prompt_done"
    assert "title" in result.matched_fields
    assert "metadata.prompt_excerpt" in result.matched_fields

    assert %{results: [%{id: "audit:audit-prompt"}]} =
             PreviousSessions.search(@workspace_id,
               query: "done",
               sessions: [],
               audit_events: [event],
               activity_entries: [],
               labels_by_session: %{}
             )
  end

  test "derives prompt audit status from action when metadata status is absent" do
    event =
      audit_event("audit-attention", ~U[2026-06-29 12:00:00Z], %{
        "session" => "devide_alpha_agent",
        "pane" => "%2",
        "title" => "Fix preview auth",
        "tool" => "send_agent_prompt"
      })
      |> Map.put(:action, "terminal.agent_prompt_attention")

    assert %{results: [%{status: "attention"} = result]} =
             PreviousSessions.search(@workspace_id,
               query: "attention",
               sessions: [],
               audit_events: [event],
               activity_entries: [],
               labels_by_session: %{}
             )

    assert result.id == "audit:audit-attention"
    assert "status" in result.matched_fields
  end

  test "derives running prompt audit status from action when metadata status is absent" do
    event =
      audit_event("audit-running", ~U[2026-06-29 12:00:00Z], %{
        "session" => "devide_alpha_agent",
        "pane" => "%2",
        "title" => "Fix preview auth",
        "tool" => "send_agent_prompt"
      })
      |> Map.put(:action, "terminal.agent_prompt_running")

    assert %{results: [%{status: "running"} = result]} =
             PreviousSessions.search(@workspace_id,
               query: "running",
               sessions: [],
               audit_events: [event],
               activity_entries: [],
               labels_by_session: %{}
             )

    assert result.id == "audit:audit-running"
    assert "status" in result.matched_fields
  end

  test "searches prompt activity titles excerpts and status metadata" do
    activity = %{
      id: "activity-prompt",
      workspace_id: @workspace_id,
      source: :terminal_mcp,
      tool: "send_agent_prompt",
      summary: "done: Fix preview auth · session=devide_alpha_agent pane=%2 chunks=2/2",
      metadata: %{
        "session" => "devide_alpha_agent",
        "pane" => "%2",
        "title" => "Fix preview auth",
        "prompt_excerpt" => "Fix preview auth\n\nRun focused tests",
        "status" => "done",
        "title_source" => "first_prompt",
        "tool" => "send_agent_prompt"
      },
      status: :ok,
      inserted_at: ~U[2026-06-29 12:00:00Z]
    }

    assert %{results: [result]} =
             PreviousSessions.search(@workspace_id,
               query: "preview auth",
               session: "alpha_agent",
               pane: "%2",
               sessions: [],
               audit_events: [],
               activity_entries: [activity],
               labels_by_session: %{}
             )

    assert result.source == :activity
    assert result.title == "Fix preview auth"
    assert result.summary =~ "done: Fix preview auth"
    assert "title" in result.matched_fields
    assert "metadata.prompt_excerpt" in result.matched_fields

    assert %{results: [%{id: "activity:activity-prompt"}]} =
             PreviousSessions.search(@workspace_id,
               query: "done",
               sessions: [],
               audit_events: [],
               activity_entries: [activity],
               labels_by_session: %{}
             )
  end

  test "promotes activity error status when metadata status is absent" do
    activity = %{
      id: "activity-error",
      workspace_id: @workspace_id,
      source: :terminal_mcp,
      tool: "send_agent_prompt",
      summary: "failed to paste prompt",
      metadata: %{
        "session" => "devide_alpha_agent",
        "pane" => "%2",
        "title" => "Fix preview auth"
      },
      status: :error,
      inserted_at: ~U[2026-06-29 12:00:00Z]
    }

    assert %{results: [%{status: "error"} = result]} =
             PreviousSessions.search(@workspace_id,
               query: "error",
               sessions: [],
               audit_events: [],
               activity_entries: [activity],
               labels_by_session: %{}
             )

    assert result.id == "activity:activity-error"
    assert "status" in result.matched_fields
  end

  test "promotes preview MCP context for session-linked browser history" do
    activity = %{
      id: "preview-activity",
      workspace_id: @workspace_id,
      source: :preview_mcp,
      tool: "preview_screenshot",
      summary: "preview_screenshot · session preview-123",
      metadata: %{
        "agent_session" => "devide_alpha_agent",
        "agent_pane" => "%2",
        "session_id" => "preview-123",
        "pane_id" => "%8",
        "preview_title" => "Dashboard",
        "preview_status" => "ready",
        "url" => "http://localhost:5173/dashboard",
        "source_url" => "http://localhost:5173/dashboard",
        "display_url" => "/preview-proxy/ws-alpha/5173/dashboard",
        "screenshot_url" => "/preview-artifacts/ws-alpha/snap.png",
        "artifact_url" => "/preview-artifacts/ws-alpha/snap.png",
        "recording_id" => "rec-123",
        "recording_url" => "/preview-artifacts/ws-alpha/rec-123.webm",
        "recording_path" => "/preview-artifacts/ws-alpha/rec-123.webm",
        "recording_status" => "recorded",
        "status" => "done"
      },
      status: :ok,
      inserted_at: ~U[2026-06-29 12:00:00Z]
    }

    assert %{results: [result]} =
             PreviousSessions.search(@workspace_id,
               query: "snap.png",
               session: "preview-123",
               pane: "%8",
               sessions: [],
               audit_events: [],
               activity_entries: [activity],
               labels_by_session: %{}
             )

    assert result.source == :activity
    assert result.session == "preview-123"
    assert result.pane == "%8"
    assert_href(result.href, "/workspaces/ws-alpha", %{})

    assert result.preview == %{
             agent_action: "preview_screenshot",
             agent_session: "devide_alpha_agent",
             agent_pane: "%2",
             tool: "preview_screenshot",
             session_id: "preview-123",
             pane: "%8",
             title: "Dashboard",
             status: "ready",
             url: "http://localhost:5173/dashboard",
             source_url: "http://localhost:5173/dashboard",
             display_url: "/preview-proxy/ws-alpha/5173/dashboard",
             screenshot_url: "/preview-artifacts/ws-alpha/snap.png",
             artifact_url: "/preview-artifacts/ws-alpha/snap.png",
             recording_id: "rec-123",
             recording_url: "/preview-artifacts/ws-alpha/rec-123.webm",
             recording_path: "/preview-artifacts/ws-alpha/rec-123.webm",
             recording_status: "recorded"
           }

    assert "preview.screenshot_url" in result.matched_fields
    assert "metadata.screenshot_url" in result.matched_fields

    assert %{results: [%{id: "activity:preview-activity"} = recording_result]} =
             PreviousSessions.search(@workspace_id,
               query: "rec-123",
               sessions: [],
               audit_events: [],
               activity_entries: [activity],
               labels_by_session: %{}
             )

    assert "preview.recording_id" in recording_result.matched_fields
    assert "preview.recording_url" in recording_result.matched_fields
  end

  test "filters results by source including preview-context rows" do
    audit =
      audit_event("audit-source", ~U[2026-06-29 12:00:00Z], %{
        "session" => "devide_alpha_agent",
        "command" => "mix test"
      })

    activity = %{
      id: "activity-source",
      workspace_id: @workspace_id,
      source: :terminal_mcp,
      tool: "terminal_capture",
      summary: "mix test output",
      metadata: %{session: "devide_alpha_agent"},
      status: :ok,
      inserted_at: ~U[2026-06-29 12:01:00Z]
    }

    preview_activity = %{
      id: "preview-source",
      workspace_id: @workspace_id,
      source: :preview_mcp,
      tool: "preview_open_app",
      summary: "preview_open_app",
      metadata: %{
        session_id: "preview-session",
        display_url: "/preview-proxy/ws-alpha/4000",
        status: "done"
      },
      status: :ok,
      inserted_at: ~U[2026-06-29 12:02:00Z]
    }

    shared_opts = [
      query: "",
      sessions: [],
      audit_events: [audit],
      activity_entries: [activity, preview_activity],
      labels_by_session: %{}
    ]

    assert %{source: "audit", results: [%{id: "audit:audit-source"}]} =
             PreviousSessions.search(@workspace_id, Keyword.put(shared_opts, :source, :audit))

    assert %{source: "activity", results: activity_results} =
             PreviousSessions.search(@workspace_id, Keyword.put(shared_opts, :source, "activity"))

    assert Enum.map(activity_results, & &1.id) == [
             "activity:preview-source",
             "activity:activity-source"
           ]

    assert %{source: "preview", results: [%{id: "activity:preview-source", preview: preview}]} =
             PreviousSessions.search(@workspace_id, Keyword.put(shared_opts, :source, "preview"))

    assert preview.display_url == "/preview-proxy/ws-alpha/4000"

    assert %{source: ["activity", "preview"], results: combined_results} =
             PreviousSessions.search(
               @workspace_id,
               Keyword.put(shared_opts, :source, "activity,preview")
             )

    assert Enum.map(combined_results, & &1.id) == [
             "activity:preview-source",
             "activity:activity-source"
           ]
  end

  test "discovers live pane labels for known tmux sessions" do
    session =
      SessionInfo.new_shell(@workspace_id, "u-dev",
        metadata: %{session_alias: "Dev shell", activity: 1_782_736_000}
      )
      |> Map.put(:tmux_session, "devide_alpha_u-dev")

    labels = %{
      "devide_alpha_u-dev" => %{
        "devide_alpha_u-dev::%1" => %{
          label: "Checkout restore flow",
          base_label: "Checkout restore flow",
          source: :agent,
          tool: "terminal_set_agent_label",
          frozen?: false,
          updated_at: ~U[2026-06-29 12:30:00Z]
        }
      }
    }

    assert %{results: [result]} =
             PreviousSessions.search(@workspace_id,
               query: "restore",
               sessions: [session],
               audit_events: [],
               activity_entries: [],
               labels_by_session: labels
             )

    assert result.source == :label
    assert result.session == "devide_alpha_u-dev"
    assert result.pane == "%1"
    assert result.title == "Checkout restore flow"
  end

  test "clamps result limits and bounds audit and activity fetches" do
    test_pid = self()

    session_reader = fn workspace_id, opts ->
      send(test_pid, {:session_reader, workspace_id, opts})
      []
    end

    audit_reader = fn workspace_id, limit ->
      send(test_pid, {:audit_reader, workspace_id, limit})
      []
    end

    activity_reader = fn workspace_id, limit ->
      send(test_pid, {:activity_reader, workspace_id, limit})
      []
    end

    assert %{limit: 50, results: []} =
             PreviousSessions.search(@workspace_id,
               query: "anything",
               limit: 999,
               session_reader: session_reader,
               audit_reader: audit_reader,
               activity_reader: activity_reader,
               labels_by_session: %{}
             )

    assert_receive {:session_reader, @workspace_id, []}
    assert_receive {:audit_reader, @workspace_id, 200}
    assert_receive {:activity_reader, @workspace_id, 200}

    assert %{limit: 20, results: []} =
             PreviousSessions.search(@workspace_id,
               query: "anything",
               source_limit: 9_999,
               session_reader: session_reader,
               audit_reader: audit_reader,
               activity_reader: activity_reader,
               labels_by_session: %{}
             )

    assert_receive {:session_reader, @workspace_id, []}
    assert_receive {:audit_reader, @workspace_id, 1_000}
    assert_receive {:activity_reader, @workspace_id, 1_000}

    assert %{limit: 20, results: []} =
             PreviousSessions.search(@workspace_id,
               query: "anything",
               source_limit: "bad",
               session_reader: session_reader,
               audit_reader: audit_reader,
               activity_reader: activity_reader,
               labels_by_session: %{}
             )

    assert_receive {:session_reader, @workspace_id, []}
    assert_receive {:audit_reader, @workspace_id, 200}
    assert_receive {:activity_reader, @workspace_id, 200}
  end

  test "empty query returns recent rows sorted newest first" do
    audit =
      audit_event("audit-1", ~U[2026-06-29 12:00:00Z], %{
        "session" => "devide_alpha_agent",
        "command" => "mix test"
      })

    activity = %{
      id: "activity-1",
      workspace_id: @workspace_id,
      source: :terminal_mcp,
      tool: "terminal_capture",
      summary: "session=devide_alpha_agent",
      metadata: %{session: "devide_alpha_agent"},
      status: :ok,
      inserted_at: ~U[2026-06-29 12:05:00Z]
    }

    assert %{results: [first, second]} =
             PreviousSessions.search(@workspace_id,
               query: "",
               limit: 2,
               sessions: [],
               audit_events: [audit],
               activity_entries: [activity],
               labels_by_session: %{}
             )

    assert first.id == "activity:activity-1"
    assert second.id == "audit:audit-1"
    assert first.matched_fields == []
  end

  defp audit_event(id, inserted_at, metadata) do
    %Event{
      id: id,
      workspace_id: @workspace_id,
      actor_id: "mcp",
      action: "agent.terminal_terminal_send_command",
      target_type: "session",
      target_ref: Map.get(metadata, "session"),
      decision: :allow,
      reason: nil,
      metadata: metadata,
      inserted_at: inserted_at
    }
  end

  defp assert_href(href, path, query) do
    uri = URI.parse(href)
    assert uri.path == path
    assert URI.decode_query(uri.query || "") == query
  end
end
