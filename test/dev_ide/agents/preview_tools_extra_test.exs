defmodule Casein.Agents.PreviewToolsExtraTest do
  @moduledoc """
  Additional branch coverage for `Casein.Agents.PreviewTools`.

  Focuses on argument validation, not-found / unknown error tuples, dispatch
  fall-through, and pure formatting/normalization helpers that the primary
  suite (`preview_tools_test.exs`) does not exercise. Reuses the same setup,
  fakes, and seeding helpers.
  """
  use Casein.DataCase, async: false

  alias Casein.Agents.PreviewTools
  alias Casein.PreviewActivity
  alias Casein.PreviewControl.Registry
  alias Casein.PreviewPanes
  alias Casein.Runtimes
  alias Casein.Terminals.Tmux
  alias TmuxCtl.Test.FakeAdapter
  alias TmuxCtl.Test.FakeState

  @v3_workspace %{
    id: "ws-tools",
    metadata: %{
      type: :v3,
      domain_base: "alice.devbox.example.com",
      ports: %{"app" => 10_100}
    }
  }

  setup do
    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_tmux = Application.get_env(:casein, :tmux_adapter)
    prev_api_token = Application.get_env(:casein, :casein_api_token)
    prev_preflight = Application.get_env(:casein, :preview_open_preflight)
    prev_persistence = Application.get_env(:casein, :preview_pane_persistence_enabled)

    prev_visibility_initial =
      Application.get_env(:casein, :preview_operator_visibility_initial_timeout_ms)

    prev_visibility_iframe =
      Application.get_env(:casein, :preview_operator_visibility_iframe_reload_timeout_ms)

    prev_visibility_page =
      Application.get_env(:casein, :preview_operator_visibility_page_reload_timeout_ms)

    prev_fake_tmux_pid = FakeState.get(:fake_tmux_test_pid)
    Application.put_env(:casein, :tmux_adapter, FakeAdapter)
    Application.put_env(:casein, :casein_api_token, "preview-tools-test-token")
    Application.put_env(:casein, :preview_pane_persistence_enabled, false)
    Application.put_env(:casein, :preview_operator_visibility_initial_timeout_ms, 0)
    Application.put_env(:casein, :preview_operator_visibility_iframe_reload_timeout_ms, 0)
    Application.put_env(:casein, :preview_operator_visibility_page_reload_timeout_ms, 0)
    FakeState.put(:fake_tmux_test_pid, self())
    _ = Registry.clear()
    Runtimes.clear()
    PreviewActivity.clear()
    PreviewPanes.clear()
    seed_workspace_tmux!(@v3_workspace.id)

    on_exit(fn ->
      Runtimes.clear()
      PreviewActivity.clear()
      PreviewPanes.clear()
      FakeState.delete(:fake_tmux_windows)
      FakeState.delete(:fake_tmux_panes)
      FakeState.delete(:fake_tmux_alive_sessions)
      FakeState.delete(:fake_tmux_session_meta)
      FakeState.delete(:fake_tmux_split_pane_exits)
      FakeState.delete(:fake_tmux_scrollback)
      restore_fake_state(:fake_tmux_test_pid, prev_fake_tmux_pid)

      if is_nil(prev_root),
        do: Application.delete_env(:casein, :workspaces_root),
        else: Application.put_env(:casein, :workspaces_root, prev_root)

      restore_env(:tmux_adapter, prev_tmux)
      restore_env(:casein_api_token, prev_api_token)
      restore_env(:preview_open_preflight, prev_preflight)
      restore_env(:preview_pane_persistence_enabled, prev_persistence)
      restore_env(:preview_operator_visibility_initial_timeout_ms, prev_visibility_initial)
      restore_env(:preview_operator_visibility_iframe_reload_timeout_ms, prev_visibility_iframe)
      restore_env(:preview_operator_visibility_page_reload_timeout_ms, prev_visibility_page)
    end)

    :ok
  end

  defp seed_workspace_tmux!(workspace_id, opts \\ []) when is_binary(workspace_id) do
    session =
      Keyword.get(opts, :session, "#{Tmux.workspace_session_prefix(workspace_id)}default")

    activity = Keyword.get(opts, :activity, 0)
    pane_id = Keyword.get(opts, :pane_id, "%1")

    FakeState.update(:fake_tmux_alive_sessions, MapSet.new(), &MapSet.put(&1, session))

    FakeState.update(:fake_tmux_windows, %{}, fn windows ->
      Map.put(windows, session, [
        %{id: "@1", index: 0, name: "bash", active: true, panes: 1, activity: activity}
      ])
    end)

    FakeState.update(:fake_tmux_panes, %{}, fn panes ->
      Map.put(panes, session, [
        %{
          id: pane_id,
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 120,
          height: 40,
          current_command: "bash",
          current_path: "/tmp"
        }
      ])
    end)

    FakeState.put(:fake_tmux_scrollback, %{
      {session, pane_id} => "# Casein agent pane\n"
    })
  end

  # ---------------------------------------------------------------------------
  # Dispatch fall-through
  # ---------------------------------------------------------------------------

  test "invoke returns :unknown_tool for an unrecognized tool name" do
    assert {:error, :unknown_tool} =
             PreviewTools.invoke("preview_does_not_exist", @v3_workspace, %{})
  end

  # ---------------------------------------------------------------------------
  # preview_open unified mode routing
  # ---------------------------------------------------------------------------

  test "preview_open rejects an invalid mode with structured error" do
    assert {:error,
            %{
              error: :invalid_mode,
              mode: "sideways",
              allowed_modes: ["app", "localhost", "here"],
              message: message
            }} =
             PreviewTools.invoke("preview_open", @v3_workspace, %{"mode" => "sideways"})

    assert message =~ "preview_open mode must be one of"
    assert message =~ "default app"
  end

  test "preview_open mode localhost validates port like the deprecated alias" do
    assert {:error, %{error: :port_not_allowed, port: 9999}} =
             PreviewTools.invoke("preview_open", @v3_workspace, %{
               "mode" => "localhost",
               "port" => 9999
             })
  end

  test "preview_open mode here requires tmux_session" do
    assert {:error, %{error: :missing_tmux_session, guidance: guidance}} =
             PreviewTools.invoke("preview_open", @v3_workspace, %{"mode" => "here"})

    assert guidance =~ "pass tmux_session"
  end

  # ---------------------------------------------------------------------------
  # navigate / navigate_pane argument validation + not-found
  # ---------------------------------------------------------------------------

  test "navigate rejects a non-numeric session_id" do
    assert {:error, :invalid_session_id} =
             PreviewTools.invoke("preview_navigate", @v3_workspace, %{
               "session_id" => "not-a-number",
               "path" => "/x"
             })
  end

  test "navigate without a path stops at the missing argument tuple" do
    assert {:error, {:missing_argument, "path"}} =
             PreviewTools.navigate(%{"session_id" => "123"})
  end

  test "navigate_pane without a pane_id reports the missing argument" do
    assert {:error, {:missing_argument, "pane_id"}} =
             PreviewTools.invoke("preview_navigate_pane", @v3_workspace, %{"path" => "/x"})
  end

  test "navigate_pane without a path reports the missing argument" do
    assert {:error, {:missing_argument, "path"}} =
             PreviewTools.invoke("preview_navigate_pane", @v3_workspace, %{"pane_id" => "%1"})
  end

  test "navigate_pane surfaces the registry error for an unknown pane" do
    assert {:error, _reason} =
             PreviewTools.invoke("preview_navigate_pane", @v3_workspace, %{
               "pane_id" => "%does-not-exist",
               "path" => "/x"
             })
  end

  # ---------------------------------------------------------------------------
  # observe_pane validation + not-found + scope
  # ---------------------------------------------------------------------------

  test "observe_pane without a pane_id reports the missing argument" do
    assert {:error, {:missing_argument, "pane_id"}} =
             PreviewTools.invoke("preview_observe_pane", @v3_workspace, %{
               "workspace_id" => @v3_workspace.id
             })
  end

  test "observe_pane returns not_found for an unregistered pane" do
    assert {:error, :not_found} =
             PreviewTools.invoke("preview_observe_pane", @v3_workspace, %{
               "workspace_id" => @v3_workspace.id,
               "pane_id" => "%missing"
             })
  end

  test "observe_pane enforces workspace scope on a pane from a different workspace" do
    assert {:ok, %{pane_id: pane_id}} =
             PreviewTools.split_preview_pane(@v3_workspace, "http://localhost:5173/", [])

    other_workspace = %{id: "ws-other"}

    assert {:error, :not_found} =
             PreviewTools.invoke("preview_observe_pane", other_workspace, %{
               "workspace_id" => "ws-other",
               "pane_id" => pane_id
             })
  end

  # ---------------------------------------------------------------------------
  # session-id parsing across observe/screenshot/storage/report tools
  # ---------------------------------------------------------------------------

  test "observe rejects a non-numeric session_id" do
    assert {:error, :invalid_session_id} =
             PreviewTools.invoke("preview_observe", @v3_workspace, %{"session_id" => "abc"})
  end

  test "observe_live rejects a non-numeric session_id" do
    assert {:error, :invalid_session_id} =
             PreviewTools.invoke("preview_observe_live", @v3_workspace, %{"session_id" => "abc"})
  end

  test "screenshot rejects a non-numeric session_id" do
    assert {:error, :invalid_session_id} =
             PreviewTools.invoke("preview_screenshot", @v3_workspace, %{"session_id" => "abc"})
  end

  test "get_storage rejects a non-numeric session_id" do
    assert {:error, :invalid_session_id} =
             PreviewTools.invoke("preview_get_storage", @v3_workspace, %{"session_id" => "abc"})
  end

  test "clear_storage rejects a non-numeric session_id" do
    assert {:error, :invalid_session_id} =
             PreviewTools.invoke("preview_clear_storage", @v3_workspace, %{"session_id" => "abc"})
  end

  test "report_errors rejects a non-numeric session_id" do
    assert {:error, :invalid_session_id} =
             PreviewTools.invoke("preview_report_errors", @v3_workspace, %{"session_id" => "abc"})
  end

  test "click rejects a non-numeric session_id before any browser work" do
    assert {:error, :invalid_session_id} =
             PreviewTools.invoke("preview_click", @v3_workspace, %{
               "session_id" => "abc",
               "selector" => "button"
             })
  end

  test "type rejects a non-numeric session_id before any browser work" do
    assert {:error, :invalid_session_id} =
             PreviewTools.invoke("preview_type", @v3_workspace, %{
               "session_id" => "abc",
               "selector" => "input",
               "text" => "hi"
             })
  end

  test "press rejects a non-numeric session_id before any browser work" do
    assert {:error, :invalid_session_id} =
             PreviewTools.invoke("preview_press", @v3_workspace, %{
               "session_id" => "abc",
               "key" => "Enter"
             })
  end

  test "observe accepts an atom-keyed session_id map and still rejects non-numeric ids" do
    assert {:error, :invalid_session_id} = PreviewTools.observe(%{session_id: "abc"})
  end

  test "screenshot accepts an atom-keyed session_id map and rejects non-numeric ids" do
    assert {:error, :invalid_session_id} = PreviewTools.screenshot(%{session_id: "abc"})
  end

  # ---------------------------------------------------------------------------
  # close validation + not-found
  # ---------------------------------------------------------------------------

  test "close with no session_id or pane_id reports the missing argument" do
    assert {:error, {:missing_argument, "session_id or pane_id"}} =
             PreviewTools.invoke("preview_close", @v3_workspace, %{})
  end

  test "close rejects a non-numeric session_id" do
    assert {:error, :invalid_session_id} =
             PreviewTools.invoke("preview_close", @v3_workspace, %{"session_id" => "abc"})
  end

  test "close reports preview_pane_not_registered for an unknown pane without tmux_session" do
    assert {:error,
            %{
              error: :preview_pane_not_registered,
              pane_id: "%stale-unknown",
              message: message
            }} =
             PreviewTools.invoke("preview_close", @v3_workspace, %{"pane_id" => "%stale-unknown"})

    assert message =~ "Pass tmux_session"
  end

  # ---------------------------------------------------------------------------
  # open_localhost port validation
  # ---------------------------------------------------------------------------

  test "open_localhost rejects a non-numeric port string" do
    assert {:error, :invalid_port} =
             PreviewTools.invoke("preview_open_localhost", @v3_workspace, %{
               "port" => "not-a-port"
             })
  end

  test "open_localhost rejects a missing port" do
    assert {:error, :invalid_port} =
             PreviewTools.invoke("preview_open_localhost", @v3_workspace, %{})
  end

  # ---------------------------------------------------------------------------
  # ensure_server_here gating
  # ---------------------------------------------------------------------------

  test "ensure_server_here requires a tmux_session" do
    assert {:error, %{error: :missing_tmux_session}} =
             PreviewTools.invoke("preview_ensure_server_here", @v3_workspace, %{})
  end

  test "ensure_server_here reports runtime_surface_not_found when no runtime matches" do
    assert {:error, %{error: :runtime_surface_not_found, tmux_session: "dev-ws-tools-nope"}} =
             PreviewTools.invoke("preview_ensure_server_here", @v3_workspace, %{
               "tmux_session" => "dev-ws-tools-nope"
             })
  end

  # ---------------------------------------------------------------------------
  # open_app_here required-session gate
  # ---------------------------------------------------------------------------

  test "open_app_here without a tmux_session reports missing_tmux_session" do
    assert {:error, %{error: :missing_tmux_session, message: message}} =
             PreviewTools.open_app_here(@v3_workspace, %{"actor_id" => "agent-1"})

    assert message =~ "session-scoped Preview MCP URL"
  end

  # ---------------------------------------------------------------------------
  # resolve_workspace error branches
  # ---------------------------------------------------------------------------

  test "resolve_workspace reports workspace_not_found for an unknown workspace_id" do
    assert {:error,
            %{
              error: :workspace_not_found,
              workspace_id: "ws-nope",
              folder_id_format: "folder:<base64url-absolute-path>",
              message: message
            }} =
             PreviewTools.invoke("preview_resolve_workspace", %{}, %{"workspace_id" => "ws-nope"})

    assert message =~ "was not found"
  end

  test "resolve_workspace reports a path resolution error for a disallowed folder" do
    assert {:error, %{error: :workspace_path_not_resolved, path: path}} =
             PreviewTools.invoke("preview_resolve_workspace", %{}, %{
               "workspace_path" => "/definitely/not/an/allowed/root/abc"
             })

    assert path == "/definitely/not/an/allowed/root/abc"
  end

  # ---------------------------------------------------------------------------
  # registration_origin clauses (pure helper)
  # ---------------------------------------------------------------------------

  test "registration_origin prefers display_url origin" do
    assert PreviewTools.registration_origin(%{
             display_url: "http://localhost:5173/foo",
             url: "http://localhost:9999/"
           }) == "http://localhost:5173"
  end

  test "registration_origin falls back to url when display_url is absent" do
    assert PreviewTools.registration_origin(%{url: "http://localhost:5173/foo"}) ==
             "http://localhost:5173"
  end

  test "registration_origin returns nil when neither url is present" do
    assert PreviewTools.registration_origin(%{}) == nil
  end

  # ---------------------------------------------------------------------------
  # surfaces empty / scoped formatting
  # ---------------------------------------------------------------------------

  test "surfaces reports a scoped server status of wrong_tmux_session for off-session surfaces" do
    ws =
      Map.update!(@v3_workspace, :metadata, fn metadata ->
        Map.put(metadata, :terminal_output, "Serving at http://localhost:8765/")
      end)

    assert {:ok, %{surfaces: surfaces}} =
             PreviewTools.invoke("preview_surfaces", ws, %{
               "workspace_id" => ws.id,
               "tmux_session" => "dev-ws-tools-some-other-session"
             })

    # Terminal-detected surfaces carry no tmux_session, so they still match
    # (session_match true). The manager "app" surface likewise has no session.
    assert Enum.all?(surfaces, &(&1.server_status.session_match in [true, false]))
    assert Enum.any?(surfaces, &(&1.name == "localhost:8765"))
  end

  test "surfaces marks every surface server_active and unprobed when probing is disabled" do
    assert {:ok, %{surfaces: surfaces}} =
             PreviewTools.invoke("preview_surfaces", @v3_workspace, %{
               "workspace_id" => @v3_workspace.id
             })

    assert surfaces != []
    assert Enum.all?(surfaces, & &1.server_active)
    assert Enum.all?(surfaces, &(&1.server_status.liveness == "unprobed"))
    refute Enum.any?(surfaces, & &1.snapshot_mode)
    assert Enum.all?(surfaces, &(&1.interaction_mode == "iframe"))
  end

  test "surfaces probes loopback ports and reports dead servers honestly" do
    enable_surface_probe({__MODULE__, :fake_surface_probe})

    ws = %{
      id: @v3_workspace.id,
      metadata: %{
        terminal_output: "Serving at http://localhost:5173/\nAlso http://localhost:4321/\n"
      }
    }

    assert {:ok, %{surfaces: surfaces} = payload} =
             PreviewTools.invoke("preview_surfaces", ws, %{"workspace_id" => ws.id})

    alive = Enum.find(surfaces, &(&1.port == 5173))
    dead = Enum.find(surfaces, &(&1.port == 4321))

    assert alive.server_active
    assert alive.server_status.liveness == "alive"
    refute dead.server_active
    assert dead.server_status.liveness == "dead"

    assert Enum.find_index(surfaces, &(&1.port == 5173)) <
             Enum.find_index(surfaces, &(&1.port == 4321))

    assert payload.next_tool == "preview_open"
    assert payload.next_arguments == %{workspace_id: ws.id, mode: "localhost", port: 5173}
  end

  test "surfaces never recommends a dead loopback port carried by a public surface" do
    enable_surface_probe({__MODULE__, :fake_surface_probe_all_dead})

    assert {:ok, %{surfaces: surfaces} = payload} =
             PreviewTools.invoke("preview_surfaces", @v3_workspace, %{
               "workspace_id" => @v3_workspace.id
             })

    public = Enum.find(surfaces, &(&1.name == "app"))
    loopback = Enum.find(surfaces, &(&1.name == "app-local"))

    assert public.server_active
    assert public.server_status.liveness == "unprobed"
    refute loopback.server_active
    assert loopback.server_status.liveness == "dead"

    assert payload.next_arguments == %{
             workspace_id: @v3_workspace.id,
             mode: "app",
             surface: "app"
           }
  end

  def fake_surface_probe(ports), do: Map.new(ports, &{&1, &1 == 5173})

  def fake_surface_probe_all_dead(ports), do: Map.new(ports, &{&1, false})

  defp enable_surface_probe(prober) do
    prev_probe = Application.get_env(:casein, :preview_surface_probe)
    prev_prober = Application.get_env(:casein, :preview_surface_prober)
    Application.put_env(:casein, :preview_surface_probe, true)
    Application.put_env(:casein, :preview_surface_prober, prober)

    on_exit(fn ->
      restore_env(:preview_surface_probe, prev_probe)
      restore_env(:preview_surface_prober, prev_prober)
    end)
  end

  # ---------------------------------------------------------------------------
  # reload tools require workspace map; browser_control_opts normalization
  # ---------------------------------------------------------------------------

  test "reload_iframe drops blank actor_id and reason from browser control opts" do
    :ok = Phoenix.PubSub.subscribe(Casein.PubSub, "workspace_browser:ws-tools")

    assert {:ok, %{status: "queued", action: "reload_preview_iframe", request_id: request_id}} =
             PreviewTools.invoke("preview_reload_iframe", @v3_workspace, %{
               "actor_id" => "",
               "reason" => ""
             })

    assert_receive {:browser_control, %{"action" => "reload_preview_iframe"} = payload}
    assert payload["request_id"] == request_id
    refute Map.has_key?(payload, "actor_id")
    refute Map.has_key?(payload, "reason")
  end

  test "reload_page queues a workspace page reload without optional opts" do
    :ok = Phoenix.PubSub.subscribe(Casein.PubSub, "workspace_browser:ws-tools")

    assert {:ok, %{status: "queued", action: "reload_page", workspace_id: "ws-tools"}} =
             PreviewTools.invoke("devide_reload_page", @v3_workspace, %{})

    assert_receive {:browser_control, %{"action" => "reload_page", "workspace_id" => "ws-tools"}}
  end

  # ---------------------------------------------------------------------------
  # split_preview_pane guard: missing tmux session
  # ---------------------------------------------------------------------------

  test "split_preview_pane returns :no_tmux_session for a workspace with no sessions" do
    assert {:error, :no_tmux_session} =
             PreviewTools.split_preview_pane(
               %{id: "ws-with-no-sessions"},
               "http://localhost:5173/",
               tmux_session: nil
             )
  end

  # ---------------------------------------------------------------------------
  # list_surfaces public helper
  # ---------------------------------------------------------------------------

  test "list_surfaces exposes the manager app surface" do
    surfaces = PreviewTools.list_surfaces(@v3_workspace)
    assert Enum.any?(surfaces, &(&1.name == "app"))
  end

  # ---------------------------------------------------------------------------
  # definitions metadata buckets (pure)
  # ---------------------------------------------------------------------------

  test "definitions tag read tools as non-mutating and open tools as mutating" do
    defs = PreviewTools.definitions()
    by_name = Map.new(defs, &{&1.name, &1})

    refute by_name["preview_surfaces"].metadata.mutation?
    assert by_name["preview_surfaces"].metadata.danger_level == :low

    assert by_name["preview_open_app"].metadata.mutation?
    assert by_name["preview_open_app"].metadata.danger_level == :medium

    assert by_name["preview_clear_storage"].metadata.danger_level == :high
    assert by_name["preview_close"].metadata.danger_level == :low
  end

  defp restore_env(key, value) do
    if is_nil(value),
      do: Application.delete_env(:casein, key),
      else: Application.put_env(:casein, key, value)
  end

  defp restore_fake_state(key, nil), do: FakeState.delete(key)
  defp restore_fake_state(key, value), do: FakeState.put(key, value)
end
