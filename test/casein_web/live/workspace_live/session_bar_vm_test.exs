defmodule CaseinWeb.WorkspaceLive.Show.SessionBarVMTest do
  use ExUnit.Case, async: true

  alias Casein.Terminals.Session.Info, as: SessionInfo
  alias Casein.Workspaces.Scratch
  alias CaseinWeb.WorkspaceLive.Show.SessionBarVM

  defp shell_info(sid) do
    SessionInfo.new_shell("ws-a", sid, metadata: %{})
  end

  defp workspace_nodes(tree), do: Enum.reject(tree, &Scratch.scratch?(&1.workspace_id))

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
      # Attention.classify reads :quiet from directory maps; the tab builder must
      # map its :quiet? windows back so quiet sessions still triage as needs_you.
      [tab] =
        SessionBarVM.session_tabs([
          shell_info_with_windows("quiet", [%{id: "@1", index: 0, name: "agent", quiet: true}])
        ])

      assert tab.attention_section == :needs_you
      assert tab.attention_reason == :quiet

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
    test "orders the needs-you section blocked/error, then completed, then quiet" do
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
      assert quiet.attention_reason == :quiet
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
  end
end
