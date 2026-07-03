defmodule DevIdeWeb.WorkspaceLive.Show.TerminalChromeHelpersTest do
  @moduledoc """
  Direct-call unit tests for the PURE helper functions of
  `DevIdeWeb.WorkspaceLive.Show.TerminalChrome`.

  These exercise geometry math, activity/status derivation, title/path
  formatting, pane selection, preview helpers, and session label helpers by
  calling each public `def` directly and asserting exact return values. The
  HEEx-rendering function components (render_*, pane_resize_handles,
  assign_tmux_pane_geometry) are intentionally NOT exercised here — they
  require a LiveView render harness and are out of scope.
  """
  use DevIDE.TestCase, async: true

  alias DevIdeWeb.WorkspaceLive.Show.TerminalChrome, as: TC
  alias DevIDE.Terminals.Session.Info, as: SessionInfo

  # ── geometry: tmux_dimension / percentage ──────────────────────────────

  describe "tmux_dimension/1" do
    test "clamps integers to a non-negative floor" do
      assert TC.tmux_dimension(5) == 5
      assert TC.tmux_dimension(0) == 0
      assert TC.tmux_dimension(-3) == 0
    end

    test "non-integers become 0" do
      assert TC.tmux_dimension(nil) == 0
      assert TC.tmux_dimension("10") == 0
      assert TC.tmux_dimension(1.5) == 0
    end
  end

  describe "percentage/2" do
    test "zero total short-circuits to 0" do
      assert TC.percentage(42, 0) == 0
    end

    test "computes a rounded percentage" do
      assert TC.percentage(1, 2) == 50.0
      assert TC.percentage(1, 3) == 33.3333
      assert TC.percentage(0, 4) == 0.0
    end
  end

  # ── tmux_pane_geometry_ready? / tmux_pane_surface_ready? / ready? ───────

  describe "tmux_pane_geometry_ready?/1" do
    test "true only when both width and height are positive" do
      assert TC.tmux_pane_geometry_ready?(%{width: 10, height: 4})
      refute TC.tmux_pane_geometry_ready?(%{width: 0, height: 4})
      refute TC.tmux_pane_geometry_ready?(%{width: 10, height: 0})
      refute TC.tmux_pane_geometry_ready?(%{width: nil, height: nil})
    end
  end

  describe "tmux_pane_surface_ready?/1" do
    test "true when non-empty, has an active pane, and all panes have geometry" do
      panes = [
        %{active: true, width: 10, height: 4},
        %{active: false, width: 5, height: 4}
      ]

      assert TC.tmux_pane_surface_ready?(panes)
    end

    test "false on empty list" do
      refute TC.tmux_pane_surface_ready?([])
    end

    test "false when no pane is active" do
      refute TC.tmux_pane_surface_ready?([%{active: false, width: 10, height: 4}])
    end

    test "false when any pane lacks geometry" do
      panes = [
        %{active: true, width: 10, height: 4},
        %{active: false, width: 0, height: 4}
      ]

      refute TC.tmux_pane_surface_ready?(panes)
    end
  end

  describe "tmux_geometry_ready?/1" do
    test "requires more than one pane and a ready surface" do
      one = [%{active: true, width: 10, height: 4}]
      refute TC.tmux_geometry_ready?(one)

      two = [
        %{active: true, width: 10, height: 4},
        %{active: false, width: 5, height: 4}
      ]

      assert TC.tmux_geometry_ready?(two)
    end

    test "two panes but surface not ready is false" do
      two = [
        %{active: false, width: 10, height: 4},
        %{active: false, width: 5, height: 4}
      ]

      refute TC.tmux_geometry_ready?(two)
    end
  end

  # ── active_tmux_window_panes / renderable_tmux_window_panes ─────────────

  describe "active_tmux_window_panes/1" do
    test "returns the active window's pane_list" do
      windows = [
        %{active: false, pane_list: [%{id: "a"}]},
        %{active: true, pane_list: [%{id: "b"}, %{id: "c"}]}
      ]

      assert TC.active_tmux_window_panes(windows) == [%{id: "b"}, %{id: "c"}]
    end

    test "active window without a list yields []" do
      assert TC.active_tmux_window_panes([%{active: true, pane_list: nil}]) == []
    end

    test "no active window yields []" do
      assert TC.active_tmux_window_panes([%{active: false, pane_list: [%{id: "a"}]}]) == []
    end

    test "non-list argument yields []" do
      assert TC.active_tmux_window_panes(nil) == []
      assert TC.active_tmux_window_panes(%{}) == []
    end
  end

  describe "tmux_pane_bounds/1" do
    test "computes the maximum right/bottom extent, left/top pinned to 0" do
      panes = [
        %{left: 0, top: 0, width: 10, height: 5},
        %{left: 10, top: 0, width: 8, height: 12}
      ]

      assert TC.tmux_pane_bounds(panes) == %{left: 0, top: 0, width: 18, height: 12}
    end

    test "empty panes keep the seed minimum of 1x1" do
      assert TC.tmux_pane_bounds([]) == %{left: 0, top: 0, width: 1, height: 1}
    end
  end

  describe "renderable_tmux_window_panes/1" do
    test "returns all panes when none is zoomed" do
      panes = [
        %{id: "a", active: true, zoomed?: false, left: 0, top: 0, width: 6, height: 8},
        %{id: "b", active: false, zoomed?: false, left: 6, top: 0, width: 6, height: 8}
      ]

      assert TC.renderable_tmux_window_panes(panes) == panes
    end

    test "collapses to a single full-bounds tile for the zoomed active pane" do
      panes = [
        %{id: "a", active: true, zoomed?: true, left: 2, top: 2, width: 4, height: 4},
        %{id: "b", active: false, zoomed?: false, left: 6, top: 0, width: 6, height: 8}
      ]

      assert [tile] = TC.renderable_tmux_window_panes(panes)
      assert tile.id == "a"
      # bounds = max right/bottom across panes = width 12, height 8
      assert tile.left == 0
      assert tile.top == 0
      assert tile.width == 12
      assert tile.height == 8
    end

    test "non-list argument yields []" do
      assert TC.renderable_tmux_window_panes(nil) == []
    end
  end

  describe "tmux_pane_style/2" do
    test "renders a left/top/width/height percentage style string" do
      pane = %{left: 0, top: 0, width: 1, height: 1}
      bounds = %{width: 2, height: 2}

      assert TC.tmux_pane_style(pane, bounds) ==
               "left: 0.0%; top: 0.0%; width: 50.0%; height: 50.0%;"
    end
  end

  # ── activity timestamps / states ───────────────────────────────────────

  describe "parse_activity_timestamp/1" do
    test "integers pass through" do
      assert TC.parse_activity_timestamp(123) == {:ok, 123}
    end

    test "numeric strings parse" do
      assert TC.parse_activity_timestamp("456") == {:ok, 456}
    end

    test "non-numeric strings error" do
      assert TC.parse_activity_timestamp("123abc") == :error
      assert TC.parse_activity_timestamp("nope") == :error
    end

    test "other types error" do
      assert TC.parse_activity_timestamp(nil) == :error
      assert TC.parse_activity_timestamp(%{}) == :error
    end
  end

  describe "activity_age_seconds/2" do
    test "returns age clamped at 0 for a valid past timestamp" do
      assert TC.activity_age_seconds(100, 250) == {:ok, 150}
    end

    test "future timestamp clamps to 0" do
      assert TC.activity_age_seconds(300, 250) == {:ok, 0}
    end

    test "non-positive timestamp errors" do
      assert TC.activity_age_seconds(0, 250) == :error
    end

    test "unparseable activity errors" do
      assert TC.activity_age_seconds("nope", 250) == :error
      assert TC.activity_age_seconds(nil, 250) == :error
    end
  end

  describe "window_activity_state/2" do
    test "fresh under 30s" do
      assert TC.window_activity_state(%{activity: 1000}, 1010) == :fresh
    end

    test "recent under 300s" do
      assert TC.window_activity_state(%{activity: 1000}, 1100) == :recent
    end

    test "idle at/over 300s" do
      assert TC.window_activity_state(%{activity: 1000}, 1400) == :idle
    end

    test "idle when activity is missing/unparseable" do
      assert TC.window_activity_state(%{}, 1000) == :idle
      assert TC.window_activity_state(%{activity: "nope"}, 1000) == :idle
    end
  end

  describe "pane_activity_state/2" do
    test "fresh / recent / idle thresholds" do
      assert TC.pane_activity_state(%{activity: 1000}, 1005) == :fresh
      assert TC.pane_activity_state(%{activity: 1000}, 1200) == :recent
      assert TC.pane_activity_state(%{activity: 1000}, 9000) == :idle
      assert TC.pane_activity_state(%{}, 9000) == :idle
    end
  end

  # ── pane status / bell / ui_active ─────────────────────────────────────

  describe "pane_status/2" do
    test "bell wins over everything" do
      pane = %{bell: true, active: true, activity_flag: true, width: 10, height: 4}
      assert TC.pane_status(pane, 1000) == :bell
    end

    test "active when not belling" do
      pane = %{active: true, width: 10, height: 4}
      assert TC.pane_status(pane, 1000) == :active
    end

    test "fresh from activity_flag when inactive" do
      pane = %{active: false, activity_flag: true, width: 10, height: 4}
      assert TC.pane_status(pane, 1000) == :fresh
    end

    test "fresh/recent derived from activity timestamp" do
      fresh = %{active: false, activity: 1000, width: 10, height: 4}
      assert TC.pane_status(fresh, 1010) == :fresh

      recent = %{active: false, activity: 1000, width: 10, height: 4}
      assert TC.pane_status(recent, 1100) == :recent
    end

    test "alive when only geometry is ready" do
      pane = %{active: false, width: 10, height: 4}
      assert TC.pane_status(pane, 9_000_000) == :alive
    end

    test "unknown when geometry not ready and no activity" do
      pane = %{active: false, width: 0, height: 0}
      assert TC.pane_status(pane, 9_000_000) == :unknown
    end
  end

  describe "pane_bell?/1" do
    test "true only for an explicit true bell flag" do
      assert TC.pane_bell?(%{bell: true})
      refute TC.pane_bell?(%{bell: false})
      refute TC.pane_bell?(%{})
      refute TC.pane_bell?(%{bell: "true"})
    end
  end

  describe "pane_ui_active?/3" do
    test "matches the highlight id when present" do
      assert TC.pane_ui_active?(%{id: "p1"}, "p1", "p2")
      refute TC.pane_ui_active?(%{id: "p2"}, "p1", "p2")
    end

    test "falls back to the tmux active id when highlight is blank" do
      assert TC.pane_ui_active?(%{id: "p2"}, "", "p2")
      assert TC.pane_ui_active?(%{id: "p2"}, nil, "p2")
    end

    test "false when no active id resolves" do
      refute TC.pane_ui_active?(%{id: "p1"}, "", nil)
      refute TC.pane_ui_active?(%{id: "p1"}, nil, "")
    end
  end

  # ── class / label tables ───────────────────────────────────────────────

  describe "window_activity_class/1 and window_activity_label/1" do
    test "fresh / recent / idle mappings" do
      assert TC.window_activity_class(:fresh) =~ "bg-emerald-400"
      assert TC.window_activity_class(:recent) == "bg-amber-300"
      assert TC.window_activity_class(:idle) == "bg-base-content/20"

      assert TC.window_activity_label(:fresh) == "Recent tmux window activity"
      assert TC.window_activity_label(:recent) == "Tmux window activity in the last five minutes"
      assert TC.window_activity_label(:idle) == "No recent tmux window activity"
    end
  end

  describe "pane_status_class/1 and pane_status_label/1" do
    test "covers every status atom" do
      for status <- [:active, :bell, :fresh, :recent, :alive, :unknown] do
        assert is_binary(TC.pane_status_class(status))
        assert is_binary(TC.pane_status_label(status))
      end

      assert TC.pane_status_class(:recent) == "bg-amber-300"
      assert TC.pane_status_label(:active) == "Active tmux pane"
      assert TC.pane_status_label(:bell) == "Tmux pane bell alert"
      assert TC.pane_status_label(:unknown) == "Tmux pane geometry unavailable"
    end
  end

  # ── titles / paths / blank handling ────────────────────────────────────

  describe "blank_to_nil/1" do
    test "trims and nils empties" do
      assert TC.blank_to_nil("  hi  ") == "hi"
      assert TC.blank_to_nil("   ") == nil
      assert TC.blank_to_nil("") == nil
    end

    test "non-binaries become nil" do
      assert TC.blank_to_nil(nil) == nil
      assert TC.blank_to_nil(123) == nil
    end
  end

  describe "short_path/1" do
    test "empty inputs return empty string" do
      assert TC.short_path(nil) == ""
      assert TC.short_path("") == ""
    end

    test "single-segment path returns the segment" do
      assert TC.short_path("/usr") == "usr"
    end

    test "keeps the last two segments" do
      assert TC.short_path("/a/b/c/d") == "c/d"
    end

    test "collapses the HOME prefix to ~" do
      home = System.get_env("HOME")

      if is_binary(home) and home != "" do
        assert TC.short_path(home <> "/projects/app") == "projects/app"
      else
        assert TC.short_path("/projects/app") == "projects/app"
      end
    end
  end

  describe "pane_path_label/1" do
    test "basename of the current path" do
      assert TC.pane_path_label(%{current_path: "/home/dev/app"}) == "app"
    end

    test "unknown for blank path" do
      assert TC.pane_path_label(%{current_path: "   "}) == "unknown"
      assert TC.pane_path_label(%{current_path: nil}) == "unknown"
    end
  end

  describe "pane_display_title/1 and pane_full_title/1" do
    test "display title joins basename and command" do
      pane = %{current_path: "/home/dev/app", current_command: "vim"}
      assert TC.pane_display_title(pane) == "app · vim"
    end

    test "display title falls back to shell for blank command" do
      pane = %{current_path: "/home/dev/app", current_command: nil}
      assert TC.pane_display_title(pane) == "app · shell"
    end

    test "full title uses the full path" do
      pane = %{current_path: "/home/dev/app", current_command: "vim"}
      assert TC.pane_full_title(pane) == "/home/dev/app · vim"
    end

    test "full title uses 'unknown path' for blank path" do
      pane = %{current_path: "  ", current_command: "vim"}
      assert TC.pane_full_title(pane) == "unknown path · vim"
    end

    test "full title leads with the application-set pane title" do
      pane = %{
        current_path: "/home/dev/app",
        current_command: "claude",
        pane_title: "✳ Fix screen collapsing problem"
      }

      assert TC.pane_full_title(pane) == "Fix screen collapsing problem · /home/dev/app · claude"
    end
  end

  describe "window_full_title/2" do
    test "window name alone when there is no matching pane" do
      window = %{name: "main", pane_list: []}
      assert TC.window_full_title(window) == "main"
    end

    test "appends the highlighted pane's full title" do
      window = %{
        name: "main",
        pane_list: [
          %{id: "p1", active: false, current_path: "/x", current_command: "sh"},
          %{id: "p2", active: true, current_path: "/y", current_command: "vim"}
        ]
      }

      assert TC.window_full_title(window, "p1") == "main · /x · sh"
    end

    test "falls back to the active pane when no highlight matches" do
      window = %{
        name: "main",
        pane_list: [
          %{id: "p1", active: false, current_path: "/x", current_command: "sh"},
          %{id: "p2", active: true, current_path: "/y", current_command: "vim"}
        ]
      }

      assert TC.window_full_title(window, nil) == "main · /y · vim"
    end
  end

  # ── pane selection ─────────────────────────────────────────────────────

  describe "terminal_surface_pane_id/4" do
    test "returns the active id when it is a non-preview operator pane" do
      panes = [%{id: "p1", active: true}, %{id: "p2", active: false}]
      assert TC.terminal_surface_pane_id(panes, %{}, "p1") == "p1"
    end

    test "skips a preview pane in favor of the previous operator pane" do
      panes = [%{id: "p1", active: true}, %{id: "p2", active: false}]
      preview_panes = %{"p1" => %{}}

      assert TC.terminal_surface_pane_id(panes, preview_panes, "p1", "p2") == "p2"
    end

    test "falls back to the active non-preview pane" do
      panes = [%{id: "prev", active: false}, %{id: "p2", active: true}]
      preview_panes = %{"prev" => %{}}

      assert TC.terminal_surface_pane_id(panes, preview_panes, nil, nil) == "p2"
    end

    test "falls back to the first non-preview pane when none is active" do
      panes = [%{id: "p1", active: false}, %{id: "p2", active: false}]
      assert TC.terminal_surface_pane_id(panes, nil, nil, nil) == "p1"
    end

    test "nil when there are no operator panes" do
      panes = [%{id: "p1", active: false}]
      preview_panes = %{"p1" => %{}}
      assert TC.terminal_surface_pane_id(panes, preview_panes, nil, nil) == nil
    end
  end

  describe "focused_pane_session_sid/3" do
    test "returns the focused pane's session_sid" do
      pane_data = %{"p1" => %{session_sid: "sid-1"}}
      assert TC.focused_pane_session_sid(pane_data, "p1", "fallback") == "sid-1"
    end

    test "falls back when the pane has a blank sid" do
      pane_data = %{"p1" => %{session_sid: ""}}
      assert TC.focused_pane_session_sid(pane_data, "p1", "fallback") == "fallback"
    end

    test "falls back when the pane is missing" do
      assert TC.focused_pane_session_sid(%{}, "missing", "fallback") == "fallback"
    end

    test "falls back when pane_data is not a map" do
      assert TC.focused_pane_session_sid(nil, "p1", "fallback") == "fallback"
    end
  end

  # ── preview helpers ────────────────────────────────────────────────────

  describe "preview_viewport_label/1" do
    test "atom-key dimensions" do
      assert TC.preview_viewport_label(%{viewport: %{width: 800, height: 600}}) == "800x600"
    end

    test "string-key dimensions" do
      assert TC.preview_viewport_label(%{"viewport" => %{"width" => 1024, "height" => 768}}) ==
               "1024x768"
    end

    test "string viewport value passes through (atom and string key)" do
      assert TC.preview_viewport_label(%{viewport: "mobile"}) == "mobile"
      assert TC.preview_viewport_label(%{"viewport" => "tablet"}) == "tablet"
    end

    test "nil for unknown shapes" do
      assert TC.preview_viewport_label(%{}) == nil
      assert TC.preview_viewport_label(nil) == nil
    end
  end

  describe "preview_snapshot_mode?/1 and preview_playback_mode?/1" do
    test "snapshot true for an artifact URL that is not playback" do
      assert TC.preview_snapshot_mode?(%{display_url: "/preview-artifacts/x.png"})
      assert TC.preview_snapshot_mode?(%{"display_url" => "/preview-artifacts/y.png"})
    end

    test "snapshot false for a playback artifact" do
      refute TC.preview_snapshot_mode?(%{display_url: "/preview-artifacts/x.webm"})
    end

    test "snapshot false for non-artifact url and bad shapes" do
      refute TC.preview_snapshot_mode?(%{display_url: "http://x"})
      refute TC.preview_snapshot_mode?(%{})
    end

    test "playback true for webm/mp4/fit=playback artifacts" do
      assert TC.preview_playback_mode?(%{display_url: "/preview-artifacts/a.webm"})
      assert TC.preview_playback_mode?(%{"display_url" => "/preview-artifacts/a.mp4"})
      assert TC.preview_playback_mode?(%{display_url: "/preview-artifacts/a?fit=playback"})
    end

    test "playback false for non-playback artifact and bad shapes" do
      refute TC.preview_playback_mode?(%{display_url: "/preview-artifacts/a.png"})
      refute TC.preview_playback_mode?(%{})
    end
  end

  describe "preview_proxied?/1" do
    test "true for a /preview-proxy/ url (atom and string key)" do
      assert TC.preview_proxied?(%{display_url: "/preview-proxy/abc"})
      assert TC.preview_proxied?(%{"display_url" => "/preview-proxy/abc"})
    end

    test "false otherwise" do
      refute TC.preview_proxied?(%{display_url: "/preview-artifacts/a.png"})
      refute TC.preview_proxied?(%{})
    end
  end

  describe "preview_iframe_sandbox/1" do
    test "returns the fixed sandbox attribute" do
      assert TC.preview_iframe_sandbox(%{}) ==
               "allow-scripts allow-same-origin allow-forms allow-popups allow-modals"
    end
  end

  describe "preview_pane_title/1" do
    test "prefers display_url, then url, across key styles" do
      assert TC.preview_pane_title(%{display_url: "http://a"}) == "http://a"
      assert TC.preview_pane_title(%{"display_url" => "http://b"}) == "http://b"
      assert TC.preview_pane_title(%{url: "http://c"}) == "http://c"
      assert TC.preview_pane_title(%{"url" => "http://d"}) == "http://d"
    end

    test "defaults to 'preview'" do
      assert TC.preview_pane_title(%{}) == "preview"
    end
  end

  describe "preview_display_url/1 and preview_tmux_session/1" do
    test "display_url prefers :display_url then :url and falls back across key styles" do
      assert TC.preview_display_url(%{display_url: "http://a"}) == "http://a"
      assert TC.preview_display_url(%{url: "http://b"}) == "http://b"
      assert TC.preview_display_url(%{"display_url" => "http://c"}) == "http://c"
      assert TC.preview_display_url(%{}) == nil
      assert TC.preview_display_url(nil) == nil
    end

    test "tmux_session reads either key style" do
      assert TC.preview_tmux_session(%{tmux_session: "devide_a_b"}) == "devide_a_b"
      assert TC.preview_tmux_session(%{"tmux_session" => "devide_c_d"}) == "devide_c_d"
      assert TC.preview_tmux_session(%{}) == nil
      assert TC.preview_tmux_session(nil) == nil
    end
  end

  describe "preview_session_mismatch?/2" do
    test "true only when both sessions are present and differ" do
      assert TC.preview_session_mismatch?(%{tmux_session: "s1"}, "s2")
      refute TC.preview_session_mismatch?(%{tmux_session: "s1"}, "s1")
      refute TC.preview_session_mismatch?(%{tmux_session: ""}, "s2")
      refute TC.preview_session_mismatch?(%{}, "s2")
      refute TC.preview_session_mismatch?(%{tmux_session: "s1"}, "")
      refute TC.preview_session_mismatch?(%{tmux_session: "s1"}, nil)
    end
  end

  describe "preview_session_label/2" do
    test "mismatch produces an 'Other session' label" do
      label = TC.preview_session_label(%{tmux_session: "devide_a_b_alpha"}, "devide_x_y_beta")
      assert label =~ "Other session: "
    end

    test "matching/present session produces a 'Session' label" do
      label = TC.preview_session_label(%{tmux_session: "devide_a_b_alpha"}, "devide_a_b_alpha")
      assert label =~ "Session "
      refute label =~ "Other session"
    end

    test "unknown when no preview session" do
      assert TC.preview_session_label(%{}, "devide_a_b") == "Session unknown"
    end
  end

  describe "preview_session_title/2" do
    test "includes the preview session, and the active session on mismatch" do
      title = TC.preview_session_title(%{tmux_session: "s1"}, "s2")
      assert title == "Preview tmux_session=s1 · active tmux_session=s2"
    end

    test "drops the active clause when sessions match" do
      title = TC.preview_session_title(%{tmux_session: "s1"}, "s1")
      assert title == "Preview tmux_session=s1"
    end

    test "uses 'unknown' for a blank preview session" do
      title = TC.preview_session_title(%{}, "s2")
      assert title == "Preview tmux_session=unknown"
    end
  end

  describe "preview_favicon_url/1" do
    test "uses the local favicon for an http(s) url" do
      assert TC.preview_favicon_url("https://example.com/path") == "/favicon.ico"
    end

    test "nil for a non-http url or empty host" do
      assert TC.preview_favicon_url("ftp://example.com") == nil
      assert TC.preview_favicon_url("not a url") == nil
    end

    test "derives the url from a preview map" do
      assert TC.preview_favicon_url(%{display_url: "https://host.test/x"}) == "/favicon.ico"

      assert TC.preview_favicon_url(%{}) == nil
    end

    test "nil for unsupported argument" do
      assert TC.preview_favicon_url(nil) == nil
      assert TC.preview_favicon_url(123) == nil
    end
  end

  describe "preview_pane_rect_json/2" do
    test "encodes percentage rect as JSON" do
      pane = %{left: 0, top: 0, width: 1, height: 1}
      bounds = %{width: 2, height: 2}

      assert Jason.decode!(TC.preview_pane_rect_json(pane, bounds)) ==
               %{"left" => 0.0, "top" => 0.0, "width" => 50.0, "height" => 50.0}
    end
  end

  # ── pane picker / agent label ──────────────────────────────────────────

  describe "pane_picker_label/3" do
    test "overlay label wins when there is no preview" do
      assert TC.pane_picker_label(%{}, nil, "Agent: build") == "Agent: build"
    end

    test "path · command when no preview and no overlay" do
      pane = %{current_path: "/home/dev/app", current_command: "vim"}
      assert TC.pane_picker_label(pane, nil, nil) == "app · vim"
    end

    test "application-set pane title wins over path · command" do
      pane = %{
        current_path: "/home/dev/app",
        current_command: "claude",
        pane_title: "✳ Fix screen collapsing problem"
      }

      assert TC.pane_picker_label(pane, nil, nil) == "Fix screen collapsing problem"
    end

    test "prefers an already-derived task summary over re-parsing the title" do
      pane = %{
        current_path: "/home/dev/app",
        current_command: "claude",
        pane_title: "ignored",
        task_summary: "Ship title state"
      }

      assert TC.pane_picker_label(pane, nil, nil) == "Ship title state"
    end

    test "falls back when the title just repeats the path basename" do
      pane = %{current_path: "/home/dev/app", current_command: "node", pane_title: "app"}
      assert TC.pane_picker_label(pane, nil, nil) == "app · node"
    end

    test "overlay label still wins over the pane title" do
      pane = %{
        current_path: "/home/dev/app",
        current_command: "claude",
        pane_title: "✳ Fix screen collapsing problem"
      }

      assert TC.pane_picker_label(pane, nil, "Agent: build") == "Agent: build"
    end

    test "preview title when a preview map is present" do
      assert TC.pane_picker_label(%{}, %{title: "My App"}, nil) == "My App"
    end

    test "defaults to 'Preview' when the preview has no usable title" do
      assert TC.pane_picker_label(%{}, %{title: "preview foo"}, nil) == "Preview"
    end
  end

  describe "pane_picker_detail/2" do
    test "shortened cwd when no preview" do
      pane = %{current_path: "/home/dev/app/lib"}
      assert TC.pane_picker_detail(pane, nil) == "app/lib"
    end

    test "preview url path when present" do
      assert TC.pane_picker_detail(%{}, %{display_url: "http://host/dashboard"}) == "/dashboard"
    end

    test "falls back to viewport when the url path is root" do
      preview = %{display_url: "http://host/", viewport: "mobile"}
      assert TC.pane_picker_detail(%{}, preview) == "mobile"
    end

    test "empty string when preview has no usable data" do
      assert TC.pane_picker_detail(%{}, %{}) == ""
    end
  end

  describe "pane_picker_title/2" do
    test "pane full title when no preview" do
      pane = %{current_path: "/x", current_command: "sh"}
      assert TC.pane_picker_title(pane, nil) == "/x · sh"
    end

    test "joins unique preview title/url/viewport parts" do
      preview = %{title: "App", display_url: "http://host/x", viewport: "800x600"}
      assert TC.pane_picker_title(%{}, preview) == "App · http://host/x · 800x600"
    end
  end

  describe "agent_label_title/1" do
    test "nil for nil" do
      assert TC.agent_label_title(nil) == nil
    end

    test "joins present source/tool/updated parts" do
      ts = ~U[2026-06-24 13:45:09Z]

      assert TC.agent_label_title(%{source: "cli", tool: "edit", updated_at: ts}) ==
               "source=cli · tool=edit · updated=13:45:09"
    end

    test "defaults when all parts are nil" do
      assert TC.agent_label_title(%{source: nil, tool: nil, updated_at: nil}) == "Agent label"
    end
  end

  # ── session helpers ────────────────────────────────────────────────────

  describe "session_attach_id/1" do
    test "shell sessions use the sid" do
      info = %SessionInfo{kind: :shell, sid: "u-alice-abc1234", id: "shell_w_u-alice-abc1234"}
      assert TC.session_attach_id(info) == "u-alice-abc1234"
    end

    test "non-shell sessions use the id" do
      info = %SessionInfo{kind: :agent, id: "agent_42"}
      assert TC.session_attach_id(info) == "agent_42"
    end
  end

  describe "session_kind_label/1" do
    test "known kinds" do
      assert TC.session_kind_label(:shell) == "Shell"
      assert TC.session_kind_label(:agent) == "Agent"
    end

    test "other atoms are capitalized" do
      assert TC.session_kind_label(:custom) == "Custom"
    end

    test "non-atoms stringify" do
      assert TC.session_kind_label("weird") == "weird"
    end
  end

  describe "session_tab_label/1" do
    test "shell uses alias when present" do
      info = %SessionInfo{kind: :shell, sid: "u-a-abc1234", metadata: %{session_alias: "Build"}}
      assert TC.session_tab_label(info) == "Build"
    end

    test "shell uses a context label derived from git_toplevel when no alias" do
      info = %SessionInfo{
        kind: :shell,
        sid: "u-a-abc1234",
        metadata: %{git_toplevel: "/home/dev/myrepo"}
      }

      assert TC.session_tab_label(info) == "myrepo"
    end

    test "shell defaults to 'workspace' with no alias or context" do
      info = %SessionInfo{kind: :shell, sid: "u-a-abc1234", metadata: %{}}
      assert TC.session_tab_label(info) == "workspace"
    end

    test "non-shell falls back to the kind label" do
      info = %SessionInfo{kind: :agent, metadata: %{}}
      assert TC.session_tab_label(info) == "Agent"
    end
  end

  describe "session_tab_detail/1" do
    test "shell joins branch/agent/identity, deduped" do
      info = %SessionInfo{
        kind: :shell,
        sid: "u-alice-abc1234",
        metadata: %{git_branch: "main", agent: "claude"}
      }

      # shell_sid_detail strips the "u-alice-" family prefix then shortens.
      assert TC.session_tab_detail(info) == "main · claude · abc1234"
    end

    test "non-shell uses runner identity" do
      info = %SessionInfo{kind: :agent, runner_id: "runner-xyz", metadata: %{}}
      assert TC.session_tab_detail(info) == "runner-xyz"
    end
  end

  describe "session_tab_title/1" do
    test "shell with a binary sid embeds it" do
      info = %SessionInfo{kind: :shell, sid: "u-a-abc1234", metadata: %{}}
      title = TC.session_tab_title(info)
      assert title =~ "Workspace shell u-a-abc1234"
    end

    test "shell without a sid uses the generic phrase" do
      info = %SessionInfo{kind: :shell, sid: nil, metadata: %{}}
      assert TC.session_tab_title(info) =~ "Workspace shell"
    end

    test "non-shell labels the session kind" do
      info = %SessionInfo{kind: :agent, metadata: %{}}
      assert TC.session_tab_title(info) =~ "Terminal session Agent"
    end

    test "appends cwd metadata when present" do
      info = %SessionInfo{kind: :shell, sid: "u-a-abc1234", metadata: %{cwd: "/home/dev/app"}}
      title = TC.session_tab_title(info)
      assert title =~ "app"
    end
  end

  describe "shorten/1" do
    test "nil becomes empty" do
      assert TC.shorten(nil) == ""
    end

    test "strings under the limit pass through" do
      assert TC.shorten("short") == "short"
    end

    test "long strings are truncated with an ellipsis" do
      assert TC.shorten("0123456789abcdefghij") == "0123456789abcde…"
    end
  end

  describe "shell_sid_detail/1" do
    test "strips the shell family prefix and shortens" do
      assert TC.shell_sid_detail("u-alice-abc1234") == "abc1234"
    end

    test "shortens the whole sid when there is no family match" do
      assert TC.shell_sid_detail("custom-shell") == "custom-shell"
    end

    test "non-binary becomes empty string" do
      assert TC.shell_sid_detail(nil) == ""
    end
  end

  describe "shell_button_detail/3" do
    test "delegates to shell_sid_detail on the default sid" do
      assert TC.shell_button_detail("u-alice-abc1234", "ignored", []) == "abc1234"
    end
  end

  describe "shell_button_label/4" do
    test "uses the active pane cwd when default == active sid" do
      panes = [%{active: true, current_path: "/home/dev/app/lib"}]
      assert TC.shell_button_label("sid", "sid", panes) == "app/lib"
    end

    test "uses the host path when the active cwd is unavailable" do
      assert TC.shell_button_label("sid", "other", [], "/home/dev/host/dir") == "host/dir"
    end

    test "defaults to 'workspace' when nothing resolves" do
      assert TC.shell_button_label("sid", "other", [], nil) == "workspace"
    end
  end

  describe "shell_tab_title/1" do
    test "embeds a non-empty sid" do
      assert TC.shell_tab_title("u-a-abc1234") == "Workspace shell u-a-abc1234"
    end

    test "generic phrase for blank/non-binary" do
      assert TC.shell_tab_title("") == "Workspace shell"
      assert TC.shell_tab_title(nil) == "Workspace shell"
    end
  end

  describe "terminal_session_label/2" do
    test "prefers the terminal sid detail when present" do
      assert TC.terminal_session_label("devide_w_x_alpha", "u-alice-abc1234") == "abc1234"
    end

    test "uses the tmux session id segment when no terminal sid" do
      # tmux_sid("devide_" <> rest): rest split on "_" must have >= 2 parts;
      # last segment is the sid, run through shell_sid_detail/shorten.
      assert TC.terminal_session_label("devide_work_alpha") == "alpha"
    end

    test "shortens the raw tmux session when it is not a devide_ session" do
      assert TC.terminal_session_label("plain-session") == "plain-session"
    end
  end
end
