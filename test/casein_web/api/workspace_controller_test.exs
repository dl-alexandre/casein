defmodule CaseinWeb.API.WorkspaceControllerTest do
  use CaseinWeb.ConnCase, async: false

  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.MemoryAdapter
  alias Casein.Workspaces.DbIsolation
  alias Casein.Workspace
  alias Casein.Terminals.Templates

  @token "test-token"
  @api_session Casein.Terminals.Tmux.session_name("alpha", "api-session")

  setup %{conn: conn} do
    MemoryAdapter.clear()
    Casein.Audit.MemoryAdapter.clear()
    Casein.Agents.Activity.clear()
    prev_token = Application.get_env(:casein, :api_token)
    prev_workspace_tokens = Application.get_env(:casein, :workspace_api_tokens)
    prev_tmux_adapter = Application.get_env(:casein, :tmux_adapter)
    prev_fake_tmux_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
    prev_fake_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_fake_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)
    prev_fake_next_window = TmuxCtl.Test.FakeState.get(:fake_tmux_next_window)
    prev_agent_mcp_base_url = Application.get_env(:casein, :agent_mcp_base_url)

    Application.put_env(:casein, :api_token, @token)
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())
    # Deferred window closes are global and outlive a test; a leftover pending
    # entry would hide a window from an unrelated test's topology.
    Casein.Terminals.WindowTrash.__reset__()
    Application.put_env(:casein, :agent_mcp_base_url, "http://127.0.0.1:4000")

    on_exit(fn ->
      MemoryAdapter.clear()
      Casein.Audit.MemoryAdapter.clear()
      Casein.Agents.Activity.clear()
      Casein.Terminals.WindowTrash.__reset__()

      if prev_token,
        do: Application.put_env(:casein, :api_token, prev_token),
        else: Application.delete_env(:casein, :api_token)

      if prev_workspace_tokens,
        do: Application.put_env(:casein, :workspace_api_tokens, prev_workspace_tokens),
        else: Application.delete_env(:casein, :workspace_api_tokens)

      if prev_tmux_adapter,
        do: Application.put_env(:casein, :tmux_adapter, prev_tmux_adapter),
        else: Application.delete_env(:casein, :tmux_adapter)

      if prev_fake_tmux_pid,
        do: TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, prev_fake_tmux_pid),
        else: TmuxCtl.Test.FakeState.delete(:fake_tmux_test_pid)

      if prev_fake_windows,
        do: TmuxCtl.Test.FakeState.put(:fake_tmux_windows, prev_fake_windows),
        else: TmuxCtl.Test.FakeState.delete(:fake_tmux_windows)

      if prev_fake_panes,
        do: TmuxCtl.Test.FakeState.put(:fake_tmux_panes, prev_fake_panes),
        else: TmuxCtl.Test.FakeState.delete(:fake_tmux_panes)

      if prev_fake_next_window,
        do: TmuxCtl.Test.FakeState.put(:fake_tmux_next_window, prev_fake_next_window),
        else: TmuxCtl.Test.FakeState.delete(:fake_tmux_next_window)

      if prev_agent_mcp_base_url,
        do: Application.put_env(:casein, :agent_mcp_base_url, prev_agent_mcp_base_url),
        else: Application.delete_env(:casein, :agent_mcp_base_url)
    end)

    {:ok, conn: conn}
  end

  defp authed(conn, token \\ @token),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)

  defp seed_workspace(opts \\ []) do
    root = Keyword.get(opts, :root)
    db_isolation = Keyword.get(opts, :db_isolation)

    {:ok, _} =
      State.sync(%Workspace{
        id: "ws-1",
        name: "alpha",
        user: "alice",
        branch: "main",
        status: :running,
        path: root,
        metadata: %{
          "id" => "ws-1",
          "name" => "alpha",
          "DATABASE_URL" => "postgres://u:hunter2@stage.rds.amazonaws.com/app",
          "password" => "hunter2",
          "ports" => %{"app" => 4000}
        }
      })

    if db_isolation do
      {:ok, _} =
        State.persist_isolation("ws-1", %DbIsolation{
          isolation: db_isolation,
          source: :env_file,
          summary: Atom.to_string(db_isolation),
          detected_at: DateTime.utc_now()
        })
    end
  end

  test "401 without token", %{conn: conn} do
    conn = get(conn, "/api/workspaces")
    assert conn.status == 401
  end

  test "503 when token is unset", %{conn: conn} do
    prev_env = System.get_env("CASEIN_API_TOKEN")
    prev_ws_env = System.get_env("CASEIN_WORKSPACE_API_TOKENS")
    prev_ws_tokens = Application.get_env(:casein, :workspace_api_tokens)

    on_exit(fn ->
      if prev_env,
        do: System.put_env("CASEIN_API_TOKEN", prev_env),
        else: System.delete_env("CASEIN_API_TOKEN")

      if prev_ws_env,
        do: System.put_env("CASEIN_WORKSPACE_API_TOKENS", prev_ws_env),
        else: System.delete_env("CASEIN_WORKSPACE_API_TOKENS")

      if prev_ws_tokens,
        do: Application.put_env(:casein, :workspace_api_tokens, prev_ws_tokens),
        else: Application.delete_env(:casein, :workspace_api_tokens)
    end)

    Application.delete_env(:casein, :api_token)
    System.delete_env("CASEIN_API_TOKEN")

    # Earlier tests may have minted workspace-scoped tokens into the registry
    # (Casein.Agents.WorkspaceTokens); 503 means NO token source is configured.
    Application.delete_env(:casein, :workspace_api_tokens)
    System.delete_env("CASEIN_WORKSPACE_API_TOKENS")

    conn = get(conn, "/api/workspaces")
    assert conn.status == 503
    assert json_response(conn, 503) == %{"error" => "api_token_not_configured"}
  end

  test "/api/workspaces lists synced records", %{conn: conn} do
    seed_workspace()
    body = conn |> authed() |> get("/api/workspaces") |> json_response(200)
    assert is_list(body)
    [ws] = body
    assert ws["id"] == "ws-1"
    assert ws["name"] == "alpha"
    assert ws["status"] == "running"
  end

  test "/api/workspaces/:id/status returns mode + isolation + recent fields", %{conn: conn} do
    seed_workspace()
    body = conn |> authed() |> get("/api/workspaces/ws-1/status") |> json_response(200)

    assert body["workspace"]["id"] == "ws-1"
    assert body["mode"]["value"]
    assert body["mode"]["source"]
    assert body["db_isolation"]
    assert is_list(body["agent_capabilities"])

    preview_mcp =
      Enum.find(body["agent_capabilities"], &(&1["kind"] == "preview_mcp"))

    assert preview_mcp["status"] == "detected"
    assert preview_mcp["url"] == "http://127.0.0.1:4000/api/preview/mcp?workspace_id=ws-1"
    assert preview_mcp["details"]["workspace_id"] == "ws-1"
    assert preview_mcp["details"]["pre_scoped"] == true
    assert "preview_open_app" in preview_mcp["details"]["tools"]
    assert is_map(body["deploy"])
    assert is_binary(body["deploy"]["running_revision"])
    assert is_boolean(body["deploy"]["ok"])
    assert is_map(body["deploy"]["checks"])
    assert "preview_close" in preview_mcp["details"]["tools"]

    artifact_mcp =
      Enum.find(body["agent_capabilities"], &(&1["kind"] == "artifact_mcp"))

    assert artifact_mcp["status"] == "detected"
    assert artifact_mcp["url"] == "http://127.0.0.1:4000/api/artifacts/mcp?workspace_id=ws-1"
    assert artifact_mcp["details"]["workspace_id"] == "ws-1"
    assert artifact_mcp["details"]["pre_scoped"] == true
    assert "artifact_create" in artifact_mcp["details"]["tools"]
    assert "artifact_update" in artifact_mcp["details"]["tools"]

    code_mcp =
      Enum.find(body["agent_capabilities"], &(&1["kind"] == "code_mcp"))

    assert code_mcp["status"] == "detected"
    assert code_mcp["url"] == "http://127.0.0.1:4000/api/code/mcp?workspace_id=ws-1"
    assert code_mcp["details"]["workspace_id"] == "ws-1"
    assert code_mcp["details"]["pre_scoped"] == true
    assert "code_read" in code_mcp["details"]["tools"]
    assert "code_apply_patch" in code_mcp["details"]["tools"]

    terminal_mcp =
      Enum.find(body["agent_capabilities"], &(&1["kind"] == "terminal_mcp"))

    assert terminal_mcp["status"] == "detected"
    assert terminal_mcp["url"] == "http://127.0.0.1:4000/api/terminals/mcp?workspace_id=ws-1"
    assert terminal_mcp["details"]["workspace_id"] == "ws-1"
    assert terminal_mcp["details"]["pre_scoped"] == true
    assert "terminal_list_sessions" in terminal_mcp["details"]["tools"]
    assert "terminal_capture" in terminal_mcp["details"]["tools"]

    assert is_list(body["agent_sessions"])
    assert is_map(body["agent_layout"])
    assert body["agent_layout"]["status"] in ["no_sessions", "ready", "missing_agent_pane"]
    assert body["agent_layout"]["required_role"] == "agent"
    assert body["agent_layout"]["suggested_template"] == "agent_pair"
    assert is_list(body["recent_runs"])
    assert is_list(body["recent_proposals"])
    assert is_list(body["recent_audit"])
  end

  test "/api/workspaces/:id/topology returns tmux topology for an explicit session", %{conn: conn} do
    seed_workspace()

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      @api_session => [
        %{
          id: "@1",
          index: 0,
          name: "server",
          active: true,
          panes: 1,
          activity: 0,
          current_command: "mix"
        },
        %{
          id: "@2",
          index: 1,
          name: "tests",
          active: false,
          panes: 1,
          activity: 0,
          current_command: "bash"
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      @api_session => [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 120,
          height: 40,
          current_command: "mix",
          current_path: "/workspace",
          activity: 123,
          activity_flag: true,
          bell: false,
          unseen_changes: true
        },
        %{
          id: "%2",
          window_id: "@2",
          index: 0,
          active: false,
          left: 0,
          top: 0,
          width: 80,
          height: 24,
          current_command: "bash",
          current_path: "/workspace/test",
          activity: 456,
          activity_flag: false,
          bell: true,
          unseen_changes: false
        }
      ]
    })

    body =
      conn
      |> authed()
      |> get("/api/workspaces/ws-1/topology", %{"session" => @api_session})
      |> json_response(200)

    assert body["workspace_id"] == "ws-1"
    assert body["session"] == @api_session
    assert body["active_window_id"] == "@1"
    assert body["active_pane_id"] == "%1"
    assert is_integer(body["version"])

    assert [
             %{"id" => "@1", "name" => "server", "pane_list" => [%{"id" => "%1"}]},
             %{"id" => "@2", "name" => "tests", "pane_list" => [%{"id" => "%2"}]}
           ] =
             body["windows"]

    assert [
             %{
               "id" => "%1",
               "window_id" => "@1",
               "current_path" => "/workspace",
               "activity" => 123,
               "bell" => false
             },
             %{
               "id" => "%2",
               "window_id" => "@2",
               "current_path" => "/workspace/test",
               "activity" => 456,
               "bell" => true
             }
           ] = body["panes"]
  end

  test "/api/workspaces/:id/topology requires a session query param", %{conn: conn} do
    seed_workspace()

    body =
      conn
      |> authed()
      |> get("/api/workspaces/ws-1/topology")
      |> json_response(422)

    assert body == %{"error" => "session_required"}
  end

  test "/api/workspaces/:id/topology rejects a session outside workspace scope", %{conn: conn} do
    seed_workspace()

    other_session = Casein.Terminals.Tmux.session_name("beta", "api-session")
    seed_tmux_session(other_session)

    body =
      conn
      |> authed()
      |> get("/api/workspaces/ws-1/topology", %{"session" => other_session})
      |> json_response(422)

    assert body == %{"error" => "invalid_tmux_session_scope"}
  end

  test "GET /api/workspaces/:id/previous_sessions searches bounded session context", %{
    conn: conn
  } do
    seed_workspace()

    Casein.Agents.Activity.record(%{
      workspace_id: "ws-1",
      source: :terminal_mcp,
      tool: "terminal_send_agent_prompt",
      summary: "session=#{@api_session} pane=%4",
      metadata: %{
        session: @api_session,
        pane: "%4",
        text: "Old compile warning",
        status: :ignored
      },
      status: :ok,
      inserted_at: ~U[2026-06-28 10:00:00Z]
    })

    Casein.Agents.Activity.record(%{
      workspace_id: "ws-1",
      source: :terminal_mcp,
      tool: "terminal_send_agent_prompt",
      summary: "session=#{@api_session} pane=%3",
      metadata: %{
        session: @api_session,
        pane: "%3",
        text: "Restart Phoenix preview Bearer abc123",
        token: "secret-token",
        status: :queued,
        nested: %{seen_at: ~U[2026-06-29 12:01:00Z]}
      },
      status: :ok,
      inserted_at: ~U[2026-06-29 12:00:00Z]
    })

    body =
      conn
      |> authed()
      |> get("/api/workspaces/ws-1/previous_sessions", %{
        "query" => "phoenix",
        "workspace" => "alpha",
        "source" => "activity",
        "session" => "api-session",
        "pane" => "%3",
        "since" => "2026-06-29",
        "limit" => "5"
      })
      |> json_response(200)

    assert body["workspace_id"] == "ws-1"
    assert body["query"] == "phoenix"
    assert body["workspace"] == "alpha"
    assert body["source"] == "activity"
    assert body["limit"] == 5

    assert [
             %{
               "source" => "activity",
               "session" => @api_session,
               "pane" => "%3",
               "href" => href,
               "status" => "queued",
               "occurred_at" => "2026-06-29T12:00:00Z",
               "metadata" => metadata
             }
           ] = body["results"]

    assert href_query(href) == %{"session" => @api_session, "pane" => "%3"}
    assert metadata["text"] == "Restart Phoenix preview Bearer [REDACTED]"
    refute Map.has_key?(metadata, "token")
    assert metadata["status"] == "queued"
    assert metadata["nested"]["seen_at"] == "2026-06-29T12:01:00Z"
  end

  test "GET /api/workspaces/:id/previous_sessions exposes safe preview history context", %{
    conn: conn
  } do
    seed_workspace()

    Casein.Agents.Activity.record(%{
      workspace_id: "ws-1",
      source: :preview_mcp,
      tool: "preview_record_stop",
      summary: "preview_record_stop · rec-api.webm",
      metadata: %{
        "agent_session" => @api_session,
        "agent_pane" => "%3",
        "session_id" => "preview-api",
        "pane_id" => "%8",
        "preview_title" => "API Preview",
        "preview_status" => "ready",
        "url" => "http://localhost:4000/dashboard?token=secret-token",
        "display_url" => "/preview-proxy/ws-1/4000/dashboard",
        "screenshot_url" => "/preview-artifacts/ws-1/snap-api.png",
        "recording_id" => "rec-api",
        "recording_url" => "/preview-artifacts/ws-1/rec-api.webm?token=secret-token",
        "recording_status" => "recorded",
        "token" => "secret-token"
      },
      status: :ok,
      inserted_at: ~U[2026-06-29 13:00:00Z]
    })

    body =
      conn
      |> authed()
      |> get("/api/workspaces/ws-1/previous_sessions", %{
        "query" => "rec-api",
        "source" => "preview",
        "limit" => "5"
      })
      |> json_response(200)

    assert body["workspace_id"] == "ws-1"
    assert body["source"] == "preview"

    assert [
             %{
               "source" => "activity",
               "session" => "preview-api",
               "pane" => "%8",
               "href" => "/workspaces/ws-1",
               "preview" => preview,
               "metadata" => metadata,
               "matched_fields" => matched_fields
             }
           ] = body["results"]

    assert preview["agent_action"] == "preview_record_stop"
    assert preview["agent_session"] == @api_session
    assert preview["agent_pane"] == "%3"
    assert preview["tool"] == "preview_record_stop"
    assert preview["session_id"] == "preview-api"
    assert preview["pane"] == "%8"
    assert preview["title"] == "API Preview"
    assert preview["status"] == "ready"
    assert preview["display_url"] == "/preview-proxy/ws-1/4000/dashboard"
    assert preview["screenshot_url"] == "/preview-artifacts/ws-1/snap-api.png"
    assert preview["recording_id"] == "rec-api"
    assert preview["recording_url"] == "/preview-artifacts/ws-1/rec-api.webm?token=[REDACTED]"
    assert preview["recording_status"] == "recorded"
    assert preview["url"] == "http://localhost:4000/dashboard?token=[REDACTED]"

    assert "preview.recording_id" in matched_fields
    assert "preview.recording_url" in matched_fields
    refute Map.has_key?(metadata, "token")
    refute inspect(body) =~ "secret-token"
  end

  test "GET /api/workspaces/:id/previous_sessions honors source_limit", %{conn: conn} do
    seed_workspace()

    Casein.Agents.Activity.record(%{
      workspace_id: "ws-1",
      source: :terminal_mcp,
      tool: "terminal_send_agent_prompt",
      summary: "session=#{@api_session} pane=%3",
      metadata: %{
        session: @api_session,
        pane: "%3",
        text: "deep-source-limit-target"
      },
      status: :ok,
      inserted_at: ~U[2026-06-29 11:00:00Z]
    })

    for index <- 1..10 do
      Casein.Agents.Activity.record(%{
        workspace_id: "ws-1",
        source: :terminal_mcp,
        tool: "terminal_send_agent_prompt",
        summary: "filler #{index}",
        metadata: %{
          session: @api_session,
          pane: "%#{index + 10}",
          text: "filler prompt #{index}"
        },
        status: :ok,
        inserted_at: DateTime.add(~U[2026-06-29 11:00:00Z], index, :second)
      })
    end

    shallow =
      conn
      |> authed()
      |> get("/api/workspaces/ws-1/previous_sessions", %{
        "query" => "deep-source-limit-target",
        "source" => "activity",
        "source_limit" => "5"
      })
      |> json_response(200)

    assert shallow["results"] == []

    deep =
      conn
      |> recycle()
      |> authed()
      |> get("/api/workspaces/ws-1/previous_sessions", %{
        "query" => "deep-source-limit-target",
        "source" => "activity",
        "source_limit" => "20"
      })
      |> json_response(200)

    assert [%{"source" => "activity", "metadata" => %{"text" => "deep-source-limit-target"}}] =
             deep["results"]
  end

  test "GET /api/workspaces/:id/previous_sessions clamps the limit", %{conn: conn} do
    seed_workspace()

    body =
      conn
      |> authed()
      |> get("/api/workspaces/ws-1/previous_sessions", %{"limit" => "999"})
      |> json_response(200)

    assert body["limit"] == Casein.PreviousSessions.max_limit()
  end

  test "GET /api/workspaces/:id/previous_sessions returns 404 for unknown workspace", %{
    conn: conn
  } do
    body =
      conn
      |> authed()
      |> get("/api/workspaces/missing/previous_sessions")
      |> json_response(404)

    assert body == %{"error" => "not_found"}
  end

  test "workspace-scoped token can search only its workspace history", %{conn: conn} do
    seed_workspace()
    Application.put_env(:casein, :workspace_api_tokens, %{"ws-token" => "ws-1"})

    own =
      conn
      |> authed("ws-token")
      |> get("/api/workspaces/ws-1/previous_sessions")
      |> json_response(200)

    assert own["workspace_id"] == "ws-1"

    forbidden =
      conn
      |> recycle()
      |> authed("ws-token")
      |> get("/api/workspaces/ws-2/previous_sessions")
      |> json_response(403)

    assert forbidden == %{"error" => "workspace_forbidden"}
  end

  test "GET /api/workspaces/:id/templates lists built-in session templates", %{conn: conn} do
    seed_workspace()

    body =
      conn
      |> authed()
      |> get("/api/workspaces/ws-1/templates")
      |> json_response(200)

    assert Enum.map(body, & &1["id"]) == [
             "agent_pair",
             "agent_preview_demo",
             "generic_project",
             "phoenix_dev"
           ]

    assert Enum.find(body, &(&1["id"] == "generic_project")) == %{
             "id" => "generic_project",
             "name" => "Generic Project",
             "description" => "Shell, git status, and a scratch pane.",
             "source" => "built_in",
             "schema_version" => 1,
             "apply_supported" => true,
             "tags" => [],
             "windows" => 1,
             "panes" => 3
           }
  end

  test "GET /api/workspaces/:id/templates/export exports current tmux topology", %{conn: conn} do
    seed_workspace(root: "/workspace")
    seed_tmux_session(@api_session)

    body =
      conn
      |> authed()
      |> get("/api/workspaces/ws-1/templates/export", %{
        "session" => @api_session,
        "name" => "current_layout"
      })
      |> json_response(200)

    assert body["workspace_id"] == "ws-1"
    assert body["session"] == @api_session
    assert body["template"]["version"] == 2
    assert body["template"]["name"] == "current_layout"
    assert body["template"]["root"] == "${workspace_root}"
    assert body["template"]["metadata"]["session"] == @api_session
    assert body["template"]["startup"] == %{"window" => "server", "pane" => "mix"}

    assert [
             %{
               "name" => "server",
               "root" => "${workspace_root}",
               "focus" => true,
               "layout" => %{"name" => "mix", "focus" => true}
             },
             %{
               "name" => "tests",
               "root" => "${workspace_root}/test",
               "layout" => %{"name" => "shell"}
             }
           ] = body["template"]["windows"]

    assert body["yaml"] =~ "version: 2"
    assert body["yaml"] =~ ~s(name: "current_layout")
  end

  test "POST /api/workspaces/:id/templates/export saves current tmux topology", %{conn: conn} do
    seed_workspace(root: "/workspace")
    seed_tmux_session(@api_session)

    body =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/templates/export", %{
        "session" => @api_session,
        "name" => "saved_layout",
        "description" => "Exported from a live session",
        "tags" => ["phoenix", "daily"]
      })
      |> json_response(201)

    assert body["action"] == "template_exported"
    assert body["dry_run"] == false
    assert body["workspace_id"] == "ws-1"
    assert body["session"] == @api_session
    assert body["template"]["version"] == 2
    assert body["template"]["name"] == "saved_layout"
    assert body["yaml"] =~ ~s(name: "saved_layout")
    assert body["topology"]["active_pane_id"] == "%1"

    assert %{
             "id" => saved_id,
             "workspace_id" => "ws-1",
             "name" => "saved_layout",
             "description" => "Exported from a live session",
             "source" => "exported",
             "schema_version" => 2,
             "apply_supported" => true,
             "source_session" => @api_session,
             "tags" => ["phoenix", "daily"],
             "windows" => 2,
             "panes" => 2
           } = body["saved_template"]

    assert body["result"]["id"] == saved_id

    listed =
      conn
      |> authed()
      |> get("/api/workspaces/ws-1/templates")
      |> json_response(200)

    assert Enum.map(listed, & &1["id"]) == [
             "agent_pair",
             "agent_preview_demo",
             "generic_project",
             "phoenix_dev",
             saved_id
           ]

    assert Enum.find(listed, &(&1["id"] == saved_id))["apply_supported"] == true
    assert Enum.find(listed, &(&1["id"] == saved_id))["tags"] == ["phoenix", "daily"]

    filtered =
      conn
      |> authed()
      |> get("/api/workspaces/ws-1/templates", %{"tag" => "phoenix"})
      |> json_response(200)

    assert Enum.map(filtered, & &1["id"]) == [saved_id]

    filtered_out =
      conn
      |> authed()
      |> get("/api/workspaces/ws-1/templates", %{"filter" => %{"tag" => "rust"}})
      |> json_response(200)

    assert filtered_out == []

    assert [%{action: "tmux.template_exported", target_ref: ^saved_id} = event] =
             Casein.Audit.recent_for("ws-1", 1)

    assert event.target_type == "tmux_template"
    assert event.metadata.session == @api_session
    assert event.metadata.template_name == "saved_layout"
    assert event.metadata.topology_version
  end

  test "POST /api/workspaces/:id/templates/export supports dry-run without saving", %{conn: conn} do
    seed_workspace(root: "/workspace")
    seed_tmux_session(@api_session)

    body =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/templates/export", %{
        "session" => @api_session,
        "name" => "dry_saved_layout",
        "dry_run" => true
      })
      |> json_response(200)

    assert body["action"] == "template_exported"
    assert body["dry_run"] == true
    assert body["template"]["name"] == "dry_saved_layout"
    assert body["topology"]["active_pane_id"] == "%1"

    listed =
      conn
      |> authed()
      |> get("/api/workspaces/ws-1/templates")
      |> json_response(200)

    refute Enum.any?(listed, &(&1["id"] == "dry_saved_layout"))

    refute Enum.any?(
             Casein.Audit.recent_for("ws-1", 10),
             &(&1.action == "tmux.template_exported")
           )
  end

  test "POST /api/workspaces/:id/templates/:template_id/apply supports dry-run", %{conn: conn} do
    seed_workspace()
    seed_tmux_session(@api_session)

    body =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/templates/generic_project/apply", %{
        "session" => @api_session,
        "dry_run" => true
      })
      |> json_response(200)

    assert body["action"] == "template_applied"
    assert body["dry_run"] == true
    assert body["result"]["template"]["id"] == "generic_project"
    assert body["result"]["step_count"] == 5
    assert body["topology"]["active_window_id"] == "@1"
    refute_received {:fake_tmux_new_window, @api_session, _}

    refute Enum.any?(
             Casein.Audit.recent_for("ws-1", 10),
             &(&1.action == "tmux.template_applied")
           )
  end

  test "POST /api/workspaces/:id/templates/:template_id/apply executes template", %{conn: conn} do
    root = temp_workspace_root!()
    seed_workspace(root: root)
    seed_tmux_session(@api_session)
    TmuxCtl.Test.FakeState.put(:fake_tmux_next_window, %{@api_session => "@3"})

    body =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/templates/generic_project/apply", %{
        "session" => @api_session
      })
      |> json_response(200)

    assert body["action"] == "template_applied"
    assert body["dry_run"] == false
    assert body["result"]["template"]["id"] == "generic_project"
    assert body["result"]["step_count"] == 5
    assert body["result"]["refs"]["window:shell"] == "@3"
    assert body["result"]["refs"]["pane:shell:root"] == "%3"
    assert body["result"]["refs"]["pane:shell:git"] == "%4"
    assert body["result"]["refs"]["pane:shell:scratch"] == "%5"
    assert body["topology"]["active_window_id"] == "@3"
    assert body["topology"]["active_pane_id"] == "%3"

    assert_receive {:fake_tmux_new_window, @api_session, opts}
    assert opts[:name] == "shell"
    assert opts[:cwd] == root

    assert_receive {:fake_tmux_split_pane, @api_session, "%3", "v", "%4"}
    assert_receive {:fake_tmux_send_command, @api_session, "%4", "git status --short", _}
    assert_receive {:fake_tmux_split_pane, @api_session, "%3", "h", "%5"}
    assert_receive {:fake_tmux_select_pane, @api_session, "%3"}

    assert [%{action: "tmux.template_applied", target_ref: "generic_project"} = event] =
             Casein.Audit.recent_for("ws-1", 1)

    assert event.target_type == "tmux_template"
    assert event.metadata.session == @api_session
    assert event.metadata.step_count == 5
    assert event.metadata.refs["window:shell"] == "@3"
  end

  test "POST /api/workspaces/:id/templates/:template_id/apply supports saved v2 dry-run", %{
    conn: conn
  } do
    root = temp_workspace_root!()
    seed_workspace(root: root)
    seed_tmux_session(@api_session)
    {:ok, saved} = save_saved_v2_template()

    body =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/templates/#{saved.id}/apply", %{
        "session" => @api_session,
        "dry_run" => true
      })
      |> json_response(200)

    assert body["action"] == "template_applied"
    assert body["dry_run"] == true
    assert body["result"]["template"]["id"] == saved.id
    assert body["result"]["template"]["source"] == "exported"
    assert body["result"]["template"]["schema_version"] == 2
    assert body["result"]["step_count"] == 7
    assert body["topology"]["active_window_id"] == "@1"

    assert Enum.any?(body["result"]["steps"], fn step ->
             step["action"] == "split_pane" and step["ref"] == "pane:server:console"
           end)

    refute_received {:fake_tmux_new_window, @api_session, _}

    refute Enum.any?(
             Casein.Audit.recent_for("ws-1", 10),
             &(&1.action == "tmux.template_applied")
           )
  end

  test "POST /api/workspaces/:id/templates/:template_id/apply supports saved v2 reconcile diff",
       %{
         conn: conn
       } do
    seed_workspace(root: "/workspace")
    seed_tmux_session(@api_session)
    {:ok, saved} = save_saved_v2_template()

    body =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/templates/#{saved.id}/apply", %{
        "session" => @api_session,
        "dry_run" => true,
        "reconcile" => true
      })
      |> json_response(200)

    assert body["action"] == "template_applied"
    assert body["dry_run"] == true
    assert body["reconcile"] == true
    assert body["result"]["template"]["source"] == "exported"
    assert body["result"]["strategy"] == "reconcile"
    assert body["result"]["summary"]["reuse_windows"] == 1
    assert body["result"]["summary"]["create_windows"] == 0
    assert body["result"]["summary"]["reuse_panes"] == 1
    assert body["result"]["summary"]["new_panes"] == 2
    assert body["diff"]["template_id"] == saved.id
    assert body["diff"]["estimated_disruption"] == "medium"

    assert Enum.any?(body["diff"]["changes"], fn change ->
             change["action"] == "reuse_window" and change["target_id"] == "@1"
           end)

    assert Enum.any?(body["diff"]["changes"], fn change ->
             change["action"] == "split_pane" and
               change["template_ref"]["ref"] == "pane:server:console"
           end)

    refute_received {:fake_tmux_new_window, @api_session, _}

    refute Enum.any?(
             Casein.Audit.recent_for("ws-1", 10),
             &(&1.action == "tmux.template_applied")
           )
  end

  test "POST /api/workspaces/:id/templates/:template_id/apply executes saved v2 template", %{
    conn: conn
  } do
    root = temp_workspace_root!()
    File.mkdir_p!(Path.join(root, "apps/web"))
    seed_workspace(root: root)
    seed_tmux_session(@api_session)
    {:ok, saved} = save_saved_v2_template()
    TmuxCtl.Test.FakeState.put(:fake_tmux_next_window, %{@api_session => "@3"})

    body =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/templates/#{saved.id}/apply", %{
        "session" => @api_session
      })
      |> json_response(200)

    assert body["action"] == "template_applied"
    assert body["dry_run"] == false
    assert body["result"]["template"]["id"] == saved.id
    assert body["result"]["template"]["source"] == "exported"
    assert body["result"]["refs"]["window:server"] == "@3"
    assert body["result"]["refs"]["pane:server:root"] == "%3"
    assert body["result"]["refs"]["pane:server:console"] == "%4"
    assert body["result"]["refs"]["pane:server:logs"] == "%5"
    assert body["topology"]["active_window_id"] == "@3"
    assert body["topology"]["active_pane_id"] == "%4"

    assert_receive {:fake_tmux_new_window, @api_session, opts}
    assert opts[:name] == "server"
    assert opts[:cwd] == root

    assert_receive {:fake_tmux_send_command, @api_session, "%3", "mix phx.server", _}
    assert_receive {:fake_tmux_split_pane, @api_session, "%3", "h", "%4"}
    assert_receive {:fake_tmux_send_command, @api_session, "%4", "iex -S mix", _}
    assert_receive {:fake_tmux_split_pane, @api_session, "%4", "v", "%5"}
    assert_receive {:fake_tmux_send_command, @api_session, "%5", "tail -f log/dev.log", _}
    assert_receive {:fake_tmux_select_pane, @api_session, "%4"}

    assert [%{action: "tmux.template_applied", target_ref: template_id} = event] =
             Casein.Audit.recent_for("ws-1", 1)

    assert template_id == saved.id
    assert event.metadata.template_source == "exported"
    assert event.metadata.schema_version == 2
    assert event.metadata.refs["window:server"] == "@3"
  end

  test "POST /api/workspaces/:id/templates/:template_id/apply executes saved v2 reconcile",
       %{
         conn: conn
       } do
    seed_workspace(root: "/workspace")
    seed_tmux_session(@api_session)
    {:ok, saved} = save_saved_v2_template()

    body =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/templates/#{saved.id}/apply", %{
        "session" => @api_session,
        "reconcile" => true
      })
      |> json_response(200)

    assert body["action"] == "template_applied"
    assert body["dry_run"] == false
    assert body["reconcile"] == true
    assert body["result"]["plan_executed"] == true
    assert body["result"]["strategy"] == "reconcile"
    assert body["result"]["template"]["source"] == "exported"
    assert body["result"]["reconciliation"]["reuse_windows"] == 1
    assert body["result"]["reconciliation"]["new_panes"] == 2
    assert body["result"]["refs"]["window:server"] == "@1"
    assert body["result"]["refs"]["pane:server:root"] == "%1"
    assert body["result"]["refs"]["pane:server:console"] == "%3"
    assert body["result"]["refs"]["pane:server:logs"] == "%4"
    assert body["summary"]["new_panes"] == 2
    assert body["diff"]["strategy"] == "reconcile"
    assert body["topology"]["active_window_id"] == "@1"
    assert body["topology"]["active_pane_id"] == "%3"

    refute_received {:fake_tmux_new_window, @api_session, _}
    assert_receive {:fake_tmux_split_pane, @api_session, "%1", "h", "%3"}
    assert_receive {:fake_tmux_send_command, @api_session, "%3", "iex -S mix", _}
    assert_receive {:fake_tmux_split_pane, @api_session, "%3", "v", "%4"}
    assert_receive {:fake_tmux_send_command, @api_session, "%4", "tail -f log/dev.log", _}
    assert_receive {:fake_tmux_select_pane, @api_session, "%3"}

    assert [%{action: "tmux.template_applied", target_ref: template_id} = event] =
             Casein.Audit.recent_for("ws-1", 1)

    assert template_id == saved.id
    assert event.metadata.template_source == "exported"
    assert event.metadata.schema_version == 2
    assert event.metadata.reconciliation.new_panes == 2
    assert event.metadata.refs["pane:server:console"] == "%3"
  end

  test "PATCH /api/workspaces/:id/templates/:template_id updates saved template metadata", %{
    conn: conn
  } do
    seed_workspace()
    seed_tmux_session(@api_session)
    {:ok, saved} = save_saved_v2_template()

    body =
      conn
      |> authed()
      |> patch("/api/workspaces/ws-1/templates/#{saved.id}", %{
        "session" => @api_session,
        "name" => "daily_layout_v2",
        "description" => "Updated daily stack",
        "tags" => "daily, Phoenix"
      })
      |> json_response(200)

    assert body["action"] == "template_updated"
    assert body["dry_run"] == false
    assert body["workspace_id"] == "ws-1"
    assert body["template_id"] == saved.id
    assert body["template"]["name"] == "daily_layout_v2"
    assert body["template"]["description"] == "Updated daily stack"
    assert body["template"]["tags"] == ["daily", "phoenix"]
    assert body["topology"]["active_pane_id"] == "%1"
    assert body["changes"]["name"] == %{"before" => "saved_layout", "after" => "daily_layout_v2"}
    assert body["changes"]["tags"] == %{"before" => ["saved"], "after" => ["daily", "phoenix"]}

    assert {:ok, updated} = Templates.get("ws-1", saved.id)
    assert updated.name == "daily_layout_v2"
    assert updated.description == "Updated daily stack"
    assert updated.tags == ["daily", "phoenix"]
    assert updated.body["name"] == "saved_layout"

    assert [%{action: "tmux.template_updated", target_ref: template_id} = event] =
             Casein.Audit.recent_for("ws-1", 1)

    assert template_id == saved.id
    assert event.actor_id == "api"
    assert event.metadata.template_name == "daily_layout_v2"
    assert event.metadata.changes.name.after == "daily_layout_v2"
    assert event.metadata.changes.description.before == "Saved v2 layout"
    assert event.metadata.changes.tags.after == ["daily", "phoenix"]
  end

  test "PATCH /api/workspaces/:id/templates/:template_id supports dry-run without saving", %{
    conn: conn
  } do
    seed_workspace()
    {:ok, saved} = save_saved_v2_template()

    body =
      conn
      |> authed()
      |> patch("/api/workspaces/ws-1/templates/#{saved.id}", %{
        "name" => "dry_layout",
        "tags" => ["dry-run"],
        "dry_run" => true
      })
      |> json_response(200)

    assert body["action"] == "template_updated"
    assert body["dry_run"] == true
    assert body["template"]["name"] == "dry_layout"
    assert body["template"]["tags"] == ["dry-run"]

    assert {:ok, unchanged} = Templates.get("ws-1", saved.id)
    assert unchanged.name == "saved_layout"
    assert unchanged.tags == ["saved"]

    refute Enum.any?(
             Casein.Audit.recent_for("ws-1", 10),
             &(&1.action == "tmux.template_updated")
           )
  end

  test "PATCH /api/workspaces/:id/templates/:template_id returns stable errors", %{conn: conn} do
    seed_workspace()
    {:ok, saved} = save_saved_v2_template()

    missing =
      conn
      |> authed()
      |> patch("/api/workspaces/ws-1/templates/00000000-0000-0000-0000-000000000000", %{
        "name" => "missing"
      })
      |> json_response(404)

    assert missing == %{"error" => "template_not_found"}

    blank =
      conn
      |> authed()
      |> patch("/api/workspaces/ws-1/templates/#{saved.id}", %{"name" => "   "})
      |> json_response(422)

    assert blank == %{"error" => "name_required"}

    {:ok, other} =
      Templates.save(%{
        workspace_id: "ws-1",
        name: "other_layout",
        description: "Other layout",
        body: saved_v2_template_body(),
        source_session: @api_session,
        schema_version: 2
      })

    taken =
      conn
      |> authed()
      |> patch("/api/workspaces/ws-1/templates/#{other.id}", %{"name" => "saved_layout"})
      |> json_response(409)

    assert taken == %{"error" => "name_taken"}
  end

  test "POST /api/workspaces/:id/templates/:template_id/duplicate copies saved templates", %{
    conn: conn
  } do
    seed_workspace()
    seed_tmux_session(@api_session)
    {:ok, saved} = save_saved_v2_template()

    body =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/templates/#{saved.id}/duplicate", %{
        "session" => @api_session,
        "name" => "saved_layout_copy",
        "description" => "Copied v2 layout"
      })
      |> json_response(200)

    assert body["action"] == "template_duplicated"
    assert body["dry_run"] == false
    assert body["workspace_id"] == "ws-1"
    assert body["source_template_id"] == saved.id
    assert body["template_id"] != saved.id
    assert body["saved_template"]["name"] == "saved_layout_copy"
    assert body["saved_template"]["description"] == "Copied v2 layout"
    assert body["saved_template"]["tags"] == ["saved"]
    assert body["saved_template"]["source_session"] == @api_session
    assert body["topology"]["active_pane_id"] == "%1"

    assert {:ok, duplicated} = Templates.get("ws-1", body["template_id"])
    assert duplicated.name == "saved_layout_copy"
    assert duplicated.description == "Copied v2 layout"
    assert duplicated.tags == ["saved"]
    assert duplicated.body == saved.body

    assert [%{action: "tmux.template_duplicated", target_ref: template_id} = event] =
             Casein.Audit.recent_for("ws-1", 1)

    assert template_id == duplicated.id
    assert event.actor_id == "api"
    assert event.metadata.source_template_id == saved.id
    assert event.metadata.template_name == "saved_layout_copy"
  end

  test "POST /api/workspaces/:id/templates/:template_id/duplicate supports dry-run", %{
    conn: conn
  } do
    seed_workspace()
    {:ok, saved} = save_saved_v2_template()

    body =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/templates/#{saved.id}/duplicate", %{
        "dry_run" => true
      })
      |> json_response(200)

    assert body["action"] == "template_duplicated"
    assert body["dry_run"] == true
    assert body["source_template_id"] == saved.id
    assert body["template_id"] == nil
    assert body["saved_template"]["id"] == nil
    assert body["saved_template"]["name"] == "saved_layout (copy)"
    assert body["saved_template"]["description"] == "Saved v2 layout"
    assert body["saved_template"]["tags"] == ["saved"]

    saved_id = saved.id
    assert [%{id: ^saved_id}] = Templates.list_for_workspace("ws-1")

    refute Enum.any?(
             Casein.Audit.recent_for("ws-1", 10),
             &(&1.action == "tmux.template_duplicated")
           )
  end

  test "POST /api/workspaces/:id/templates/:template_id/duplicate returns stable errors", %{
    conn: conn
  } do
    seed_workspace()
    {:ok, saved} = save_saved_v2_template()

    missing =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/templates/00000000-0000-0000-0000-000000000000/duplicate", %{
        "name" => "missing"
      })
      |> json_response(404)

    assert missing == %{"error" => "template_not_found"}

    blank =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/templates/#{saved.id}/duplicate", %{"name" => "   "})
      |> json_response(422)

    assert blank == %{"error" => "name_required"}

    taken =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/templates/#{saved.id}/duplicate", %{
        "name" => "saved_layout"
      })
      |> json_response(409)

    assert taken == %{"error" => "name_taken"}
  end

  test "DELETE /api/workspaces/:id/templates/:template_id deletes saved templates", %{
    conn: conn
  } do
    seed_workspace()
    {:ok, saved} = save_saved_v2_template()

    body =
      conn
      |> authed()
      |> delete("/api/workspaces/ws-1/templates/#{saved.id}")
      |> json_response(200)

    assert body == %{
             "action" => "template_deleted",
             "workspace_id" => "ws-1",
             "template_id" => saved.id
           }

    assert Templates.list_for_workspace("ws-1") == []

    missing =
      conn
      |> authed()
      |> delete("/api/workspaces/ws-1/templates/#{saved.id}")
      |> json_response(404)

    assert missing == %{"error" => "template_not_found"}

    assert [%{action: "tmux.template_deleted", target_ref: template_id} = event] =
             Casein.Audit.recent_for("ws-1", 1)

    assert template_id == saved.id
    assert event.metadata.template_name == "saved_layout"
    assert event.metadata.schema_version == 2
  end

  test "template apply endpoint returns stable errors", %{conn: conn} do
    seed_workspace()
    seed_tmux_session(@api_session)

    missing_session =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/templates/generic_project/apply", %{})
      |> json_response(422)

    assert missing_session == %{"error" => "session_required"}

    missing_template =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/templates/missing/apply", %{
        "session" => @api_session,
        "dry_run" => true
      })
      |> json_response(404)

    assert missing_template == %{"error" => "template_not_found"}

    unsupported_reconcile =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/templates/generic_project/apply", %{
        "session" => @api_session,
        "dry_run" => true,
        "reconcile" => true
      })
      |> json_response(422)

    assert unsupported_reconcile == %{"error" => "unsupported_reconcile"}

    reconcile_without_dry_run =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/templates/generic_project/apply", %{
        "session" => @api_session,
        "reconcile" => true
      })
      |> json_response(422)

    assert reconcile_without_dry_run == %{"error" => "unsupported_reconcile"}
  end

  test "POST /api/workspaces/:id/windows creates a tmux window and returns topology", %{
    conn: conn
  } do
    root = temp_workspace_root!()
    seed_workspace(root: root)
    seed_tmux_session(@api_session)
    TmuxCtl.Test.FakeState.put(:fake_tmux_next_window, %{@api_session => "@3"})

    body =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/windows", %{
        "session" => @api_session,
        "name" => "server",
        "cwd" => "."
      })
      |> json_response(200)

    assert body["action"] == "window_created"
    assert body["dry_run"] == false
    assert body["result"] == %{"window_id" => "@3"}
    assert body["topology"]["active_window_id"] == "@3"
    assert Enum.any?(body["topology"]["windows"], &(&1["id"] == "@3" and &1["name"] == "server"))
    assert_receive {:fake_tmux_new_window, @api_session, opts}
    assert opts[:name] == "server"
    assert opts[:cwd] == Path.expand(root)

    [event] = Casein.Audit.recent_for("ws-1", 1)
    assert event.action == "tmux.window_created"
    assert event.actor_id == "api"
    assert event.target_type == "tmux_window"
    assert event.target_ref == "@3"
    assert event.metadata.session == @api_session
    assert event.metadata.window_id == "@3"
    assert event.metadata.active_window_id == "@3"
    assert event.metadata.dry_run == false
  end

  test "POST /api/workspaces/:id/windows rejects cwd outside workspace root", %{conn: conn} do
    root = temp_workspace_root!()
    seed_workspace(root: root)
    seed_tmux_session(@api_session)

    body =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/windows", %{
        "session" => @api_session,
        "name" => "escape",
        "cwd" => "/etc"
      })
      |> json_response(422)

    assert body == %{"error" => "outside_root"}
    refute_received {:fake_tmux_new_window, @api_session, _opts}
  end

  test "window mutation endpoints select rename kill and support dry-run", %{conn: conn} do
    seed_workspace()
    seed_tmux_session(@api_session)

    dry_run =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/windows/@2/select", %{
        "session" => @api_session,
        "dry_run" => true
      })
      |> json_response(200)

    assert dry_run["action"] == "window_selected"
    assert dry_run["dry_run"] == true
    assert dry_run["topology"]["active_window_id"] == "@1"
    refute_received {:fake_tmux_select_window, @api_session, "@2"}

    refute Enum.any?(
             Casein.Audit.recent_for("ws-1", 10),
             &(&1.action == "tmux.window_selected")
           )

    selected =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/windows/@2/select", %{"session" => @api_session})
      |> json_response(200)

    assert selected["topology"]["active_window_id"] == "@2"
    assert_receive {:fake_tmux_select_window, @api_session, "@2"}

    assert [%{action: "tmux.window_selected", target_ref: "@2"}] =
             Casein.Audit.recent_for("ws-1", 1)

    renamed =
      conn
      |> authed()
      |> patch("/api/workspaces/ws-1/windows/@2", %{
        "session" => @api_session,
        "name" => "specs"
      })
      |> json_response(200)

    assert Enum.any?(
             renamed["topology"]["windows"],
             &(&1["id"] == "@2" and &1["name"] == "specs")
           )

    assert_receive {:fake_tmux_rename_window, @api_session, "@2", "specs"}

    assert [%{action: "tmux.window_renamed", target_ref: "@2"}] =
             Casein.Audit.recent_for("ws-1", 1)

    closed =
      conn
      |> authed()
      |> delete("/api/workspaces/ws-1/windows/@2", %{"session" => @api_session})
      |> json_response(200)

    # Deferred, like the viewer: the window is gone from the response topology
    # but tmux still has it until the grace period expires.
    assert closed["action"] == "window_close_deferred"
    assert closed["result"]["window_id"] == "@2"
    assert closed["result"]["grace_ms"] > 0
    refute Enum.any?(closed["topology"]["windows"], &(&1["id"] == "@2"))
    refute_receive {:fake_tmux_kill_window, @api_session, "@2"}

    assert [%{action: "tmux.window_close_deferred", target_ref: "@2"}] =
             Casein.Audit.recent_for("ws-1", 1)

    # A pending window is invisible to the rest of the surface, so acting on it
    # reports not-found rather than mutating something already reported closed.
    assert conn
           |> authed()
           |> post("/api/workspaces/ws-1/windows/@2/select", %{"session" => @api_session})
           |> json_response(404)

    restored =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/windows/@2/restore", %{"session" => @api_session})
      |> json_response(200)

    assert restored["action"] == "window_close_undone"
    assert Enum.any?(restored["topology"]["windows"], &(&1["id"] == "@2"))
    refute_receive {:fake_tmux_kill_window, @api_session, "@2"}

    # Restoring twice is a 422, not a silent success — the second caller must
    # not believe it recovered a window.
    assert %{"error" => "window_not_pending"} =
             conn
             |> authed()
             |> post("/api/workspaces/ws-1/windows/@2/restore", %{"session" => @api_session})
             |> json_response(422)
  end

  test "a deferred window close really kills once the grace period expires", %{conn: conn} do
    seed_workspace()
    seed_tmux_session(@api_session)

    prev_grace = Application.get_env(:casein, :window_trash_grace_ms)
    Application.put_env(:casein, :window_trash_grace_ms, 50)

    on_exit(fn ->
      if prev_grace,
        do: Application.put_env(:casein, :window_trash_grace_ms, prev_grace),
        else: Application.delete_env(:casein, :window_trash_grace_ms)
    end)

    conn
    |> authed()
    |> delete("/api/workspaces/ws-1/windows/@2", %{"session" => @api_session})
    |> json_response(200)

    assert_receive {:fake_tmux_kill_window, @api_session, "@2"}, 1_000

    # Too late to take back once it has really gone.
    assert %{"error" => "window_not_pending"} =
             conn
             |> authed()
             |> post("/api/workspaces/ws-1/windows/@2/restore", %{"session" => @api_session})
             |> json_response(422)
  end

  test "window mutation endpoints return stable errors", %{conn: conn} do
    seed_workspace()
    seed_tmux_session(@api_session)

    missing_session =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/windows/@2/select", %{})
      |> json_response(422)

    assert missing_session == %{"error" => "session_required"}

    missing_window =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/windows/@9/select", %{"session" => @api_session})
      |> json_response(404)

    assert missing_window == %{"error" => "window_not_found"}

    missing_name =
      conn
      |> authed()
      |> patch("/api/workspaces/ws-1/windows/@1", %{"session" => @api_session, "name" => ""})
      |> json_response(422)

    assert missing_name == %{"error" => "name_required"}
  end

  test "window mutation endpoints reject cross-workspace tmux sessions", %{conn: conn} do
    seed_workspace()

    other_session = Casein.Terminals.Tmux.session_name("beta", "api-session")
    seed_tmux_session(other_session)

    body =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/windows/@2/select", %{"session" => other_session})
      |> json_response(422)

    assert body == %{"error" => "invalid_tmux_session_scope"}
    refute_received {:fake_tmux_select_window, ^other_session, "@2"}
  end

  test "pane mutation endpoints select split resize kill and support dry-run", %{conn: conn} do
    seed_workspace()
    seed_tmux_session(@api_session)

    dry_run =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/panes/%1/select", %{
        "session" => @api_session,
        "dry_run" => true
      })
      |> json_response(200)

    assert dry_run["action"] == "pane_selected"
    assert dry_run["dry_run"] == true
    assert dry_run["topology"]["active_pane_id"] == "%1"
    refute_received {:fake_tmux_select_pane, @api_session, "%1"}
    assert Casein.Audit.recent_for("ws-1", 10) == []

    split =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/panes/%1/split", %{
        "session" => @api_session,
        "direction" => "h"
      })
      |> json_response(200)

    assert split["action"] == "pane_split"
    assert split["dry_run"] == false
    assert split["result"] == %{"pane_id" => "%3"}
    assert split["topology"]["active_pane_id"] == "%3"
    assert Enum.any?(split["topology"]["panes"], &(&1["id"] == "%3"))
    assert_receive {:fake_tmux_split_pane, @api_session, "%1", "h", "%3"}

    assert [%{action: "tmux.pane_split", target_ref: "%3", target_type: "tmux_pane"}] =
             Casein.Audit.recent_for("ws-1", 1)

    selected =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/panes/%1/select", %{"session" => @api_session})
      |> json_response(200)

    assert selected["topology"]["active_pane_id"] == "%1"
    assert_receive {:fake_tmux_select_pane, @api_session, "%1"}

    assert [%{action: "tmux.pane_selected", target_ref: "%1"}] =
             Casein.Audit.recent_for("ws-1", 1)

    resized =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/panes/%1/resize", %{
        "session" => @api_session,
        "direction" => "right",
        "amount" => "5"
      })
      |> json_response(200)

    assert resized["action"] == "pane_resized"
    assert_receive {:fake_tmux_resize_pane, @api_session, "%1", "right", 5}

    assert [%{action: "tmux.pane_resized", target_ref: "%1"}] =
             Casein.Audit.recent_for("ws-1", 1)

    killed =
      conn
      |> authed()
      |> delete("/api/workspaces/ws-1/panes/%3", %{"session" => @api_session})
      |> json_response(200)

    assert killed["action"] == "pane_killed"
    refute Enum.any?(killed["topology"]["panes"], &(&1["id"] == "%3"))
    assert_receive {:fake_tmux_kill_pane, @api_session, "%3"}

    assert [%{action: "tmux.pane_killed", target_ref: "%3"}] =
             Casein.Audit.recent_for("ws-1", 1)
  end

  test "POST /api/workspaces/:id/panes creates a pane by splitting a target pane", %{conn: conn} do
    seed_workspace()
    seed_tmux_session(@api_session)

    body =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/panes", %{
        "session" => @api_session,
        "pane_id" => "%1",
        "direction" => "v"
      })
      |> json_response(200)

    assert body["action"] == "pane_split"
    assert body["result"] == %{"pane_id" => "%3"}
    assert body["topology"]["active_pane_id"] == "%3"
    assert_receive {:fake_tmux_split_pane, @api_session, "%1", "v", "%3"}
  end

  test "pane mutation endpoints return stable errors", %{conn: conn} do
    seed_workspace()
    seed_tmux_session(@api_session)

    missing_session =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/panes/%1/select", %{})
      |> json_response(422)

    assert missing_session == %{"error" => "session_required"}

    missing_pane =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/panes/%9/select", %{"session" => @api_session})
      |> json_response(404)

    assert missing_pane == %{"error" => "pane_not_found"}

    invalid_split =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/panes/%1/split", %{
        "session" => @api_session,
        "direction" => "x"
      })
      |> json_response(422)

    assert invalid_split == %{"error" => "invalid_direction"}

    invalid_resize_amount =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/panes/%1/resize", %{
        "session" => @api_session,
        "direction" => "right",
        "amount" => "51"
      })
      |> json_response(422)

    assert invalid_resize_amount == %{"error" => "invalid_amount"}

    last_pane =
      conn
      |> authed()
      |> delete("/api/workspaces/ws-1/panes/%2", %{"session" => @api_session})
      |> json_response(422)

    assert last_pane == %{"error" => "last_pane"}
  end

  test "/api/workspaces/:id/runs", %{conn: conn} do
    seed_workspace()
    body = conn |> authed() |> get("/api/workspaces/ws-1/runs") |> json_response(200)
    assert is_list(body)
  end

  test "/api/workspaces/:id/proposals", %{conn: conn} do
    seed_workspace()
    body = conn |> authed() |> get("/api/workspaces/ws-1/proposals") |> json_response(200)
    assert is_list(body)
  end

  test "/api/workspaces/:id/audit", %{conn: conn} do
    seed_workspace()
    body = conn |> authed() |> get("/api/workspaces/ws-1/audit") |> json_response(200)
    assert is_list(body)
  end

  test "404 for unknown workspace", %{conn: conn} do
    Application.put_env(:casein, :api_token, @token)
    conn = conn |> authed() |> get("/api/workspaces/no-such/status")
    assert conn.status == 404
  end

  test "no secrets leak in /status response", %{conn: conn} do
    seed_workspace()
    raw = conn |> authed() |> get("/api/workspaces/ws-1/status") |> response(200)

    refute raw =~ "hunter2"
    refute raw =~ "DATABASE_URL"
    refute raw =~ "postgres://u:"
  end

  test "other workspace writes are not exposed on /api/* routes", %{conn: conn} do
    seed_workspace()
    base = authed(conn)

    assert_no_route = fn fun ->
      try do
        result = fun.(base)
        assert result.status in [404, 405]
      rescue
        Phoenix.Router.NoRouteError -> :ok
      end
    end

    assert_no_route.(fn c -> post(c, "/api/workspaces") end)
    assert_no_route.(fn c -> put(c, "/api/workspaces/ws-1/status") end)
    assert_no_route.(fn c -> delete(c, "/api/workspaces/ws-1") end)
    assert_no_route.(fn c -> patch(c, "/api/workspaces/ws-1/status") end)
  end

  # ---------------------------------------------------------------------------
  # M3.1: Saved template tests
  # ---------------------------------------------------------------------------

  test "POST /api/workspaces/:id/templates/export saves topology as a template", %{conn: conn} do
    seed_workspace(root: "/workspace")
    seed_tmux_session(@api_session)

    body =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/templates/export", %{
        "session" => @api_session,
        "name" => "my_layout"
      })
      |> json_response(201)

    assert body["workspace_id"] == "ws-1"
    assert body["session"] == @api_session
    assert body["template"]["version"] == 2
    assert body["template"]["name"] == "my_layout"
    assert body["yaml"] =~ "version: 2"

    saved = body["saved_template"]
    assert saved["id"]
    assert saved["workspace_id"] == "ws-1"
    assert saved["name"] == "my_layout"
    assert saved["source_session"] == @api_session
    assert saved["inserted_at"]

    assert [%{action: "tmux.template_exported", target_type: "tmux_template"}] =
             Casein.Audit.recent_for("ws-1", 1)
  end

  test "POST /api/workspaces/:id/templates/export requires session param", %{conn: conn} do
    seed_workspace()

    body =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/templates/export", %{"name" => "oops"})
      |> json_response(422)

    assert body == %{"error" => "session_required"}
  end

  test "POST /api/workspaces/:id/templates/export rejects unknown workspace", %{conn: conn} do
    body =
      conn
      |> authed()
      |> post("/api/workspaces/no-such/templates/export", %{
        "session" => @api_session,
        "name" => "x"
      })
      |> json_response(404)

    assert body == %{"error" => "not_found"}
  end

  test "GET /api/workspaces/:id/templates includes saved exports in listing", %{conn: conn} do
    seed_workspace(root: "/workspace")
    seed_tmux_session(@api_session)

    # Save a template first
    conn
    |> authed()
    |> post("/api/workspaces/ws-1/templates/export", %{
      "session" => @api_session,
      "name" => "saved_layout"
    })
    |> json_response(201)

    body =
      conn
      |> authed()
      |> get("/api/workspaces/ws-1/templates")
      |> json_response(200)

    ids = Enum.map(body, & &1["id"])
    assert "agent_pair" in ids
    assert "generic_project" in ids
    assert "phoenix_dev" in ids

    saved = Enum.find(body, &(&1["name"] == "saved_layout"))
    assert saved
    assert saved["id"]
    assert saved["windows"] >= 1
    assert saved["panes"] >= 1
  end

  test "saved template can be retrieved and applied by id", %{conn: conn} do
    root = temp_workspace_root!()
    seed_workspace(root: root)
    seed_tmux_session(@api_session)
    TmuxCtl.Test.FakeState.put(:fake_tmux_next_window, %{@api_session => "@3"})

    # Save
    saved_body =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/templates/export", %{
        "session" => @api_session,
        "name" => "saved_for_apply"
      })
      |> json_response(201)

    template_id = saved_body["saved_template"]["id"]
    assert template_id

    # Apply dry-run using the saved UUID
    dry_run =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/templates/#{template_id}/apply", %{
        "session" => @api_session,
        "dry_run" => true
      })
      |> json_response(200)

    assert dry_run["action"] == "template_applied"
    assert dry_run["dry_run"] == true
  end

  defp temp_workspace_root! do
    root = Path.join(System.tmp_dir!(), "casein-api-root-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp seed_tmux_session(session) do
    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [
        %{
          id: "@1",
          index: 0,
          name: "server",
          active: true,
          panes: 1,
          activity: 0,
          current_command: "mix"
        },
        %{
          id: "@2",
          index: 1,
          name: "tests",
          active: false,
          panes: 1,
          activity: 0,
          current_command: "bash"
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      session => [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 120,
          height: 40,
          current_command: "mix",
          current_path: "/workspace"
        },
        %{
          id: "%2",
          window_id: "@2",
          index: 0,
          active: false,
          left: 0,
          top: 0,
          width: 80,
          height: 24,
          current_command: "bash",
          current_path: "/workspace/test"
        }
      ]
    })
  end

  defp save_saved_v2_template do
    Templates.save(%{
      workspace_id: "ws-1",
      name: "saved_layout",
      description: "Saved v2 layout",
      body: saved_v2_template_body(),
      source_session: @api_session,
      schema_version: 2,
      tags: ["saved"]
    })
  end

  defp saved_v2_template_body do
    %{
      "version" => 2,
      "name" => "saved_layout",
      "root" => "${workspace_root}",
      "windows" => [
        %{
          "name" => "server",
          "root" => "${workspace_root}",
          "focus" => true,
          "layout" => %{
            "direction" => "horizontal",
            "panes" => [
              %{"name" => "app", "command" => "mix phx.server", "focus" => true},
              %{
                "direction" => "vertical",
                "panes" => [
                  %{
                    "name" => "console",
                    "cwd" => "${workspace_root}/apps/web",
                    "command" => "iex -S mix"
                  },
                  %{
                    "name" => "logs",
                    "cwd" => "${workspace_root}/apps/web",
                    "command" => "tail -f log/dev.log"
                  }
                ]
              }
            ]
          }
        }
      ],
      "startup" => %{"window" => "server", "pane" => "console"}
    }
  end

  defp href_query(href) do
    href
    |> URI.parse()
    |> Map.get(:query)
    |> then(&URI.decode_query(&1 || ""))
  end
end
