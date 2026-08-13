defmodule CaseinWeb.WorkspaceLive.Show.SessionBarVMTest do
  use ExUnit.Case, async: true

  alias Casein.Labels
  alias Casein.Terminals.Session.Info, as: SessionInfo
  alias Casein.Workspaces.Scratch
  alias CaseinWeb.WorkspaceLive.Show.SessionBarVM

  defp shell_info(sid) do
    SessionInfo.new_shell("ws-a", sid, metadata: %{})
  end

  defp workspace_nodes(tree), do: Enum.reject(tree, &Scratch.scratch?(&1.workspace_id))

  describe "workspace_session_tree/4 ownership grouping" do
    test "groups nodes as :this / :mine / :other by workspace owner" do
      summaries = [
        %{id: "ws-a", name: "alpha", user: "dalexandre", session_count: 1, live?: true},
        %{id: "ws-mine", name: "mine", user: "dalexandre", session_count: 1, live?: true},
        %{id: "ws-theirs", name: "theirs", user: "zoe", session_count: 1, live?: true},
        %{id: "ws-unowned", name: "unowned", session_count: 1, live?: true}
      ]

      groups =
        summaries
        |> SessionBarVM.workspace_session_tree("ws-a",
          expanded_workspaces: MapSet.new(),
          current_session_tabs: [],
          sidebar_ws_sessions: %{},
          viewer: %{email: "dalexandre@milcgroup.com"}
        )
        |> workspace_nodes()
        |> Map.new(&{&1.workspace_id, &1.group})

      assert groups == %{
               "ws-a" => :this,
               "ws-mine" => :mine,
               "ws-theirs" => :other,
               "ws-unowned" => :other
             }
    end

    test "without a viewer identity every non-current node stays :other" do
      summaries = [
        %{id: "ws-a", name: "alpha", user: "dalexandre", session_count: 1, live?: true},
        %{id: "ws-b", name: "beta", user: "dalexandre", session_count: 1, live?: true}
      ]

      groups =
        summaries
        |> SessionBarVM.workspace_session_tree("ws-a",
          expanded_workspaces: MapSet.new(),
          current_session_tabs: [],
          sidebar_ws_sessions: %{}
        )
        |> workspace_nodes()
        |> Map.new(&{&1.workspace_id, &1.group})

      assert groups == %{"ws-a" => :this, "ws-b" => :other}
    end
  end

  describe "workspace_session_tree/4" do
    test "prepends a scratch flat-session node at the top of the tree" do
      summaries = [
        %{id: "ws-a", name: "alpha", session_count: 1, live?: true, sessions: []}
      ]

      tabs = SessionBarVM.session_tabs([shell_info("shell-1")])

      tree =
        SessionBarVM.workspace_session_tree(summaries, "ws-a",
          expanded_workspaces: MapSet.new(["ws-a"]),
          current_session_tabs: tabs,
          sidebar_ws_sessions: %{}
        )

      assert [%{workspace_id: "__scratch__", flat_session?: true, session: session} | rest] = tree
      assert session.kind == :scratch
      assert session.workspace_id == Scratch.id()
      assert session.label == "Scratch"
      assert session.href =~ "/workspaces/__scratch__"
      assert Enum.any?(rest, &(&1.workspace_id == "ws-a"))
    end

    test "does not prepend scratch when the current workspace is already scratch" do
      summaries = [
        %{id: "__scratch__", name: "__scratch__", session_count: 1, live?: true, sessions: []}
      ]

      tabs = SessionBarVM.session_tabs([shell_info("home-shell")])

      tree =
        SessionBarVM.workspace_session_tree(summaries, "__scratch__",
          expanded_workspaces: MapSet.new(["__scratch__"]),
          current_session_tabs: tabs,
          sidebar_ws_sessions: %{}
        )

      assert Enum.count(tree, &Scratch.scratch?(&1.workspace_id)) == 1

      assert [%{workspace_id: "__scratch__", flat_session?: true, session: %{id: "home-shell"}}] =
               tree
    end

    test "orders current workspace first and keeps collapsed rows session-free" do
      summaries = [
        %{id: "ws-b", name: "beta", session_count: 2, live?: true, sessions: [%{id: "s1"}]},
        %{id: "ws-a", name: "alpha", session_count: 1, live?: true, sessions: [%{id: "s0"}]}
      ]

      current_tabs = SessionBarVM.session_tabs([shell_info("shell-1")])

      tree =
        SessionBarVM.workspace_session_tree(summaries, "ws-a",
          expanded_workspaces: MapSet.new(),
          current_session_tabs: current_tabs,
          sidebar_ws_sessions: %{}
        )

      assert [%{workspace_id: "ws-a", flat_session?: true}, %{workspace_id: "ws-b"}] =
               workspace_nodes(tree)

      assert Enum.all?(workspace_nodes(tree), &(&1.sessions == nil))
      refute Enum.all?(workspace_nodes(tree), &(&1.flat_session? == false))
    end

    test "expands current workspace with live session tabs" do
      summaries = [
        %{id: "ws-a", name: "alpha", session_count: 2, live?: true, sessions: []}
      ]

      tabs = SessionBarVM.session_tabs([shell_info("shell-1"), shell_info("shell-2")])

      [node] =
        workspace_nodes(
          SessionBarVM.workspace_session_tree(summaries, "ws-a",
            expanded_workspaces: MapSet.new(["ws-a"]),
            current_session_tabs: tabs,
            sidebar_ws_sessions: %{}
          )
        )

      assert node.expanded?
      refute node.flat_session?
      assert length(node.sessions) == 2
      assert Enum.all?(node.sessions, &(&1.workspace_id == "ws-a"))
    end

    test "collapses a single-session workspace to one flat row" do
      summaries = [
        %{id: "ws-a", name: "alpha", session_count: 1, live?: true, sessions: []}
      ]

      tabs = SessionBarVM.session_tabs([shell_info("only")])

      [node] =
        workspace_nodes(
          SessionBarVM.workspace_session_tree(summaries, "ws-a",
            expanded_workspaces: MapSet.new(["ws-a"]),
            current_session_tabs: tabs,
            sidebar_ws_sessions: %{}
          )
        )

      assert node.flat_session?
      refute node.expanded?
      assert %{id: "only"} = node.session
      assert node.sessions == nil
    end

    test "uses lazily loaded sidebar sessions for other workspaces" do
      summaries = [
        %{id: "ws-a", name: "alpha", session_count: 1, live?: true, sessions: []},
        %{id: "ws-b", name: "beta", session_count: 1, live?: true, sessions: []}
      ]

      other_tabs = SessionBarVM.session_tabs([shell_info("remote-shell")])

      tree =
        SessionBarVM.workspace_session_tree(summaries, "ws-a",
          expanded_workspaces: MapSet.new(["ws-b"]),
          current_session_tabs: [],
          sidebar_ws_sessions: %{"ws-b" => other_tabs}
        )

      other = Enum.find(tree, &(&1.workspace_id == "ws-b"))
      assert other.flat_session?
      assert other.session.id == "remote-shell"
    end

    test "a single-session other workspace becomes a direct one-click nav row" do
      summaries = [
        %{id: "ws-a", name: "alpha", session_count: 1, live?: true, sessions: []},
        %{
          id: "ws-b",
          name: "beta",
          session_count: 1,
          live?: true,
          sessions: [%{id: "s0", href: "/workspaces/ws-b?session=s0"}]
        }
      ]

      tree =
        SessionBarVM.workspace_session_tree(summaries, "ws-a",
          expanded_workspaces: MapSet.new(),
          current_session_tabs: [],
          sidebar_ws_sessions: %{}
        )

      other = Enum.find(tree, &(&1.workspace_id == "ws-b"))
      # Row keeps its workspace label but navigates straight into the lone
      # session — no expand gesture, no async round-trip, no dead-end.
      assert other.nav_href == "/workspaces/ws-b?session=s0"
      assert other.sessions == nil
      refute other.flat_session?
      refute other.expanded?
    end

    test "expanding a multi-session workspace paints summary sessions before the async lands" do
      summaries = [
        %{id: "ws-a", name: "alpha", session_count: 1, live?: true, sessions: []},
        %{
          id: "ws-b",
          name: "beta",
          session_count: 2,
          live?: true,
          sessions: [
            %{id: "s0", href: "/workspaces/ws-b?session=s0"},
            %{id: "s1", href: "/workspaces/ws-b?session=s1"}
          ]
        }
      ]

      tree =
        SessionBarVM.workspace_session_tree(summaries, "ws-a",
          expanded_workspaces: MapSet.new(["ws-b"]),
          current_session_tabs: [],
          # async cache still empty — summary is the instant-paint source
          sidebar_ws_sessions: %{}
        )

      other = Enum.find(tree, &(&1.workspace_id == "ws-b"))
      assert other.expanded?
      assert length(other.sessions) == 2
      # Sessions are present, so no spinner even though the async is pending.
      refute other.loading?
    end

    test "an expanded workspace with nothing to show yet is loading, not silently empty" do
      summaries = [
        %{id: "ws-a", name: "alpha", session_count: 1, live?: true, sessions: []},
        %{id: "ws-b", name: "beta", session_count: 3, live?: true, sessions: []}
      ]

      tree =
        SessionBarVM.workspace_session_tree(summaries, "ws-a",
          expanded_workspaces: MapSet.new(["ws-b"]),
          current_session_tabs: [],
          sidebar_ws_sessions: %{}
        )

      other = Enum.find(tree, &(&1.workspace_id == "ws-b"))
      assert other.sessions == []
      assert other.loading?
    end

    test "an expanded workspace whose async read returned empty shows an empty state" do
      summaries = [
        %{id: "ws-a", name: "alpha", session_count: 1, live?: true, sessions: []},
        %{id: "ws-b", name: "beta", session_count: 3, live?: true, sessions: []}
      ]

      tree =
        SessionBarVM.workspace_session_tree(summaries, "ws-a",
          expanded_workspaces: MapSet.new(["ws-b"]),
          current_session_tabs: [],
          # async completed with an empty list (stale worktree, no live sessions)
          sidebar_ws_sessions: %{"ws-b" => []}
        )

      other = Enum.find(tree, &(&1.workspace_id == "ws-b"))
      assert other.sessions == []
      # Done loading → the row renders "No live sessions", not a perpetual gap.
      refute other.loading?
      assert other.sessions_error == nil
    end

    test "an expanded workspace whose async read failed is error, not empty" do
      summaries = [
        %{id: "ws-a", name: "alpha", session_count: 1, live?: true, sessions: []},
        %{id: "ws-b", name: "beta", session_count: 3, live?: true, sessions: []}
      ]

      tree =
        SessionBarVM.workspace_session_tree(summaries, "ws-a",
          expanded_workspaces: MapSet.new(["ws-b"]),
          current_session_tabs: [],
          sidebar_ws_sessions: %{"ws-b" => {:error, :timeout}}
        )

      other = Enum.find(tree, &(&1.workspace_id == "ws-b"))
      assert other.sessions == []
      refute other.loading?
      assert is_binary(other.sessions_error)
      assert other.sessions_error =~ "Could not load sessions"
    end

    test "tags the current workspace (and scratch) :this and the rest :other" do
      summaries = [
        %{id: "ws-a", name: "alpha", session_count: 1, live?: true, sessions: []},
        %{id: "ws-b", name: "beta", session_count: 1, live?: true, sessions: []}
      ]

      tree =
        SessionBarVM.workspace_session_tree(summaries, "ws-a",
          expanded_workspaces: MapSet.new(),
          current_session_tabs: [],
          sidebar_ws_sessions: %{}
        )

      by_id = Map.new(tree, &{&1.workspace_id, &1.group})

      assert by_id["__scratch__"] == :this
      assert by_id["ws-a"] == :this
      assert by_id["ws-b"] == :other
    end
  end

  describe "tree_liveness_summary/1" do
    test "counts live workspace-tier nodes and ignores the Browse tier" do
      summaries = [
        %{id: "ws-a", name: "alpha", session_count: 1, live?: true, sessions: []},
        %{id: "ws-b", name: "beta", session_count: 1, live?: false, sessions: []}
      ]

      tree =
        SessionBarVM.workspace_session_tree(summaries, "ws-a",
          expanded_workspaces: MapSet.new(),
          current_session_tabs: [],
          sidebar_ws_sessions: %{}
        )

      # scratch (live) + ws-a (live) + ws-b (not live) = 3 total, 2 live
      assert %{live: 2, total: 3} = SessionBarVM.tree_liveness_summary(tree)

      # Browse-tier nodes must not inflate the counts.
      browse = [%{kind: :browse_root, live?: true}, %{kind: :browse_dir, live?: true}]
      assert %{live: 2, total: 3} = SessionBarVM.tree_liveness_summary(tree ++ browse)
    end
  end

  describe "scratch_tab/0 and scratch_tree_node/1" do
    test "scratch_tab builds a kind=:scratch workspace tab" do
      tab = SessionBarVM.scratch_tab()

      assert tab.kind == :scratch
      assert tab.id == Scratch.id()
      assert tab.workspace_id == Scratch.id()
      assert tab.dom_id == "sidebar-session-scratch"
      assert is_binary(tab.href)
    end

    test "scratch_tree_node is a flat_session row wrapping scratch_tab" do
      node = SessionBarVM.scratch_tree_node(current?: true)

      assert node.flat_session?
      assert node.current?
      assert node.workspace_id == Scratch.id()
      assert node.session.kind == :scratch
      assert node.sessions == nil
    end
  end

  describe "window_tree/2" do
    defp pane(id, attrs \\ []) do
      Map.merge(
        %{
          id: id,
          dom_frag: String.trim_leading(id, "%"),
          index: 0,
          label: "pane",
          detail: "",
          title: id,
          active?: false,
          preview?: false,
          activity_state: :idle,
          activity_class: "",
          activity_label: ""
        },
        Map.new(attrs)
      )
    end

    defp window_tab(attrs) when is_map(attrs) do
      panes = Map.get(attrs, :panes, [])

      base = %{
        id: "@1",
        dom_frag: "1",
        index: 0,
        name: "main",
        display_name: "main",
        active?: true,
        attention: "none",
        activity_state: :idle,
        activity_class: "",
        activity_label: "",
        command: nil,
        full_title: "main",
        panes: panes,
        pane_count: length(panes)
      }

      Map.merge(base, Map.drop(attrs, [:panes]))
    end

    test "keeps single-pane windows flat with no pane children" do
      [node] =
        SessionBarVM.window_tree(
          [window_tab(%{panes: [pane("%1")]})],
          expanded_windows: MapSet.new(["@1"])
        )

      assert node.flat_window?
      refute node.expanded?
      assert node.pane.id == "%1"
      assert node.panes == nil
    end

    test "expands multi-pane windows when listed in expanded_windows" do
      panes = [pane("%1"), pane("%2", index: 1)]

      [node] =
        SessionBarVM.window_tree(
          [window_tab(%{panes: panes, pane_count: 2})],
          expanded_windows: MapSet.new(["@1"])
        )

      refute node.flat_window?
      assert node.expanded?
      assert length(node.panes) == 2
      assert node.pane == nil
    end

    test "collapses multi-pane windows when not expanded but keeps panes in tree data" do
      panes = [pane("%1"), pane("%2", index: 1)]

      [node] =
        SessionBarVM.window_tree(
          [window_tab(%{panes: panes, pane_count: 2})],
          expanded_windows: MapSet.new()
        )

      refute node.flat_window?
      refute node.expanded?
      assert length(node.panes) == 2
      assert node.pane_count == 2
    end
  end

  describe "sidebar sort helpers" do
    test "cycle_sort_mode rotates recency → name → liveness" do
      assert SessionBarVM.cycle_sort_mode(:recency) == :name
      assert SessionBarVM.cycle_sort_mode(:name) == :liveness
      assert SessionBarVM.cycle_sort_mode(:liveness) == :recency
    end

    test "cycle_sort_mode/2 :forward matches the arity-1 default" do
      for mode <- [:recency, :name, :liveness] do
        assert SessionBarVM.cycle_sort_mode(mode, :forward) == SessionBarVM.cycle_sort_mode(mode)
      end
    end

    test "cycle_sort_mode/2 :backward reverses the rotation" do
      assert SessionBarVM.cycle_sort_mode(:name, :backward) == :recency
      assert SessionBarVM.cycle_sort_mode(:liveness, :backward) == :name
      assert SessionBarVM.cycle_sort_mode(:recency, :backward) == :liveness
    end

    test "cycle_sort_mode/2 backward then forward round-trips every mode" do
      for mode <- [:recency, :name, :liveness] do
        assert mode
               |> SessionBarVM.cycle_sort_mode(:backward)
               |> SessionBarVM.cycle_sort_mode(:forward) == mode
      end
    end

    test "sort_workspace_summaries_for_sidebar pins current workspace first" do
      summaries = [
        %{id: "ws-b", name: "beta", session_count: 1, live?: false},
        %{id: "ws-a", name: "alpha", session_count: 1, live?: true}
      ]

      sorted =
        SessionBarVM.sort_workspace_summaries_for_sidebar(summaries, :name, "ws-b")

      assert [%{id: "ws-b"}, %{id: "ws-a"}] = sorted
    end

    test "sort_workspace_summaries_for_sidebar puts the viewer's own workspaces before others" do
      summaries = [
        %{id: "ws-cur", name: "current", user: "dalexandre"},
        %{id: "ws-zoe", name: "aaa-theirs", user: "zoe"},
        %{id: "ws-mine", name: "zzz-mine", user: "dalexandre"},
        %{id: "ws-none", name: "mmm-unowned"}
      ]

      viewer = %{email: "dalexandre@milcgroup.com"}

      sorted =
        SessionBarVM.sort_workspace_summaries_for_sidebar(summaries, :name, "ws-cur", viewer)

      # Current pinned, then mine, then everyone else's (each sorted by name).
      assert ["ws-cur", "ws-mine", "ws-zoe", "ws-none"] == Enum.map(sorted, & &1.id)
    end

    test "partition_viewer_workspaces claims unowned workspaces under the viewer's path" do
      Casein.ProcessEnv.put(:workspaces_root, "/data/workspaces")
      on_exit(fn -> Casein.ProcessEnv.delete(:workspaces_root) end)

      summaries = [
        %{id: "ws-home", name: "dev_ide", path: "/data/workspaces/dalexandre/dev_ide"},
        %{id: "ws-slug", name: "audit", path: "/data/workspaces/dalexandre-audit"},
        %{id: "ws-theirs", name: "parity", path: "/data/workspaces/sconde-facility-parity"},
        %{id: "ws-lookalike", name: "other", path: "/data/workspaces/dalexandrew-test"},
        %{id: "ws-outside", name: "elsewhere", path: "/opt/casein/deploy-build"}
      ]

      {mine, others} =
        SessionBarVM.partition_viewer_workspaces(summaries, %{email: "dalexandre@milcgroup.com"})

      assert Enum.map(mine, & &1.id) == ["ws-home", "ws-slug"]
      assert Enum.map(others, & &1.id) == ["ws-theirs", "ws-lookalike", "ws-outside"]
    end

    test "sort_workspace_summaries_for_sidebar leaves order untouched with no viewer identity" do
      summaries = [
        %{id: "ws-cur", name: "current", user: "dalexandre"},
        %{id: "ws-b", name: "beta", user: "zoe"},
        %{id: "ws-a", name: "alpha", user: "dalexandre"}
      ]

      with_viewer =
        SessionBarVM.sort_workspace_summaries_for_sidebar(summaries, :name, "ws-cur", nil)

      assert ["ws-cur", "ws-a", "ws-b"] == Enum.map(with_viewer, & &1.id)
    end

    test "partition_viewer_workspaces matches the email local-part and is case-insensitive" do
      summaries = [
        %{id: "ws-mine", user: "DAlexandre"},
        %{id: "ws-theirs", user: "zoe"},
        %{id: "ws-unowned", user: ""}
      ]

      {mine, others} =
        SessionBarVM.partition_viewer_workspaces(summaries, %{
          email: "dalexandre@milcgroup.com"
        })

      assert Enum.map(mine, & &1.id) == ["ws-mine"]
      assert Enum.map(others, & &1.id) == ["ws-theirs", "ws-unowned"]
    end

    test "partition_viewer_workspaces treats everything as unowned without viewer identity" do
      summaries = [%{id: "ws-a", user: "dalexandre"}]
      assert {[], ^summaries} = SessionBarVM.partition_viewer_workspaces(summaries, nil)
    end

    test "sort_session_tabs orders by name and liveness" do
      tabs = [
        %{label: "zebra", activity_state: :idle},
        %{label: "alpha", activity_state: :fresh}
      ]

      assert [%{label: "alpha"}, %{label: "zebra"}] =
               SessionBarVM.sort_session_tabs(tabs, :name)

      assert [%{label: "alpha"}, %{label: "zebra"}] =
               SessionBarVM.sort_session_tabs(tabs, :liveness)
    end

    test "sort_window_tree puts active window first in liveness mode" do
      nodes = [
        %{display_name: "idle", name: "idle", active?: false, activity_state: :idle, index: 0},
        %{display_name: "active", name: "active", active?: true, activity_state: :fresh, index: 1}
      ]

      assert [%{active?: true}, %{active?: false}] =
               SessionBarVM.sort_window_tree(nodes, :liveness)
    end
  end

  describe "window_tabs/4 cockpit liveness" do
    test "cached session liveness reaches the tab so FleetBoard can classify" do
      # The cockpit never attaches :liveness to panes — only the MCP topology
      # path does. Without this fallback FleetBoard sees no liveness at all and
      # every hook-less pane buckets :unknown, which is #917 unreachable from
      # the UI it was written for.
      [tab] =
        SessionBarVM.window_tabs(
          [
            %{
              id: "@9",
              index: 0,
              name: "worker-oc",
              active: true,
              current_command: "opencode",
              pane_list: [
                %{
                  id: "%42",
                  index: 0,
                  role: "agent",
                  active: true,
                  current_command: "opencode",
                  current_path: "/wt/oc"
                }
              ]
            }
          ],
          nil,
          %{},
          pane_liveness: %{
            "%42" => %{
              liveness: %{state: :active, quiet_for_seconds: 4},
              worktree_path: "/wt/oc/toplevel"
            }
          }
        )

      assert tab.liveness.state == :active
      assert tab.liveness.quiet_for_seconds == 4
      # The cached worktree root wins over the raw pane cwd, so two panes in
      # sibling subdirs of one worktree share a branch-join key.
      assert tab.worktree_path == "/wt/oc/toplevel"
    end

    test "a pane the cache could not observe keeps its reason on the tab" do
      [tab] =
        SessionBarVM.window_tabs(
          [
            %{
              id: "@9",
              index: 0,
              name: "worker-oc",
              active: true,
              current_command: "opencode",
              pane_list: [
                %{
                  id: "%42",
                  index: 0,
                  role: "agent",
                  active: true,
                  current_command: "opencode",
                  current_path: "/wt/oc"
                }
              ]
            }
          ],
          nil,
          %{},
          pane_liveness: %{
            "%42" => %{liveness: %{state: :unknown, reason: :enoent}, worktree_path: nil}
          }
        )

      assert tab.liveness.state == :unknown
      assert tab.liveness.reason == :enoent
      # Falls back to the pane cwd when the cache had no worktree root.
      assert tab.worktree_path == "/wt/oc"
    end
  end

  describe "window_tabs/4 worktree join key" do
    test "falls back to the pane cwd, which is all a cockpit pane carries" do
      # Cockpit topology panes have :current_path and no :worktree_path — that
      # enriched field only exists on the MCP path. Without this fallback the
      # PR-branch ticket join has a nil key and every PR row degrades to
      # capacity in the real drawer while unit tests still pass.
      [tab] =
        SessionBarVM.window_tabs([
          %{
            id: "@5",
            index: 0,
            name: "worker-s2",
            active: true,
            current_command: "opencode",
            pane_list: [
              %{
                id: "%93",
                index: 0,
                role: "agent",
                active: true,
                current_command: "opencode",
                current_path: "/data/casein-agent-worktrees/agent-opencode-s2"
              }
            ]
          }
        ])

      assert tab.worktree_path == "/data/casein-agent-worktrees/agent-opencode-s2"
    end

    test "prefers an enriched worktree_path when the MCP path supplied one" do
      [tab] =
        SessionBarVM.window_tabs([
          %{
            id: "@6",
            index: 0,
            name: "worker-b",
            active: true,
            current_command: "claude",
            pane_list: [
              %{
                id: "%94",
                index: 0,
                role: "agent",
                active: true,
                current_command: "claude",
                worktree_path: "/wt/enriched",
                current_path: "/wt/enriched/sub/dir"
              }
            ]
          }
        ])

      assert tab.worktree_path == "/wt/enriched"
    end
  end

  describe "window_tabs/4 labels" do
    test "replaces UUID-shaped agent titles with the running command" do
      [tab] =
        SessionBarVM.window_tabs([
          %{
            id: "@1",
            index: 0,
            name: "019f9c65-25cc-7353-b7a0-ffe0d65e7952",
            manual_name: true,
            active: true,
            current_command: "codex",
            pane_list: []
          }
        ])

      assert tab.display_name == "Codex"
    end

    test "uses each agent pane's conversation label instead of its node process name" do
      session = "casein_alpha_u-dev"

      labels = %{
        Labels.key(session, "%2") => %{
          label: "Fix workspace deletion flow",
          source: :agent,
          frozen?: false,
          tool: "terminal_send_agent_command",
          updated_at: ~U[2026-07-27 18:00:00Z]
        }
      }

      [tab] =
        SessionBarVM.window_tabs(
          [
            %{
              id: "@2",
              index: 1,
              name: "node",
              active: true,
              current_command: "node",
              pane_list: [
                %{
                  id: "%2",
                  index: 0,
                  role: "agent",
                  active: true,
                  current_command: "node",
                  current_path: "/workspace",
                  pane_title: ""
                }
              ]
            }
          ],
          nil,
          %{},
          tmux_session: session,
          pane_labels: labels
        )

      assert tab.display_name == "Fix workspace deletion flow"
    end

    test "uses a persisted Codex conversation title instead of its node process name" do
      codex_id = "019f9cae-1033-7a22-8c54-7ff3a0f2f92c"

      [tab] =
        SessionBarVM.window_tabs(
          [
            %{
              id: "@3",
              index: 2,
              name: "node",
              active: true,
              current_command: "node",
              pane_list: [
                %{
                  id: "%3",
                  index: 0,
                  role: "agent",
                  active: true,
                  current_command: "node",
                  current_path: "/workspace",
                  pane_title: codex_id
                }
              ]
            }
          ],
          nil,
          %{},
          codex_titles: %{codex_id => "Connect Anthropic remote MCP"}
        )

      assert tab.display_name == "Connect Anthropic remote MCP"
    end
  end

  describe "session_tab attention classification" do
    defp shell_info_with_windows(sid, windows) do
      SessionInfo.new_shell("ws-a", sid, metadata: %{windows: windows})
    end

    test "blocked agent window classifies :needs_you/:blocked with a count" do
      [tab] =
        SessionBarVM.session_tabs([
          shell_info_with_windows("blocked", [
            %{id: "@1", index: 0, name: "agent", agent_state: :blocked},
            %{id: "@2", index: 1, name: "agent2", agent_state: :blocked},
            %{id: "@3", index: 2, name: "shell"}
          ])
        ])

      assert tab.attention_section == :needs_you
      assert tab.attention_reason == :blocked
      assert tab.agent_blocked_count == 2
    end

    test "done agent window classifies :needs_you/:completed" do
      [tab] =
        SessionBarVM.session_tabs([
          shell_info_with_windows("done", [
            %{id: "@1", index: 0, name: "agent", agent_state: :done}
          ])
        ])

      assert tab.attention_section == :needs_you
      assert tab.attention_reason == :completed
      assert tab.agent_blocked_count == 0
    end

    test "quiet window reaches :needs_you despite the tab's quiet? key shape" do
      # Attention.classify reads the :quiet flag from directory maps and emits
      # reason :idle; the tab builder must map :quiet? windows back so idle
      # sessions still triage as needs_you.
      [tab] =
        SessionBarVM.session_tabs([
          shell_info_with_windows("quiet", [%{id: "@1", index: 0, name: "agent", quiet: true}])
        ])

      assert tab.attention_section == :needs_you
      assert tab.attention_reason == :idle

      assert [{:needs_you, [_]}] = SessionBarVM.session_attention_groups([tab])
    end

    test "working and plain sessions classify :working and :recent" do
      [working, plain] =
        SessionBarVM.session_tabs([
          shell_info_with_windows("working", [
            %{id: "@1", index: 0, name: "agent", agent_state: :working}
          ]),
          shell_info_with_windows("plain", [%{id: "@1", index: 0, name: "shell"}])
        ])

      assert working.attention_section == :working
      assert plain.attention_section == :recent
    end
  end

  describe "workspace_session_tree needs_you_count rollup" do
    test "counts needs-you sessions on the current workspace node" do
      tabs =
        SessionBarVM.session_tabs([
          shell_info_with_windows("blocked", [
            %{id: "@1", index: 0, name: "agent", agent_state: :blocked}
          ]),
          shell_info("calm")
        ])

      [node] =
        workspace_nodes(
          SessionBarVM.workspace_session_tree(
            [%{id: "ws-a", name: "alpha", session_count: 2, live?: true, sessions: []}],
            "ws-a",
            expanded_workspaces: MapSet.new(["ws-a"]),
            current_session_tabs: tabs,
            sidebar_ws_sessions: %{}
          )
        )

      assert node.needs_you_count == 1
    end

    test "collapsed other workspace still rolls up from cached sidebar sessions" do
      cached =
        SessionBarVM.session_tabs([
          shell_info_with_windows("blocked", [
            %{id: "@1", index: 0, name: "agent", agent_state: :blocked}
          ]),
          shell_info_with_windows("done", [
            %{id: "@1", index: 0, name: "agent", agent_state: :done}
          ])
        ])

      tree =
        SessionBarVM.workspace_session_tree(
          [
            %{id: "ws-a", name: "alpha", session_count: 1, live?: true, sessions: []},
            %{id: "ws-b", name: "beta", session_count: 2, live?: true, sessions: []}
          ],
          "ws-a",
          expanded_workspaces: MapSet.new(),
          current_session_tabs: [],
          sidebar_ws_sessions: %{"ws-b" => cached}
        )

      other = Enum.find(tree, &(&1.workspace_id == "ws-b"))
      refute other.expanded?
      assert other.sessions == nil
      assert other.needs_you_count == 2
    end

    test "workspaces with no cache report zero without enumerating sessions" do
      tree =
        SessionBarVM.workspace_session_tree(
          [%{id: "ws-b", name: "beta", session_count: 3, live?: true, sessions: []}],
          "ws-a",
          expanded_workspaces: MapSet.new(),
          current_session_tabs: [],
          sidebar_ws_sessions: %{}
        )

      other = Enum.find(tree, &(&1.workspace_id == "ws-b"))
      assert other.needs_you_count == 0
    end
  end

  describe "session_attention_groups urgency ordering" do
    test "orders the needs-you section blocked/error, then completed, then idle" do
      tabs =
        SessionBarVM.session_tabs([
          shell_info_with_windows("quiet", [%{id: "@1", index: 0, name: "a", quiet: true}]),
          shell_info_with_windows("done", [%{id: "@1", index: 0, name: "a", agent_state: :done}]),
          shell_info_with_windows("blocked", [
            %{id: "@1", index: 0, name: "a", agent_state: :blocked}
          ])
        ])

      assert [{:needs_you, [blocked, done, quiet]}] =
               SessionBarVM.session_attention_groups(tabs)

      assert blocked.attention_reason == :blocked
      assert done.attention_reason == :completed
      assert quiet.attention_reason == :idle
    end

    test "leaves working and recent sections in incoming order" do
      tabs =
        SessionBarVM.session_tabs([
          shell_info_with_windows("w2", [%{id: "@1", index: 0, name: "a", agent_state: :working}]),
          shell_info_with_windows("w1", [%{id: "@1", index: 0, name: "a", agent_state: :working}])
        ])

      assert [{:working, [first, second]}] = SessionBarVM.session_attention_groups(tabs)
      assert first.id == "w2"
      assert second.id == "w1"
    end
  end

  describe "needs_you_strip/3" do
    defp blocked_info(sid, message) do
      SessionInfo.new_shell("ws-a", sid,
        metadata: %{
          windows: [%{id: "@1", index: 0, name: "agent", agent_state: :blocked}],
          agent_state_messages: %{"@1" => message}
        }
      )
    end

    test "collects needs-you sessions across current and cached workspaces, urgency-first" do
      current =
        SessionBarVM.session_tabs([
          blocked_info("here-blocked", "waiting on approval"),
          shell_info("here-calm")
        ])

      other =
        SessionBarVM.session_tabs([
          shell_info_with_windows("there-done", [
            %{id: "@1", index: 0, name: "agent", agent_state: :done}
          ])
        ])

      rows =
        SessionBarVM.needs_you_strip(current, "ws-a",
          sidebar_ws_sessions: %{"ws-b" => other},
          summaries: [
            %{id: "ws-a", name: "alpha"},
            %{id: "ws-b", name: "beta"}
          ]
        )

      assert [blocked, done] = rows

      assert blocked.session_id == "here-blocked"
      assert blocked.current?
      assert blocked.reason == :blocked
      assert blocked.workspace_label == "alpha"
      assert blocked.message == "waiting on approval"

      assert done.session_id == "there-done"
      refute done.current?
      assert done.reason == :completed
      assert done.workspace_label == "beta"
      assert done.id == "ws-b:there-done"
    end

    test "excludes calm sessions and the current workspace's cached duplicate" do
      current = SessionBarVM.session_tabs([shell_info("calm-1"), shell_info("calm-2")])

      rows =
        SessionBarVM.needs_you_strip(current, "ws-a",
          sidebar_ws_sessions: %{"ws-a" => current},
          summaries: [%{id: "ws-a", name: "alpha"}]
        )

      assert rows == []
    end

    test "counts multiple blocked windows for the row badge" do
      current =
        SessionBarVM.session_tabs([
          shell_info_with_windows("multi", [
            %{id: "@1", index: 0, name: "a", agent_state: :blocked},
            %{id: "@2", index: 1, name: "b", agent_state: :blocked}
          ])
        ])

      assert [row] = SessionBarVM.needs_you_strip(current, "ws-a", summaries: [])
      assert row.agent_blocked_count == 2
    end

    # #910 catalogue + split counts + search. Constraints live here so a future
    # edit cannot collapse Stalled into idle/Quiet update or sum quiet windows
    # into Needs-you.
    test "chip catalogue keeps stalled distinct from idle and quiet" do
      assert SessionBarVM.attention_chip_label(:blocked) == "Needs input"
      assert SessionBarVM.attention_chip_label(:awaiting_input) == "Needs input"
      assert SessionBarVM.attention_chip_label(:errored) == "Error"
      assert SessionBarVM.attention_chip_label(:completed) == "Finished"
      # Stalled ≡ AgentProgress.running_but_not_progressing — NOT idle.
      assert SessionBarVM.attention_chip_label(:stalled) == "Stalled"
      assert SessionBarVM.attention_chip_label(:idle) == "Quiet update"

      refute SessionBarVM.attention_chip_label(:stalled) ==
               SessionBarVM.attention_chip_label(:idle)
    end

    test "stalled strip row carries Stalled reason, message, window deep-link fields" do
      # Messages ride agent_state_messages metadata (not a free window field).
      current =
        SessionBarVM.session_tabs([
          SessionInfo.new_shell("ws-a", "wedged",
            metadata: %{
              windows: [%{id: "@9", index: 0, name: "agent", agent_state: :stalled}],
              agent_state_messages: %{"@9" => "worktree quiet 900s"}
            }
          )
        ])

      assert [row] = SessionBarVM.needs_you_strip(current, "ws-a", summaries: [])
      assert row.reason == :stalled
      assert row.message == "worktree quiet 900s"
      assert row.window_id == "@9"
      assert row.search_text =~ "stalled"
      assert row.search_text =~ "worktree quiet"
      refute row.reason == :idle
    end

    test "needs_you_sessions and unseen_quiet_windows are distinct units" do
      tabs =
        SessionBarVM.session_tabs(
          [
            shell_info_with_windows("blocked", [
              %{id: "@1", index: 0, name: "a", agent_state: :blocked}
            ]),
            shell_info_with_windows("quiet", [
              %{id: "@2", index: 0, name: "b", quiet: true}
            ])
          ],
          unseen_quiet_window_ids: MapSet.new([{"quiet", "@2"}])
        )

      # One blocked + one quiet-idle triage session both count as needs_you sessions.
      assert SessionBarVM.needs_you_sessions(tabs) == 2
      # Unseen quiet is a window count — never added into Needs-you chip text.
      assert SessionBarVM.count_unseen_quiet_windows(tabs) >= 1

      refute SessionBarVM.needs_you_sessions(tabs) ==
               SessionBarVM.needs_you_sessions(tabs) +
                 SessionBarVM.count_unseen_quiet_windows(tabs)
    end
  end

  # Workspace names are slugs that need not match the checkout on disk
  # (`dalexandre-devide` lives at `dalexandre/dev_ide`), so the row's second line
  # has to carry the directory — letting the branch take it lost your place.
  describe "workspace_session_tree/3 row detail" do
    defp workspace_detail(summary) do
      [summary]
      |> SessionBarVM.workspace_session_tree("other-ws", sidebar_ws_sessions: %{})
      |> Enum.find(&(&1.workspace_id == summary.id))
      |> Map.fetch!(:detail)
    end

    test "shows the directory, not the default branch" do
      detail =
        workspace_detail(%{
          id: "ws-a",
          name: "dalexandre-devide",
          path_label: "dalexandre/dev_ide",
          branch: "master",
          live?: true,
          sessions: []
        })

      assert detail == "dalexandre/dev_ide"
    end

    test "appends a branch that is actually interesting" do
      detail =
        workspace_detail(%{
          id: "ws-a",
          name: "dalexandre-devide",
          path_label: "dalexandre/dev_ide",
          branch: "feature-x",
          live?: true,
          sessions: []
        })

      assert detail == "dalexandre/dev_ide ⑂ feature-x"
    end

    test "falls back to the branch when there is no path to show" do
      detail =
        workspace_detail(%{
          id: "ws-a",
          name: "alpha",
          branch: "master",
          live?: true,
          sessions: []
        })

      assert detail == "master"
    end
  end
end
