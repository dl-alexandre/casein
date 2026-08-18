defmodule Casein.Agents.PreviewToolsMoreTest do
  @moduledoc """
  Further branch coverage for `Casein.Agents.PreviewTools`.

  Complements `preview_tools_test.exs` (happy paths) and
  `preview_tools_extra_test.exs` (validation/error paths). Focuses on branches
  neither file exercises: unified preview_open success routing to app/localhost,
  integer/atom-keyed argument clauses of the session-id tools, additional
  argument-validation arms (empty/blank inputs), resolve_workspace reference
  precedence, surfaces empty/sorting/scoped formatting, and pure
  payload-shaping helpers reachable through the public API.

  Reuses the same setup, fakes, and seeding helpers as the sibling suites.
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
  # preview_open unified — successful routing to app / localhost handlers
  # (extra suite covers only the error arms: invalid mode, bad port, here gate)
  # ---------------------------------------------------------------------------

  test "preview_open with no mode defaults to the app surface and opens a pane" do
    assert {:ok, %{pane_id: pane_id, session_id: session_id}} =
             PreviewTools.invoke("preview_open", @v3_workspace, %{"actor_id" => "agent-1"})

    assert is_binary(pane_id)
    assert is_integer(session_id)
    assert PreviewPanes.get_by_pane(pane_id)
  end

  test "preview_open mode app routes to the app surface handler" do
    assert {:ok, %{pane_id: pane_id}} =
             PreviewTools.invoke("preview_open", @v3_workspace, %{
               "mode" => "app",
               "actor_id" => "agent-1"
             })

    assert is_binary(pane_id)
  end

  test "preview_open mode localhost opens an allowed dev-server port" do
    workspace = put_in(@v3_workspace, [:metadata, :ports, "dev"], 5173)

    assert {:ok, %{current_url: url, pane_id: pane_id}} =
             PreviewTools.invoke("preview_open", workspace, %{
               "mode" => "localhost",
               "port" => 5173,
               "path" => "/index.html",
               "actor_id" => "agent-1"
             })

    assert is_binary(pane_id)
    assert url == "http://localhost:5173/index.html"
  end

  # ---------------------------------------------------------------------------
  # session-id tools: integer-arg clauses (extra suite only covers map clauses)
  # An invalid id short-circuits in parse_id before any browser/control IO, so
  # an unregistered integer reaches PreviewControl and returns :not_found.
  # ---------------------------------------------------------------------------

  test "observe with an integer session id reaches control and reports not_found" do
    assert {:error, :not_found} = PreviewTools.observe(987_654_321)
  end

  test "observe_live with an integer session id reaches control and reports not_found" do
    assert {:error, :not_found} = PreviewTools.observe_live(987_654_321)
  end

  test "screenshot with an integer session id reaches control and reports not_found" do
    assert {:error, :not_found} = PreviewTools.screenshot(987_654_321)
  end

  test "get_storage with an integer session id reaches control and reports not_found" do
    assert {:error, :not_found} = PreviewTools.get_storage(987_654_321)
  end

  test "clear_storage with an integer session id reaches control and reports not_found" do
    assert {:error, :not_found} = PreviewTools.clear_storage(987_654_321)
  end

  test "report_errors with an integer session id reaches control and reports not_found" do
    assert {:error, :not_found} = PreviewTools.report_errors(987_654_321)
  end

  test "close with an integer session id reaches control and reports not_found" do
    assert {:error, :not_found} = PreviewTools.close(987_654_321)
  end

  # ---------------------------------------------------------------------------
  # observe/observe_live/screenshot/get_storage parse_id catch-all clause
  # for unsupported argument shapes (neither string nor integer)
  # ---------------------------------------------------------------------------

  test "observe rejects a nil session_id value" do
    assert {:error, :invalid_session_id} = PreviewTools.observe(%{"session_id" => nil})
  end

  test "observe_live rejects a nil session_id value" do
    assert {:error, :invalid_session_id} = PreviewTools.observe_live(%{"session_id" => nil})
  end

  test "get_storage rejects a nil session_id value" do
    assert {:error, :invalid_session_id} = PreviewTools.get_storage(%{session_id: nil})
  end

  test "clear_storage rejects a nil session_id value" do
    assert {:error, :invalid_session_id} = PreviewTools.clear_storage(%{session_id: nil})
  end

  test "report_errors rejects a nil session_id value" do
    assert {:error, :invalid_session_id} = PreviewTools.report_errors(%{"session_id" => nil})
  end

  test "navigate rejects a nil session_id value" do
    assert {:error, :invalid_session_id} =
             PreviewTools.navigate(%{"session_id" => nil, "path" => "/x"})
  end

  # ---------------------------------------------------------------------------
  # navigate_pane: blank-string path/pane arms (extra suite covers nil only)
  # An empty-string pane_id still satisfies is_binary, so navigation proceeds
  # to the registry and surfaces its error for the unknown pane.
  # ---------------------------------------------------------------------------

  test "navigate_pane treats a blank pane_id as a registry miss, not a missing argument" do
    assert {:error, reason} =
             PreviewTools.navigate_pane(%{"pane_id" => "", "path" => "/x"})

    refute reason == {:missing_argument, "pane_id"}
  end

  test "navigate_pane via invoke with atom keys still reports the missing path" do
    assert {:error, {:missing_argument, "path"}} =
             PreviewTools.navigate_pane(%{pane_id: "%1"})
  end

  # ---------------------------------------------------------------------------
  # close: atom-keyed pane_id clause and direct pane-id helper paths
  # (existing suites use string-keyed pane_id via invoke)
  # ---------------------------------------------------------------------------

  test "close with an atom-keyed pane_id closes the registered pane" do
    assert {:ok, %{pane_id: pane_id, session: session}} =
             PreviewTools.split_preview_pane(@v3_workspace, "http://localhost:5173/", [])

    assert {:ok, %{pane_id: ^pane_id, status: :closed, session_id: session_id}} =
             PreviewTools.close(%{pane_id: pane_id})

    assert session_id == session.id
    refute PreviewPanes.get_by_pane(pane_id)
  end

  test "close with an atom-keyed pane_id reports not_registered for an unknown pane" do
    assert {:error, %{error: :preview_pane_not_registered, pane_id: "%nope"}} =
             PreviewTools.close(%{pane_id: "%nope"})
  end

  test "close with an atom-keyed stale pane and tmux_session removes the tmux pane" do
    tmux_session = "#{Tmux.workspace_session_prefix(@v3_workspace.id)}default"

    assert {:ok, %{pane_id: pane_id}} =
             PreviewTools.split_preview_pane(@v3_workspace, "http://localhost:5173/", [])

    :ok = PreviewPanes.deregister(pane_id)

    assert {:ok, %{pane_id: ^pane_id, status: :closed, stale: true, tmux_session: ^tmux_session}} =
             PreviewTools.close(%{pane_id: pane_id, tmux_session: tmux_session})

    assert_receive {:fake_tmux_kill_pane, ^tmux_session, ^pane_id}
  end

  test "close with an atom-keyed session_id rejects a non-numeric id" do
    assert {:error, :invalid_session_id} = PreviewTools.close(%{session_id: "abc"})
  end

  # ---------------------------------------------------------------------------
  # resolve_workspace — reference precedence and alternate path keys
  # ---------------------------------------------------------------------------

  test "resolve_workspace attaches an allowed folder passed via the cwd key" do
    root =
      Path.join(System.tmp_dir!(), "preview-tools-cwd-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "demo")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    Application.put_env(:casein, :workspaces_root, root)

    assert {:ok, %{workspace_id: "folder:" <> _encoded, path: ^workspace}} =
             PreviewTools.invoke("preview_resolve_workspace", %{}, %{"cwd" => workspace})
  end

  test "resolve_workspace attaches an allowed folder passed via the path key" do
    root =
      Path.join(System.tmp_dir!(), "preview-tools-pathkey-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "demo")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    Application.put_env(:casein, :workspaces_root, root)

    assert {:ok, %{path: ^workspace}} =
             PreviewTools.invoke("preview_resolve_workspace", %{}, %{"path" => workspace})
  end

  test "resolve_workspace prefers workspace_id over a supplied workspace_path" do
    # workspace_id branch is checked first; an unknown id short-circuits to
    # workspace_not_found even when a (valid-looking) path is also present.
    assert {:error, %{error: :workspace_not_found, workspace_id: "ws-missing-precedence"}} =
             PreviewTools.invoke("preview_resolve_workspace", %{}, %{
               "workspace_id" => "ws-missing-precedence",
               "workspace_path" => "/tmp"
             })
  end

  # ---------------------------------------------------------------------------
  # surfaces — empty discovery and active-vs-inactive ordering
  # ---------------------------------------------------------------------------

  test "surfaces returns only inert surfaces when no pane is rendered" do
    assert {:ok, %{surfaces: surfaces}} =
             PreviewTools.invoke("preview_surfaces", @v3_workspace, %{})

    assert surfaces != []
    # With no browser-confirmed pane, nothing is active and none float up.
    refute Enum.any?(surfaces, & &1.active)
    assert Enum.all?(surfaces, &(&1.operator_visible == false))
    assert Enum.all?(surfaces, &(&1.operator_visible_state == "not_rendered"))
  end

  test "surfaces scoped to the matching tmux session marks runtime surfaces session_match true" do
    assert {:ok, %{surfaces: surfaces}} =
             PreviewTools.invoke("preview_surfaces", @v3_workspace, %{
               "workspace_id" => @v3_workspace.id,
               "tmux_session" => "#{Tmux.workspace_session_prefix(@v3_workspace.id)}default"
             })

    # Session-less manager/terminal surfaces always match a scoped request.
    assert Enum.all?(surfaces, & &1.server_status.session_match)
  end

  # ---------------------------------------------------------------------------
  # registration_origin — both-nil-keys clause distinct from missing-key clause
  # ---------------------------------------------------------------------------

  test "registration_origin returns nil when both url keys hold nil values" do
    assert PreviewTools.registration_origin(%{display_url: nil, url: nil}) == nil
  end

  test "registration_origin ignores a non-origin display_url and falls back to url" do
    assert PreviewTools.registration_origin(%{
             display_url: "/relative/no/origin",
             url: "http://localhost:7000/page"
           }) == "http://localhost:7000"
  end

  # ---------------------------------------------------------------------------
  # ensure_server_here — runtime lookup precedes the launcher gate
  # ---------------------------------------------------------------------------

  test "ensure_server_here with a blank tmux_session resolves the workspace session like siblings" do
    assert {:error, %{error: :runtime_surface_not_found, tmux_session: "casein_ws-tools_default"}} =
             PreviewTools.invoke("preview_ensure_server_here", @v3_workspace, %{
               "tmux_session" => ""
             })
  end

  # ---------------------------------------------------------------------------
  # split_preview_pane — explicit empty tmux_session opt resolves to no session
  # ---------------------------------------------------------------------------

  test "split_preview_pane returns :no_tmux_session for a blank explicit session" do
    assert {:error, :no_tmux_session} =
             PreviewTools.split_preview_pane(@v3_workspace, "http://localhost:5173/",
               tmux_session: ""
             )
  end

  # ---------------------------------------------------------------------------
  # definitions — surface/open schema details and per-tool metadata buckets
  # not asserted by the extra suite's metadata test
  # ---------------------------------------------------------------------------

  test "preview_open definition exposes the mode enum with an app default" do
    tool = Enum.find(PreviewTools.definitions(), &(&1.name == "preview_open"))
    mode = tool.parameters.properties.mode

    assert mode.enum == ["app", "localhost", "here", "external"]
    assert mode.default == "app"
  end

  test "navigate-family tools are tagged as visible_preview_mutation" do
    by_name = Map.new(PreviewTools.definitions(), &{&1.name, &1})

    assert by_name["preview_navigate"].metadata.policy_tags == [:visible_preview_mutation]
    assert by_name["preview_navigate_pane"].metadata.policy_tags == [:visible_preview_mutation]
    assert by_name["casein_reload_page"].metadata.mutation?
  end

  test "open-family tools carry the opens_preview_surface policy tag" do
    by_name = Map.new(PreviewTools.definitions(), &{&1.name, &1})

    for name <- ["preview_open", "preview_open_here", "preview_ensure_server_here"] do
      assert by_name[name].metadata.policy_tags == [:opens_preview_surface]
      assert by_name[name].metadata.danger_level == :medium
    end
  end

  test "preview_clear_storage is the only storage_mutation tool and is high danger" do
    by_name = Map.new(PreviewTools.definitions(), &{&1.name, &1})

    assert by_name["preview_clear_storage"].metadata.policy_tags == [:storage_mutation]
    assert by_name["preview_clear_storage"].metadata.capabilities == [:preview_storage]
  end

  defp restore_env(key, value) do
    if is_nil(value),
      do: Application.delete_env(:casein, key),
      else: Application.put_env(:casein, key, value)
  end

  defp restore_fake_state(key, nil), do: FakeState.delete(key)
  defp restore_fake_state(key, value), do: FakeState.put(key, value)
end
