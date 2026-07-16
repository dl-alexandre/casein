defmodule DevIdeWeb.WorkspaceLive.Show.SessionBarTest do
  use DevIDE.TestCase, async: true

  import Phoenix.LiveViewTest

  alias DevIDE.Terminals.Session.Info, as: SessionInfo
  alias DevIdeWeb.WorkspaceLive.Show.SessionBar
  alias DevIdeWeb.WorkspaceLive.Show.SessionBarVM
  alias DevIdeWeb.WorkspaceLive.Show.TerminalChrome

  defp agent_info(agent_id, tmux) do
    SessionInfo.new_agent(agent_id, workspace_id: "ws-1", loc: :local)
    |> Map.put(:tmux_session, tmux)
  end

  defp window(attrs) do
    Map.merge(
      %{
        id: "@1",
        index: 0,
        name: "shell",
        active: true,
        current_command: "bash",
        activity: 0,
        pane_list: []
      },
      attrs
    )
  end

  describe "window_tabs/1 agent_state" do
    defp agent_window(state, message) do
      window(%{pane_list: [pane(%{id: "%1", role: "agent", active: true, pane_title: ""})]})
      |> then(fn win ->
        reports = %{
          "%1" => %{
            state: state,
            message: message,
            source: :hook,
            tool: "terminal_report_agent_state",
            workspace_id: "ws-1",
            reported_at: DateTime.utc_now()
          }
        }

        SessionBarVM.window_tabs([win], nil, %{}, agent_reports: reports)
      end)
    end

    test "a blocked report drives a loud label and class" do
      [tab] = agent_window(:blocked, "needs permission")

      assert tab.agent_state == :blocked
      assert tab.agent_state_message == "needs permission"
      assert tab.activity_label == "Agent blocked: needs permission"
      assert tab.activity_class =~ "rose"
    end

    test "a done report reads calm" do
      [tab] = agent_window(:done, nil)

      assert tab.agent_state == :done
      assert tab.activity_label == "Agent done"
    end

    test "no report leaves agent_state nil and the heuristic in charge" do
      [tab] = SessionBarVM.window_tabs([window(%{})], nil, %{}, tmux_session: "tmux-none")
      assert tab.agent_state == nil
    end
  end

  describe "session_tabs/1" do
    test "styles the active tab from active_id without rebuilding tabs" do
      tabs = SessionBarVM.session_tabs([agent_info("ex-1", "tmux-ex-1")])

      html =
        render_component(&SessionBar.session_tabs/1,
          workspace_id: "ws-1",
          tabs: tabs,
          active_id: "agent_ex-1",
          shell_active?: false
        )

      assert html =~ ~s(id="active_sessions-agent_ex-1")
      assert active_tab?(html, "active_sessions-agent_ex-1")
      refute active_shell?(html)

      html =
        render_component(&SessionBar.session_tabs/1,
          workspace_id: "ws-1",
          tabs: tabs,
          active_id: "u-someone",
          shell_active?: true
        )

      refute active_tab?(html, "active_sessions-agent_ex-1")
      assert active_shell?(html)
    end

    test "renders kind label, detail, and attach payload attributes" do
      tabs = SessionBarVM.session_tabs([agent_info("ex-2", "tmux-ex-2")])

      html =
        render_component(&SessionBar.session_tabs/1,
          workspace_id: "ws-1",
          tabs: tabs,
          active_id: nil,
          shell_active?: true
        )

      assert html =~ "Agent"
      assert html =~ "1"
      assert html =~ ~s(phx-value-session-id="agent_ex-2")
      assert html =~ ~s(phx-value-kind="agent")
      assert html =~ ~s(phx-value-tmux-session="tmux-ex-2")
    end

    test "renders the fixed shell identity when provided" do
      html =
        render_component(&SessionBar.session_tabs/1,
          workspace_id: "ws-1",
          tabs: [],
          active_id: "u-alice-bbbb2222",
          shell_active?: true,
          shell_detail: "bbbb2222",
          shell_title: "Workspace shell u-alice-bbbb2222"
        )

      assert html =~ "bbbb2222"
      assert html =~ "workspace"
      assert html =~ ~s(title="Workspace shell u-alice-bbbb2222")
    end

    test "shell button label uses cwd and detail keeps sid suffix" do
      panes = [%{active: true, current_path: "/data/workspaces/dalexandre/dev_ide"}]

      assert TerminalChrome.shell_button_label("u-alice-aaaa1111", "u-alice-aaaa1111", panes) ==
               "dalexandre/dev_ide"

      assert TerminalChrome.shell_button_detail("u-alice-aaaa1111", "u-alice-aaaa1111", panes) ==
               "aaaa1111"
    end

    test "optimistically refreshes cwd-derived fields for a matching tmux session" do
      info =
        SessionInfo.new_shell("ws-1", "u-alice",
          metadata: %{cwd: "/data/workspaces/dalexandre/dev_ide"}
        )
        |> Map.put(:tmux_session, "devide_ws-1_u-alice")

      [tab] = SessionBarVM.session_tabs([info])

      assert tab.label == "dalexandre/dev_ide"
      assert tab.cwd == "/data/workspaces/dalexandre/dev_ide"

      assert [updated] =
               SessionBarVM.update_tmux_session_cwd(
                 [tab],
                 "devide_ws-1_u-alice",
                 "/data/workspaces/dalexandre/dev_ide/assets"
               )

      assert updated.label == "dev_ide/assets"
      assert updated.cwd == "/data/workspaces/dalexandre/dev_ide/assets"
      assert updated.title =~ "/data/workspaces/dalexandre/dev_ide/assets"
      refute updated.title =~ "/data/workspaces/dalexandre/dev_ide ·"
    end

    test "leaves unrelated tmux session tabs unchanged during cwd refresh" do
      [tab] = SessionBarVM.session_tabs([agent_info("ex-1", "tmux-ex-1")])

      assert SessionBarVM.update_tmux_session_cwd(
               [tab],
               "tmux-other",
               "/tmp/elsewhere"
             ) == [tab]
    end

    test "raw terminal session label avoids repeating the full tmux session" do
      assert TerminalChrome.terminal_session_label(
               "devide_dalexandre-integration_u-dalexandre-cj0e9ycd",
               "u-dalexandre-cj0e9ycd"
             ) == "cj0e9ycd"

      assert TerminalChrome.terminal_session_label(
               "devide_workspace_with_underscores_u-alice-abcd1234"
             ) == "abcd1234"
    end

    test "renders visible shell tabs with their tmux session suffixes" do
      tabs =
        SessionBarVM.session_tabs([
          SessionInfo.new_shell("ws-1", "u-alice-aaaa1111") |> Map.put(:tmux_session, "tmux-1"),
          SessionInfo.new_shell("ws-1", "u-alice-bbbb2222") |> Map.put(:tmux_session, "tmux-2")
        ])

      assert Enum.map(tabs, &{&1.label, &1.detail}) == [
               {"workspace", "aaaa1111"},
               {"workspace", "bbbb2222"}
             ]
    end

    test "renders visible shell tabs with cwd when available" do
      tabs =
        SessionBarVM.session_tabs([
          SessionInfo.new_shell("ws-1", "u-alice-aaaa1111",
            metadata: %{cwd: "/workspace/apps/web"}
          )
          |> Map.put(:tmux_session, "tmux-1")
        ])

      assert [%{label: "apps/web", detail: "aaaa1111", title: title}] = tabs
      assert title =~ "/workspace/apps/web"
    end

    test "renders git worktree context for shell tabs" do
      tabs =
        SessionBarVM.session_tabs([
          SessionInfo.new_shell("ws-1", "u-alice-aaaa1111",
            metadata: %{
              cwd: "/tmp/opencode/repo/apps/web",
              git_toplevel: "/tmp/opencode/repo",
              git_branch: "feature-test",
              agent: "opencode"
            }
          )
          |> Map.put(:tmux_session, "tmux-1")
        ])

      assert [
               %{
                 label: "repo/apps/web",
                 detail: "feature-test · opencode · aaaa1111",
                 title: title
               }
             ] = tabs

      assert title =~ "feature-test"
      assert title =~ "opencode"
    end

    test "renders other owned workspace sessions as navigation tabs" do
      workspace_tabs =
        SessionBarVM.workspace_session_tabs(
          [
            %{
              id: "ws-1",
              name: "alpha",
              path_label: "alice/alpha",
              sessions: [%{id: "u-alice", kind: :shell, href: "/workspaces/ws-1?session=u-alice"}]
            },
            %{
              id: "ws-2",
              name: "beta",
              path_label: "alice/beta",
              sessions: [
                %{
                  id: "u-alice-other",
                  kind: :shell,
                  href: "/workspaces/ws-2?session=u-alice-other",
                  metadata: %{
                    cwd: "/workspace/apps/web",
                    git_toplevel: "/workspace"
                  }
                }
              ]
            }
          ],
          "ws-1"
        )

      html =
        render_component(&SessionBar.session_tabs/1,
          workspace_id: "ws-1",
          tabs: [],
          workspace_tabs: workspace_tabs,
          active_id: nil,
          shell_active?: true
        )

      refute html =~ ~s(href="/workspaces/ws-1?session=u-alice")
      assert html =~ ~s(id="workspace_sessions-ws-2-u-alice-other")
      assert html =~ ~s(href="/workspaces/ws-2?session=u-alice-other")
      assert html =~ "apps/web"
      refute html =~ "alice/beta"
    end

    test "formats cross-workspace sessions like in-workspace shell tabs" do
      workspace_tabs =
        SessionBarVM.workspace_session_tabs(
          [
            %{
              id: "ws-devide",
              name: "dalexandre-devide",
              path_label: "dalexandre/dev_ide",
              sessions: [
                %{
                  id: "u-dalexandre-scxzocku",
                  kind: :shell,
                  href: "/workspaces/ws-devide?session=u-dalexandre-scxzocku",
                  metadata: %{
                    cwd: "/data/workspaces/dalexandre/dev_ide",
                    git_toplevel: "/data/workspaces/dalexandre/dev_ide",
                    git_branch: "master"
                  }
                }
              ]
            },
            %{
              id: "ws-integration",
              name: "dalexandre-integration",
              path_label: "ws/dalexandre-integration",
              sessions: [
                %{
                  id: "u-dalexandre-hn482jjc",
                  kind: :shell,
                  href: "/workspaces/ws-integration?session=u-dalexandre-hn482jjc",
                  metadata: %{
                    cwd: "/data/workspaces/dalexandre/dalexandre-integration",
                    git_toplevel: "/data/workspaces/dalexandre/dalexandre-integration",
                    git_branch: "main"
                  }
                }
              ]
            }
          ],
          "ws-current"
        )

      assert [
               %{
                 label: "dev_ide",
                 detail: "master · scxzocku",
                 window_count: 0
               },
               %{
                 label: "dalexandre-integration",
                 detail: "main · hn482jjc",
                 window_count: 0
               }
             ] = workspace_tabs
    end

    test "cross-workspace agent tab labels from its task title, not the worktree dir name" do
      [with_title, no_title, aliased] =
        SessionBarVM.workspace_session_tabs(
          [
            %{
              id: "ws-a",
              name: "agent-claude-adhoc-20260708033939",
              path_label: "agent-worktrees/agent-claude-adhoc-20260708033939",
              sessions: [
                %{
                  id: "sid-a",
                  kind: :agent,
                  agent_title: "Fix the session picker",
                  href: "/workspaces/ws-a?session=sid-a",
                  metadata: %{
                    cwd: "/wt/agent-claude-adhoc-20260708033939",
                    git_toplevel: "/wt/agent-claude-adhoc-20260708033939"
                  }
                }
              ]
            },
            %{
              id: "ws-b",
              name: "agent-grok-adhoc-20260708040155",
              path_label: "agent-worktrees/agent-grok-adhoc-20260708040155",
              sessions: [
                %{
                  id: "sid-b",
                  kind: :agent,
                  href: "/workspaces/ws-b?session=sid-b",
                  metadata: %{
                    cwd: "/wt/agent-grok-adhoc-20260708040155",
                    git_toplevel: "/wt/agent-grok-adhoc-20260708040155"
                  }
                }
              ]
            },
            %{
              id: "ws-c",
              name: "agent-codex-adhoc-20260708021144",
              path_label: "agent-worktrees/agent-codex-adhoc-20260708021144",
              sessions: [
                %{
                  id: "sid-c",
                  kind: :agent,
                  agent_title: "some activity",
                  href: "/workspaces/ws-c?session=sid-c",
                  metadata: %{
                    session_alias: "release-cut",
                    cwd: "/wt/agent-codex-adhoc-20260708021144"
                  }
                }
              ]
            }
          ],
          "ws-current"
        )

      # task title beats the flattened dir name
      assert with_title.label == "Fix the session picker"
      # no title → falls back to the context (dir) label, not crashing
      assert no_title.label == "agent-grok-adhoc-20260708040155"
      # an explicit alias always wins over the task title
      assert aliased.label == "release-cut"
    end

    test "preserves cross-workspace preview pane signifiers" do
      workspace_tabs =
        SessionBarVM.workspace_session_tabs(
          [
            %{
              id: "ws-preview",
              name: "preview-workspace",
              sessions: [
                %{
                  id: "u-alice-preview",
                  kind: :shell,
                  href: "/workspaces/ws-preview?session=u-alice-preview",
                  preview_pane_ids: ["%6"],
                  metadata: %{
                    cwd: "/workspace/preview",
                    windows: [
                      %{id: "@1", index: 1, name: "app", active: true},
                      %{id: "@0", index: 0, name: "shell", active: false}
                    ],
                    window_panes: %{"@1" => ["%5", "%6"], "@0" => ["%1"]}
                  }
                }
              ]
            }
          ],
          "ws-current"
        )

      assert [
               %{
                 preview_count: 1,
                 windows: [
                   %{id: "@0", preview_count: 0},
                   %{id: "@1", preview_count: 1}
                 ]
               }
             ] = workspace_tabs

      tree =
        SessionBarVM.workspace_session_tree(
          [
            %{
              id: "ws-preview",
              name: "preview-workspace",
              session_count: 1,
              live?: true,
              sessions: []
            }
          ],
          "ws-current",
          expanded_workspaces: MapSet.new(["ws-preview"]),
          current_session_tabs: [],
          sidebar_ws_sessions: %{"ws-preview" => workspace_tabs}
        )

      html =
        render_component(&SessionBar.sessions_sidebar/1,
          workspace_id: "ws-current",
          tree: tree,
          active_id: nil,
          preview_panes: %{"%6" => %{}}
        )

      assert html =~
               ~s(id="sidebar-session-preview-workspace_sessions-ws-preview-u-alice-preview")

      assert html =~ ~s(data-preview-running="true")
    end

    test "renders orphan tmux inventory tabs without navigation" do
      workspace_tabs =
        SessionBarVM.tmux_inventory_tabs([
          %{
            id: "tmux:devide_ws-adapter_sid-adapter",
            kind: :shell,
            label: "ws-adapter",
            detail: "sid-adapter",
            title: "devide_ws-adapter_sid-adapter"
          }
        ])

      html =
        render_component(&SessionBar.session_tabs/1,
          workspace_id: "ws-1",
          tabs: [],
          workspace_tabs: workspace_tabs,
          active_id: nil,
          shell_active?: true
        )

      refute html =~ ~s(href="#")
      assert html =~ "ws-adapter"
      assert html =~ "sid-adapter"
    end
  end

  describe "sessions_sidebar/1" do
    test "renders summoned workspace tree with expand toggle and active session row" do
      tabs =
        SessionBarVM.session_tabs([
          agent_info("ex-1", "tmux-ex-1"),
          agent_info("ex-2", "tmux-ex-2")
        ])

      tree =
        SessionBarVM.workspace_session_tree(
          [%{id: "ws-1", name: "alpha", session_count: 2, live?: true, sessions: []}],
          "ws-1",
          expanded_workspaces: MapSet.new(["ws-1"]),
          current_session_tabs: tabs,
          sidebar_ws_sessions: %{}
        )

      html =
        render_component(&SessionBar.sessions_sidebar/1,
          workspace_id: "ws-1",
          tree: tree,
          active_id: "agent_ex-1"
        )

      assert html =~ ~s(id="sessions-sidebar-ws-1")
      assert html =~ ~s(phx-hook="SessionsPickerSidebar")
      assert html =~ ~s(phx-click="sidebar:toggle_workspace")
      assert html =~ ~s(data-picker-active)
      assert html =~ "ex-1"
    end

    test "groups the tree into This workspace / Other workspaces with a live count" do
      tree =
        SessionBarVM.workspace_session_tree(
          [
            %{id: "ws-1", name: "alpha", session_count: 1, live?: true, sessions: []},
            %{id: "ws-2", name: "beta", session_count: 2, live?: false, sessions: []}
          ],
          "ws-1",
          expanded_workspaces: MapSet.new(),
          current_session_tabs: SessionBarVM.session_tabs([agent_info("ex-1", "tmux-ex-1")]),
          sidebar_ws_sessions: %{}
        )

      html =
        render_component(&SessionBar.sessions_sidebar/1,
          workspace_id: "ws-1",
          tree: tree,
          active_id: nil
        )

      # Section headers present when there are both current and other workspaces.
      assert html =~ "This workspace"
      assert html =~ "Other workspaces"
      # Header live/total badge: scratch + ws-1 live, ws-2 not => 2/3.
      assert html =~ "2/3 live"
      # The non-live "other" workspace row is dimmed.
      assert html =~ "opacity-60"
    end

    test "renders the scratch row with attach_terminal_session kind=scratch" do
      tabs = SessionBarVM.session_tabs([agent_info("ex-1", "tmux-ex-1")])

      tree =
        SessionBarVM.workspace_session_tree(
          [%{id: "ws-1", name: "alpha", session_count: 1, live?: true, sessions: []}],
          "ws-1",
          expanded_workspaces: MapSet.new(["ws-1"]),
          current_session_tabs: tabs,
          sidebar_ws_sessions: %{}
        )

      html =
        render_component(&SessionBar.sessions_sidebar/1,
          workspace_id: "ws-1",
          tree: tree,
          active_id: "agent_ex-1"
        )

      assert html =~ ~s(id="sidebar-session-scratch")
      assert html =~ "Scratch"
      assert html =~ ~s(phx-click="attach_terminal_session")
      assert html =~ ~s(phx-value-kind="scratch")
    end

    test "workspace-header row opens the home session; a separate chevron toggles" do
      # Current workspace, expanded, with two sessions: the last one is the
      # home/landing shell (default_sid).
      tabs =
        SessionBarVM.session_tabs([
          agent_info("ex-agent", "tmux-ex-agent"),
          agent_info("ex-shell", "tmux-ex-shell")
        ])

      home = List.last(tabs)

      tree =
        SessionBarVM.workspace_session_tree(
          [%{id: "ws-1", name: "alpha", session_count: 2, live?: true, sessions: []}],
          "ws-1",
          expanded_workspaces: MapSet.new(["ws-1"]),
          current_session_tabs: tabs,
          sidebar_ws_sessions: %{}
        )

      html =
        render_component(&SessionBar.sessions_sidebar/1,
          workspace_id: "ws-1",
          tree: tree,
          active_id: List.first(tabs).id,
          default_sid: home.id,
          session_tabs: tabs
        )

      # The workspace-header PRIMARY row is a picker item that attaches to the
      # home session — Enter/click opens a shell rather than merely toggling.
      [_, header] =
        Regex.run(~r/(<a\b[^>]*data-picker-section="workspaces"[^>]*>)/s, html)

      assert header =~ ~s(phx-click="attach_terminal_session")
      assert header =~ ~s(phx-value-session-id="#{home.id}")
      # The header row is NOT the expand toggle any more.
      refute header =~ ~s(phx-click="sidebar:toggle_workspace")

      # Expansion moved to a dedicated chevron button.
      assert html =~ ~s(id="sidebar-ws-toggle-)
      assert html =~ ~s(data-picker-ws-toggle)

      [_, chevron] =
        Regex.run(~r/(<button\b[^>]*data-picker-ws-toggle[^>]*>)/s, html)

      assert chevron =~ ~s(phx-click="sidebar:toggle_workspace")
      assert chevron =~ ~s(phx-value-workspace-id="ws-1")
    end

    test "renders the Browse tier with expand toggle and open-terminal action" do
      browse = [
        %{
          kind: :browse_root,
          id: "browse",
          dom_id: "sidebar-browse",
          label: "Browse",
          detail: "workspaces",
          title: "Browse directories",
          path: "/tmp/workspaces",
          rel: "",
          expanded?: true,
          children: [
            %{
              kind: :browse_dir,
              id: "browse:alice",
              dom_id: "sidebar-browse-alice",
              label: "alice",
              detail: "",
              title: "/tmp/workspaces/alice",
              path: "/tmp/workspaces/alice",
              rel: "alice",
              expanded?: false,
              children: nil,
              flat_session?: false,
              sessions: nil
            }
          ],
          flat_session?: false,
          sessions: nil
        }
      ]

      html =
        render_component(&SessionBar.sessions_sidebar/1,
          workspace_id: "ws-1",
          tree: browse,
          active_id: nil
        )

      assert html =~ ~s(id="sidebar-browse")
      assert html =~ "Browse"
      assert html =~ ~s(phx-click="sidebar:toggle_browse")
      assert html =~ ~s(data-browse-kind="browse_dir")
      assert html =~ "alice"
      assert html =~ ~s(phx-click="sidebar:open_folder")
      assert html =~ ~s(phx-value-path="/tmp/workspaces/alice")
    end
  end

  describe "sessions_sidebar/1 focus + quiet chrome" do
    test "groups flat single-session workspaces without replacing workspace tiers" do
      blocked =
        SessionBarVM.session_tabs([
          agent_info("blocked", "tmux-blocked")
          |> Map.put(:metadata, %{windows: [%{id: "@1", agent_state: :blocked}]})
        ])

      tree = [
        %{
          id: "ws-1",
          dom_id: "sidebar-ws-ws-1",
          workspace_id: "ws-1",
          label: "alpha",
          detail: "",
          title: "alpha",
          current?: true,
          live?: true,
          group: :this,
          session_count: 1,
          expanded?: false,
          flat_session?: true,
          session: blocked |> hd() |> Map.put(:workspace_id, "ws-1"),
          sessions: nil
        }
      ]

      html =
        render_component(&SessionBar.sessions_sidebar/1,
          workspace_id: "ws-1",
          tree: tree,
          active_id: "agent_blocked",
          session_tabs: blocked
        )

      assert html =~ "Needs you"
      assert html =~ ~s(data-picker-group="needs_you")
      assert html =~ ~s(id="active_sessions-agent_blocked")
    end

    test "groups existing picker rows into Needs You, Working, and Recent" do
      tabs =
        SessionBarVM.session_tabs([
          agent_info("blocked", "tmux-blocked")
          |> Map.put(:metadata, %{windows: [%{id: "@1", agent_state: :blocked}]}),
          agent_info("working", "tmux-working")
          |> Map.put(:metadata, %{windows: [%{id: "@2", agent_state: :working}]}),
          agent_info("shell", "tmux-shell")
        ])

      tree =
        SessionBarVM.workspace_session_tree(
          [%{id: "ws-1", name: "alpha", session_count: 3, live?: true, sessions: []}],
          "ws-1",
          expanded_workspaces: MapSet.new(["ws-1"]),
          current_session_tabs: tabs,
          sidebar_ws_sessions: %{}
        )

      html =
        render_component(&SessionBar.sessions_sidebar/1,
          workspace_id: "ws-1",
          tree: tree,
          active_id: "agent_blocked",
          default_sid: "agent_blocked",
          session_tabs: tabs
        )

      assert html =~ "Needs you"
      assert html =~ "Working"
      assert html =~ "Recent"
      assert html =~ ~s(data-picker-group="needs_you")
    end

    test "renders focus mode control and quiet badge from session tabs" do
      tabs =
        SessionBarVM.session_tabs([
          agent_info("ex-9", "tmux-ex-9")
          |> Map.put(:metadata, %{
            windows: [%{id: "@1", index: 1, name: "agent", active: false, quiet: true}]
          })
        ])

      tree =
        SessionBarVM.workspace_session_tree(
          [%{id: "ws-1", name: "alpha", session_count: 1, live?: true, sessions: []}],
          "ws-1",
          expanded_workspaces: MapSet.new(["ws-1"]),
          current_session_tabs: tabs,
          sidebar_ws_sessions: %{}
        )

      html =
        render_component(&SessionBar.sessions_sidebar/1,
          workspace_id: "ws-1",
          tree: tree,
          active_id: "agent_ex-9",
          default_sid: "agent_ex-9",
          session_tabs: tabs,
          chrome_visible?: true,
          mutations_allowed?: false
        )

      assert html =~ ~s(id="sessions-focus-mode-ws-1")
      assert html =~ ~s(phx-click="terminal:toggle_chrome")
      assert html =~ "Focus"
      assert html =~ ~s(id="session-quiet-badge-ws-1")
      assert html =~ ~s(data-leader-second-key="S")
      # Fixed-width rail with overflow clamp (no paint into the neighbor).
      assert html =~ "sessions-picker-sidebar"
      assert html =~ "w-64"
      assert html =~ "overflow-hidden"
      assert html =~ "bg-base-100"
      refute html =~ ~s(flex w-56 shrink-0)
    end
  end

  describe "session_header_indicator/1" do
    test "is a toggle button that opens the sessions rail" do
      tabs =
        SessionBarVM.session_tabs([
          agent_info("ex-9", "tmux-ex-9")
        ])

      html =
        render_component(&SessionBar.session_header_indicator/1,
          workspace_id: "ws-1",
          tabs: tabs,
          active_id: "agent_ex-9",
          active_fallback_label: "session",
          open?: false
        )

      assert html =~ ~s(id="session-header-indicator-ws-1")
      assert html =~ ~s(phx-click="sidebar:toggle_sessions")
      assert html =~ ~s(aria-expanded="false")

      open_html =
        render_component(&SessionBar.session_header_indicator/1,
          workspace_id: "ws-1",
          tabs: tabs,
          active_id: "agent_ex-9",
          open?: true
        )

      assert open_html =~ ~s(aria-expanded="true")
      assert open_html =~ "border-primary/50"
    end
  end

  describe "agent_mcp_url/2" do
    test "builds a terminal MCP URL pre-scoped to the workspace and tmux session" do
      url = SessionBar.agent_mcp_url("ws-1", "devide_ws-adapter_wt-abc123")

      assert url =~ "/api/terminals/mcp"
      assert url =~ "workspace_id=ws-1"
      assert url =~ "tmux_session=devide_ws-adapter_wt-abc123"
    end

    test "returns nil when there is no concrete tmux session to scope to" do
      assert SessionBar.agent_mcp_url("ws-1", nil) == nil
      assert SessionBar.agent_mcp_url("ws-1", "") == nil
      assert SessionBar.agent_mcp_url("", "devide_ws_wt-abc") == nil
    end
  end

  describe "copy_link_button/1" do
    test "carries the agent MCP link and a Ctrl/Cmd hint when an agent_url is given" do
      html =
        render_component(&SessionBar.copy_link_button/1,
          url: "https://host/workspaces/ws-1?session=wt-abc123",
          agent_url:
            "https://host/api/terminals/mcp?workspace_id=ws-1&tmux_session=devide_ws_wt-abc",
          label: "shell",
          kind: "session"
        )

      assert html =~ ~s(data-copy-session-link="https://host/workspaces/ws-1?session=wt-abc123")

      assert html =~
               ~s(data-copy-session-link-agent="https://host/api/terminals/mcp?workspace_id=ws-1&amp;tmux_session=devide_ws_wt-abc")

      assert html =~ "Ctrl/⌘-click copies the agent MCP link"
    end

    test "omits the agent attribute and hint when no agent_url is given" do
      html =
        render_component(&SessionBar.copy_link_button/1,
          url: "https://host/workspaces/ws-1?session=wt-abc123",
          label: "shell",
          kind: "session"
        )

      refute html =~ "data-copy-session-link-agent"
      refute html =~ "Ctrl/⌘-click"
      assert html =~ ~s(title="Copy link to shell")
    end
  end

  describe "window_sidebar/1" do
    test "renders a multi-pane window tree with pane select handlers" do
      windows =
        SessionBarVM.window_tabs(
          [
            window(%{
              pane_list: [
                pane(%{id: "%1", index: 0, active: true}),
                pane(%{id: "%2", index: 1, active: false})
              ]
            })
          ],
          "%1",
          %{}
        )

      tree =
        SessionBarVM.window_tree(windows, expanded_windows: MapSet.new(["@1"]))

      html =
        render_component(&SessionBar.window_sidebar/1,
          workspace_id: "ws-1",
          tree: tree,
          terminal_sid: "u-alice",
          topology_version: 3,
          mutations_allowed?: false,
          rename_window_id: nil
        )

      assert html =~ ~s(phx-hook="WindowPickerSidebar")
      assert html =~ ~s(phx-click="tmux:select_window")
      assert html =~ ~s(phx-click="tmux:select_pane")
      assert html =~ ~s(phx-value-pane-id="%1")
      assert html =~ ~s(phx-value-window-id="@1")
      assert html =~ ~s(phx-click="sidebar:toggle_window")
      assert html =~ ~s(data-picker-section="panes")
      assert html =~ ~s(data-picker-parent="sidebar-window--1")
    end

    test "single-pane windows stay flat without pane rows" do
      windows = SessionBarVM.window_tabs([window(%{pane_list: [pane("%1")]})], "%1", %{})

      tree = SessionBarVM.window_tree(windows, expanded_windows: MapSet.new(["@1"]))

      html =
        render_component(&SessionBar.window_sidebar/1,
          workspace_id: "ws-1",
          tree: tree,
          terminal_sid: "u-alice",
          mutations_allowed?: false
        )

      refute html =~ ~s(data-picker-section="panes")
      refute html =~ ~s(phx-click="sidebar:toggle_window")
    end
  end

  describe "window_tabs/1" do
    test "renders windows with activity state and hides mutation controls when not allowed" do
      windows =
        SessionBarVM.window_tabs([window(%{}), window(%{id: "@2", index: 1, active: false})])

      html =
        render_component(&SessionBar.window_tabs/1,
          workspace_id: "ws-1",
          windows: windows,
          topology_version: 7,
          mutations_allowed?: false,
          rename_window_id: nil
        )

      assert html =~ ~s(id="tmux-window--1")
      assert html =~ ~s(data-activity-state="idle")
      assert html =~ ~s(data-version="7")
      refute html =~ "tmux:new_window"
      refute html =~ "tmux:rename_start"
      refute html =~ "tmux:kill_window"
      # Refresh/templates moved to the header ⋯ menu — the strip is tabs only.
      refute html =~ "tmux:refresh_windows"
      refute html =~ "palette:templates"
      refute html =~ "tmux:open_template_library"
      # Tabs live inside the clipping scroll region driven by WindowTabStrip;
      # the active tab is marked so the hook can center it.
      assert html =~ ~s(phx-hook="WindowTabStrip")
      assert html =~ "data-tab-scroller"

      assert html =~
               ~s(class="tab-strip-scroller flex min-w-0 flex-1 items-center gap-1 overflow-x-auto")

      assert html =~ "data-active-window"
      assert html =~ ~s(data-tmux-window-index="0")
      assert html =~ ~s(data-tmux-window-index="1")
      refute html =~ ~s(target="_blank")
      # The drag-and-drop gate reads this as a string ("true"/"false"), so it
      # must render with an explicit value — a bare boolean attribute leaves
      # dataset.mutationsAllowed = "" and silently disables dragging.
      assert html =~ ~s(data-mutations-allowed="false")
    end

    test "drag-and-drop gate attribute renders an explicit string when allowed" do
      windows = SessionBarVM.window_tabs([window(%{})])

      html =
        render_component(&SessionBar.window_tabs/1,
          workspace_id: "ws-1",
          windows: windows,
          topology_version: 7,
          mutations_allowed?: true,
          rename_window_id: nil
        )

      assert html =~ ~s(data-mutations-allowed="true")
    end

    test "advertises leader second-keys: p/n on neighbours, digit on active, c on +" do
      windows =
        SessionBarVM.window_tabs([
          window(%{id: "@1", index: 0, name: "editor", active: false}),
          window(%{id: "@2", index: 1, name: "server", active: true}),
          window(%{id: "@3", index: 2, name: "logs", active: false})
        ])

      html =
        render_component(&SessionBar.window_tabs/1,
          workspace_id: "ws-1",
          windows: windows,
          topology_version: 1,
          mutations_allowed?: true,
          rename_window_id: nil
        )

      # Active is middle: left neighbour → p, right → n, active keeps its digit.
      assert html =~ ~s(data-window-leader-key="p")
      assert html =~ ~s(data-window-leader-key="n")
      assert html =~ ~s(data-window-leader-key="1")
      # Neighbours prefer n/p over their own digits.
      refute html =~ ~s(data-window-leader-key="0")
      refute html =~ ~s(data-window-leader-key="2")
      # New-window control uses the shared chrome second-key chip.
      assert html =~ ~s(data-leader-second-key="c")
    end

    test "renders preview marker on window tabs" do
      windows =
        SessionBarVM.window_tabs(
          [window(%{pane_list: [pane("%1"), pane("%2")]})],
          nil,
          %{"%2" => %{pane_id: "%2"}}
        )

      html =
        render_component(&SessionBar.window_tabs/1,
          workspace_id: "ws-1",
          windows: windows,
          topology_version: 7,
          mutations_allowed?: false,
          rename_window_id: nil
        )

      assert html =~ ~s(id="tmux-window-preview--1")
      assert html =~ ~s(data-preview-count="1")
    end

    test "shows mutation controls and the inline rename form when allowed" do
      windows =
        SessionBarVM.window_tabs([window(%{}), window(%{id: "@2", index: 1, active: false})])

      html =
        render_component(&SessionBar.window_tabs/1,
          workspace_id: "ws-1",
          windows: windows,
          mutations_allowed?: true,
          rename_window_id: "@1"
        )

      assert html =~ "tmux:new_window"
      assert html =~ ~s(id="tmux-rename-form--1")
      # The window being renamed loses its rename-start button; the other keeps it.
      assert html =~ "tmux:rename_start"
      assert html =~ "tmux:kill_window"
    end

    test "disables kill for the last remaining window" do
      one = SessionBarVM.window_tabs([window(%{})])

      html =
        render_component(&SessionBar.window_tabs/1,
          workspace_id: "ws-1",
          windows: one,
          mutations_allowed?: true,
          rename_window_id: nil
        )

      assert html =~ ~s(phx-click="tmux:kill_window")
      assert html =~ "disabled"
    end

    test "renders nothing when there are no windows" do
      html =
        render_component(&SessionBar.window_tabs/1,
          workspace_id: "ws-1",
          windows: [],
          mutations_allowed?: true,
          rename_window_id: nil
        )

      refute html =~ "tmux-window-tabs-ws-1"
    end
  end

  defp active_tab?(html, dom_id) do
    html |> element_class(dom_id) |> String.contains?("border-primary")
  end

  defp active_shell?(html) do
    html |> element_class("terminal-session-shell-ws-1") |> String.contains?("border-primary")
  end

  # Extracts the class attribute of the tag carrying the given DOM id
  # (attributes are rendered in source order, id before class).
  defp element_class(html, dom_id) do
    case Regex.run(~r/id="#{Regex.escape(dom_id)}"[^>]*class="([^"]*)"/s, html) do
      [_, class] -> class
      _ -> ""
    end
  end

  defp pane(id) when is_binary(id), do: pane(%{id: id})

  defp pane(attrs) when is_map(attrs) do
    id = Map.get(attrs, :id, "%1")

    %{
      id: id,
      active: Map.get(attrs, :active, id == "%1"),
      index: Map.get(attrs, :index, 0),
      left: 0,
      top: 0,
      width: 80,
      height: 24,
      current_path: Map.get(attrs, :current_path, "/workspace"),
      current_command: Map.get(attrs, :current_command, "bash")
    }
    |> Map.merge(attrs)
  end

  defp shell_tab(metadata) do
    SessionBarVM.session_tab(SessionInfo.new_shell("ws-1", "shell-aaaa1111", metadata: metadata))
  end

  describe "window_tabs/1 space efficiency" do
    test "omits the running command and keeps every tab compact" do
      one = SessionBarVM.window_tabs([window(%{current_command: "claude_exe"})])

      one_html =
        render_component(&SessionBar.window_tabs/1,
          workspace_id: "ws-1",
          windows: one,
          mutations_allowed?: false
        )

      refute one_html =~ "claude_exe", "the current command must not steal tab width"
      one_classes = one_html |> element_class("tmux-window--1") |> String.split()
      assert "min-w-24" in one_classes
      # The active tab caps wider (max-w-80) to hold its pinned window controls.
      assert "max-w-80" in one_classes
      assert "shrink-0" in one_classes
      refute "flex-1" in one_classes, "a lone window must not stretch across the strip"

      two =
        SessionBarVM.window_tabs([
          window(%{current_command: "claude_exe"}),
          window(%{id: "@2", index: 1, active: false})
        ])

      two_html =
        render_component(&SessionBar.window_tabs/1,
          workspace_id: "ws-1",
          windows: two,
          mutations_allowed?: false
        )

      # Active tab caps wider (max-w-80) for its pinned controls; the rest stay
      # compact at max-w-64. Neither stretches (no flex-1).
      for {dom_id, max_w} <- [{"tmux-window--1", "max-w-80"}, {"tmux-window--2", "max-w-64"}] do
        tab_classes = two_html |> element_class(dom_id) |> String.split()
        assert max_w in tab_classes
        assert "shrink-0" in tab_classes

        refute "flex-1" in tab_classes,
               "multiple windows must size to content, not split the row"
      end
    end
  end

  describe "session_anchor_chip/1" do
    test "worktree shows repo anchor + branch tail; full branch only in the title" do
      tab =
        shell_tab(%{
          cwd: "/wt/fx",
          git_toplevel: "/wt/fx",
          git_common_dir: "/home/dev_ide/.git",
          git_branch: "agent/grok/fix-nav",
          git_worktree?: true
        })

      html = render_component(&SessionBar.session_anchor_chip/1, tab: tab)

      assert html =~ "dev_ide⑂", "surfaces the parent repo a worktree cwd hides"
      assert html =~ ~s(max-w-32 truncate">fix-nav<), "visible text is the branch tail"
      assert html =~ "Worktree of dev_ide · branch agent/grok/fix-nav", "full branch in title"
    end

    test "non-default branch on a primary checkout shows the branch" do
      html =
        render_component(&SessionBar.session_anchor_chip/1,
          tab: shell_tab(%{cwd: "/r", git_toplevel: "/r", git_branch: "feature-x"})
        )

      assert html =~ "feature-x"
    end

    test "the default branch on a primary checkout renders nothing (noise-free)" do
      html =
        render_component(&SessionBar.session_anchor_chip/1,
          tab: shell_tab(%{cwd: "/r", git_toplevel: "/r", git_branch: "master"})
        )

      refute html =~ "master"
    end
  end

  describe "session_tab/1 branch/worktree fields" do
    test "derives branch, worktree parent repo, and a branch-free secondary detail" do
      tab =
        shell_tab(%{
          cwd: "/wt/fx",
          git_toplevel: "/wt/fx",
          git_common_dir: "/home/dev_ide/.git",
          git_branch: "feature-x",
          git_worktree?: true
        })

      assert tab.worktree?
      assert tab.repo == "dev_ide"
      assert tab.branch == "feature-x"
      assert tab.detail =~ "feature-x"
      refute tab.detail_secondary =~ "feature-x"
    end
  end
end
