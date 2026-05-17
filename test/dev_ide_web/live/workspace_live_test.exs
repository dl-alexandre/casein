defmodule DevIdeWeb.WorkspaceLiveTest do
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DevIDE.Audit
  alias DevIDE.Commands.History
  alias DevIDE.Runs.Ledger
  alias DevIDE.Workspaces.State.MemoryAdapter

  setup do
    bypass = Bypass.open()
    prev = Application.get_env(:dev_ide, :manager_url)
    Application.put_env(:dev_ide, :manager_url, "http://localhost:#{bypass.port}")
    MemoryAdapter.clear()
    Audit.clear()
    History.MemoryAdapter.clear()
    DevIDE.Runners.clear()
    DevIDE.Runtimes.clear()

    on_exit(fn ->
      MemoryAdapter.clear()
      Audit.clear()
      History.MemoryAdapter.clear()
      DevIDE.Runners.clear()
      DevIDE.Runtimes.clear()

      if prev,
        do: Application.put_env(:dev_ide, :manager_url, prev),
        else: Application.delete_env(:dev_ide, :manager_url)
    end)

    {:ok, bypass: bypass}
  end

  test "lists workspaces from a fake manager", %{conn: conn, bypass: bypass} do
    Bypass.expect(bypass, "GET", "/api/workspaces", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!([
          %{
            "id" => "abc",
            "name" => "alpha",
            "user" => "alice",
            "status" => "running",
            "type" => "v3",
            "branch" => "main"
          }
        ])
      )
    end)

    {:ok, _view, html} = live(conn, ~p"/workspaces")
    assert html =~ "alpha"
    assert html =~ "running"
  end

  test "shows actionable error when the workspace source is unreachable", %{
    conn: conn,
    bypass: bypass
  } do
    Bypass.down(bypass)
    {:ok, _view, html} = live(conn, ~p"/workspaces")
    assert html =~ "Workspace source is not reachable" or html =~ "Transport error"
  end

  test "renders the picker as a host-grouped list with a derived mode badge", %{
    conn: conn,
    bypass: bypass
  } do
    Bypass.expect(bypass, "GET", "/api/workspaces", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!([
          %{
            "id" => "abc",
            "name" => "alpha",
            "user" => "alice",
            "status" => "running",
            "type" => "v3",
            "branch" => "main"
          }
        ])
      )
    end)

    {:ok, _view, html} = live(conn, ~p"/workspaces")

    # product.md §9.1 — picker is the first screen.
    assert html =~ "Connect to a workspace"

    # FP-4 / §11 — mode is derived from capabilities. With no remote/fleet
    # signals registered, the synthetic host is local.
    assert html =~ "local"

    # capability chips appear (synthetic local host advertises these)
    assert html =~ "tmux"
    assert html =~ "audit"

    # workspace still renders under its host so previous behavior is preserved.
    assert html =~ "alpha"
    assert html =~ "running"

    # Picker links carry the host id so the cockpit knows which runtime
    # authority to attach to (audit punch-list item #4).
    assert html =~ "/workspaces/abc?host=local"
  end

  test "run tab renders canonical run ledger timeline", %{conn: conn, bypass: bypass} do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-live")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    run_id = Ledger.new_run_id()

    Ledger.command_requested(%{
      workspace_id: "ws-1",
      actor_id: "dev",
      command_id: "test",
      run_id: run_id,
      plane: "safe_action",
      metadata: %{source: "ui", protocol: "devide.immediate.v1"}
    })

    Ledger.run_started(%{
      workspace_id: "ws-1",
      actor_id: "dev",
      command_id: "test",
      run_id: run_id
    })

    Ledger.run_finished(:succeeded, %{
      workspace_id: "ws-1",
      actor_id: "dev",
      command_id: "test",
      run_id: run_id,
      metadata: %{exit_code: 0}
    })

    {:ok, history} =
      History.start_run(%{
        id: run_id,
        workspace_id: "ws-1",
        actor_id: "dev",
        command_id: "test",
        started_at: DateTime.utc_now()
      })

    {:ok, _} =
      History.finish_run(history.id, %{
        status: :succeeded,
        exit_code: 0,
        started_at: history.started_at,
        finished_at: DateTime.utc_now(),
        output: "ok\n"
      })

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    html = view |> element("button[phx-value-tab=run]") |> render_click()

    assert has_element?(view, "#run-ledger")
    assert has_element?(view, "#run-ledger-run-#{run_id}")
    assert has_element?(view, "#run-ledger-timeline")
    assert html =~ "run.command_requested"
    assert html =~ "run.started"
    assert html =~ "run.succeeded"
    assert html =~ "command output"
    assert html =~ "ok"
    refute html =~ "Recent runs"
    refute has_element?(view, "button[phx-click='run_history:toggle']")
  end

  test "evidence drawer can open a ledger run timeline", %{conn: conn, bypass: bypass} do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-live-evidence")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    run_id = Ledger.new_run_id()

    requested =
      Ledger.command_requested(%{
        workspace_id: "ws-1",
        actor_id: "dev",
        command_id: "format",
        run_id: run_id,
        plane: "safe_action",
        metadata: %{source: "ui", protocol: "devide.immediate.v1"}
      })

    Ledger.run_started(%{
      workspace_id: "ws-1",
      actor_id: "dev",
      command_id: "format",
      run_id: run_id
    })

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    _ = view |> element("button[phx-click='audit_drawer:toggle']") |> render_click()

    button_id = "#audit-open-run-#{run_id}-#{requested.id}"
    assert has_element?(view, button_id)

    html =
      view
      |> element(button_id)
      |> render_click()

    assert html =~ "Run ledger"
    assert html =~ "run.command_requested"
    assert html =~ "run.started"
    assert has_element?(view, "#run-ledger-run-#{run_id}")
    refute has_element?(view, "aside[aria-label='Evidence drawer']")
  end

  test "run tab shows capped local command output artifact", %{conn: conn, bypass: bypass} do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-output")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    run_id = Ledger.new_run_id()

    Ledger.command_requested(%{
      workspace_id: "ws-1",
      actor_id: "dev",
      command_id: "test",
      run_id: run_id,
      plane: "safe_action",
      metadata: %{source: "ui", protocol: "devide.immediate.v1"}
    })

    Ledger.run_started(%{
      workspace_id: "ws-1",
      actor_id: "dev",
      command_id: "test",
      run_id: run_id
    })

    Ledger.run_finished(:succeeded, %{
      workspace_id: "ws-1",
      actor_id: "dev",
      command_id: "test",
      run_id: run_id,
      metadata: %{exit_code: 0}
    })

    {:ok, history} =
      History.start_run(%{
        id: run_id,
        workspace_id: "ws-1",
        actor_id: "dev",
        command_id: "test",
        started_at: DateTime.utc_now()
      })

    {:ok, _} =
      History.finish_run(history.id, %{
        status: :succeeded,
        exit_code: 0,
        started_at: history.started_at,
        finished_at: DateTime.utc_now(),
        output: "line one\nline two\n"
      })

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    html = view |> element("button[phx-value-tab=run]") |> render_click()

    assert has_element?(view, "#run-artifact-command-output")
    assert html =~ "command output"
    assert html =~ "line one"
    refute html =~ "truncated"
    refute html =~ "runner assignment"
    refute html =~ "Recent runs"
    refute has_element?(view, "button[phx-click='run_history:toggle']")
  end

  test "run tab shows runner-backed assignment artifact", %{conn: conn, bypass: bypass} do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-runner")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    # Ensure workspace is synced into State so runner enqueue can resolve it.
    {:ok, _ws} = DevIDE.Workspaces.get("ws-1")

    {:ok, assignment} = DevIDE.Runners.enqueue_command("ws-1", "test")
    run_id = assignment.metadata[:run_id]

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    html = view |> element("button[phx-value-tab=run]") |> render_click()

    assert has_element?(view, "#run-ledger")
    assert has_element?(view, "#run-ledger-run-#{run_id}")
    assert has_element?(view, "#run-artifact-runner-assignment")
    assert html =~ "runner assignment"
    assert html =~ assignment.id
    assert html =~ "0"
    assert html =~ "none"
    refute html =~ "command output"
    refute html =~ "Recent runs"
    refute has_element?(view, "button[phx-click='run_history:toggle']")
  end

  test "run tab surfaces failure reason and retry affordance for failed local run", %{
    conn: conn,
    bypass: bypass
  } do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-failed")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    run_id = Ledger.new_run_id()

    Ledger.command_requested(%{
      workspace_id: "ws-1",
      actor_id: "dev",
      command_id: "test",
      run_id: run_id,
      plane: "safe_action",
      metadata: %{source: "ui", protocol: "devide.immediate.v1"}
    })

    Ledger.run_started(%{
      workspace_id: "ws-1",
      actor_id: "dev",
      command_id: "test",
      run_id: run_id
    })

    Ledger.run_finished(:failed, %{
      workspace_id: "ws-1",
      actor_id: "dev",
      command_id: "test",
      run_id: run_id,
      metadata: %{exit_code: 1}
    })

    {:ok, history} =
      History.start_run(%{
        id: run_id,
        workspace_id: "ws-1",
        actor_id: "dev",
        command_id: "test",
        started_at: DateTime.utc_now()
      })

    {:ok, _} =
      History.finish_run(history.id, %{
        status: :failed,
        exit_code: 1,
        started_at: history.started_at,
        finished_at: DateTime.utc_now(),
        output: "error output\n"
      })

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    html = view |> element("button[phx-value-tab=run]") |> render_click()

    assert has_element?(view, "#run-failure-surface")
    assert html =~ "exit 1"
    assert has_element?(view, "#run-retry-btn")
    refute html =~ "Recent runs"
    refute has_element?(view, "button[phx-click='run_history:toggle']")
  end

  test "run tab hides retry for blocked run", %{conn: conn, bypass: bypass} do
    workspace_root = Path.join(System.tmp_dir!(), "devide-workspace-denied")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, prev_root)
    end)

    run_id = Ledger.new_run_id()

    decision = DevIDE.Policy.Decision.deny(:run_command, :manual, :not_allowed, %{})

    Ledger.command_denied(decision, %{
      workspace_id: "ws-1",
      actor_id: "dev",
      command_id: "badcmd",
      run_id: run_id,
      plane: "safe_action",
      metadata: %{source: "ui", protocol: "devide.immediate.v1"}
    })

    Bypass.expect(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")
    html = view |> element("button[phx-value-tab=run]") |> render_click()

    assert has_element?(view, "#run-failure-surface")
    assert html =~ "not_allowed"
    refute has_element?(view, "#run-retry-btn")
    refute html =~ "command output"
    refute html =~ "Recent runs"
    refute has_element?(view, "button[phx-click='run_history:toggle']")
  end

  test "show LiveView refuses non-local hosts politely (product.md §11)", %{conn: conn} do
    # The host gate fires before Workspaces.get/1, so no manager response
    # is needed. A non-local host id should redirect back to the picker
    # with an honest flash — "hide rather than mock".
    assert {:error, {:live_redirect, %{to: "/workspaces", flash: flash}}} =
             live(conn, ~p"/workspaces/abc?host=remote")

    assert flash["error"] =~ "Cross-host attach is not yet configured"
  end

  defp workspace_payload(conn, workspace_path) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(
      200,
      Jason.encode!(%{
        "id" => "ws-1",
        "name" => "alpha",
        "user" => "alice",
        "status" => "running",
        "type" => "v3",
        "branch" => "main",
        "path" => workspace_path
      })
    )
  end

  defp restore(k, nil), do: Application.delete_env(:dev_ide, k)
  defp restore(k, v), do: Application.put_env(:dev_ide, k, v)
end
