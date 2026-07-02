defmodule DevIdeWeb.WorkspaceLive.Show.AuditDrawerTest do
  use DevIDE.TestCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias DevIdeWeb.WorkspaceLive.Show.AuditDrawer
  alias DevIDE.Audit.Event

  # ---------------------------------------------------------------------------
  # Pure helper: deny_count/1
  # ---------------------------------------------------------------------------

  describe "deny_count/1" do
    test "counts only events with decision == :deny" do
      events = [
        %{decision: :deny},
        %{decision: :allow},
        %{decision: :deny},
        %{decision: nil}
      ]

      assert AuditDrawer.deny_count(events) == 2
    end

    test "returns 0 for an empty list" do
      assert AuditDrawer.deny_count([]) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Pure helper: ledger_event_count/1 (delegates to DevIDE.Runs.Ledger.ledger_event?/1)
  # ---------------------------------------------------------------------------

  describe "ledger_event_count/1" do
    test "plain maps are not ledger events (false clause)" do
      events = [%{action: "policy.check"}, %{decision: :allow}]
      assert AuditDrawer.ledger_event_count(events) == 0
    end

    test "counts %Event{} structs carrying the run-ledger metadata (true clause)" do
      ledger = %Event{
        id: "1",
        action: "run.started",
        inserted_at: DateTime.utc_now(),
        metadata: %{"ledger" => "run", "ledger_version" => 1}
      }

      non_ledger = %Event{
        id: "2",
        action: "policy.check",
        inserted_at: DateTime.utc_now(),
        metadata: %{}
      }

      assert AuditDrawer.ledger_event_count([ledger, non_ledger, %{decision: :allow}]) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Pure helper: audit_dot_class/1 (4 clauses)
  # ---------------------------------------------------------------------------

  describe "audit_dot_class/1" do
    test ":deny -> bg-red-600" do
      assert AuditDrawer.audit_dot_class(%{decision: :deny}) == "bg-red-600"
    end

    test ":allow -> bg-green-600" do
      assert AuditDrawer.audit_dot_class(%{decision: :allow}) == "bg-green-600"
    end

    test "workspace.mode_set action -> bg-amber-500" do
      assert AuditDrawer.audit_dot_class(%{action: "workspace.mode_set"}) == "bg-amber-500"
    end

    test "catch-all -> bg-zinc-400" do
      assert AuditDrawer.audit_dot_class(%{action: "something.else"}) == "bg-zinc-400"
    end
  end

  # ---------------------------------------------------------------------------
  # Pure helper: audit_verb_class/1 (4 clauses)
  # ---------------------------------------------------------------------------

  describe "audit_verb_class/1" do
    test ":deny -> text-red-700" do
      assert AuditDrawer.audit_verb_class(%{decision: :deny}) == "text-red-700"
    end

    test ":allow -> text-green-700" do
      assert AuditDrawer.audit_verb_class(%{decision: :allow}) == "text-green-700"
    end

    test "workspace.mode_set action -> text-amber-700" do
      assert AuditDrawer.audit_verb_class(%{action: "workspace.mode_set"}) == "text-amber-700"
    end

    test "catch-all -> text-zinc-600" do
      assert AuditDrawer.audit_verb_class(%{action: "something.else"}) == "text-zinc-600"
    end
  end

  # ---------------------------------------------------------------------------
  # Pure helper: audit_verb/1 (4 clauses)
  # ---------------------------------------------------------------------------

  describe "audit_verb/1" do
    test ":deny -> \"deny\"" do
      assert AuditDrawer.audit_verb(%{decision: :deny}) == "deny"
    end

    test ":allow -> \"allow\"" do
      assert AuditDrawer.audit_verb(%{decision: :allow}) == "allow"
    end

    test "workspace.mode_set action -> \"mode\"" do
      assert AuditDrawer.audit_verb(%{action: "workspace.mode_set"}) == "mode"
    end

    test "generic action -> last dotted segment" do
      assert AuditDrawer.audit_verb(%{action: "run.command.started"}) == "started"
    end

    test "single-segment action returns the whole action" do
      assert AuditDrawer.audit_verb(%{action: "boot"}) == "boot"
    end
  end

  # ---------------------------------------------------------------------------
  # Pure helper: audit_detail/1 (branches for ref / window label / reason)
  # ---------------------------------------------------------------------------

  describe "audit_detail/1" do
    test "action only — no ref, no window, no reason" do
      event = %{action: "run.started", target_ref: nil, reason: nil, metadata: %{}}
      assert AuditDrawer.audit_detail(event) == "run.started"
    end

    test "empty-string ref is treated as no ref" do
      event = %{action: "run.started", target_ref: "", reason: nil, metadata: %{}}
      assert AuditDrawer.audit_detail(event) == "run.started"
    end

    test "non-empty ref is appended" do
      event = %{action: "run.started", target_ref: "abc", reason: nil, metadata: %{}}
      assert AuditDrawer.audit_detail(event) == "run.started · abc"
    end

    test "tmux_window_name (string key) is appended as win:" do
      event = %{
        action: "run.started",
        target_ref: nil,
        reason: nil,
        metadata: %{"tmux_window_name" => "editor"}
      }

      assert AuditDrawer.audit_detail(event) == "run.started · win:editor"
    end

    test "tmux_window_id (atom key) is used when name absent" do
      event = %{
        action: "run.started",
        target_ref: nil,
        reason: nil,
        metadata: %{tmux_window_id: "@3"}
      }

      assert AuditDrawer.audit_detail(event) == "run.started · win:@3"
    end

    test "reason atom is appended" do
      event = %{action: "policy.check", target_ref: nil, reason: :policy_deny, metadata: %{}}
      assert AuditDrawer.audit_detail(event) == "policy.check · policy_deny"
    end

    test "ref, window label, and reason all combine in order" do
      event = %{
        action: "policy.check",
        target_ref: "tmux/window",
        reason: :rate_limited,
        metadata: %{"tmux_window_name" => "shell"}
      }

      assert AuditDrawer.audit_detail(event) ==
               "policy.check · tmux/window · win:shell · rate_limited"
    end

    test "non-map metadata yields no window label" do
      event = %{action: "run.started", target_ref: nil, reason: nil, metadata: nil}
      assert AuditDrawer.audit_detail(event) == "run.started"
    end
  end

  # ---------------------------------------------------------------------------
  # Component: audit_drawer/1
  # ---------------------------------------------------------------------------

  defp event(attrs) do
    Map.merge(
      %{
        id: "evt-#{System.unique_integer([:positive])}",
        action: "run.started",
        decision: nil,
        target_ref: nil,
        reason: nil,
        metadata: %{},
        inserted_at: ~U[2026-06-24 13:45:07Z]
      },
      Map.new(attrs)
    )
  end

  defp drawer_assigns(overrides) do
    base = %{
      audit_drawer_open: true,
      audit_events_count: 0,
      audit_ledger_count: 0,
      audit_window_filter: "",
      workspace: %{name: "alpha"},
      streams: %{audit_events: []}
    }

    Map.merge(base, Map.new(overrides))
  end

  describe "audit_drawer/1 — closed" do
    test "renders nothing when drawer is closed" do
      assigns = drawer_assigns(audit_drawer_open: false)

      html =
        rendered_to_string(~H"""
        <AuditDrawer.audit_drawer
          audit_drawer_open={@audit_drawer_open}
          audit_events_count={@audit_events_count}
          audit_ledger_count={@audit_ledger_count}
          audit_window_filter={@audit_window_filter}
          workspace={@workspace}
          streams={@streams}
        />
        """)

      refute html =~ "Evidence drawer"
      refute html =~ "no events recorded yet"
    end
  end

  describe "audit_drawer/1 — open with no events" do
    test "renders chrome, counts, workspace name, filter and empty placeholder" do
      assigns =
        drawer_assigns(
          audit_events_count: 7,
          audit_ledger_count: 3,
          audit_window_filter: "shell",
          workspace: %{name: "beta"},
          streams: %{audit_events: []}
        )

      html =
        rendered_to_string(~H"""
        <AuditDrawer.audit_drawer
          audit_drawer_open={@audit_drawer_open}
          audit_events_count={@audit_events_count}
          audit_ledger_count={@audit_ledger_count}
          audit_window_filter={@audit_window_filter}
          workspace={@workspace}
          streams={@streams}
        />
        """)

      assert html =~ "Evidence drawer"
      assert html =~ "7 events"
      assert html =~ "3 ledger"
      assert html =~ "workspace beta"
      assert html =~ ~s(value="shell")
      assert html =~ "no events recorded yet"
      assert html =~ ~s(phx-click="audit_drawer:close")
      assert html =~ ~s(phx-click="audit_drawer:refresh")
      assert html =~ ~s(phx-change="audit_drawer:filter_window")
    end
  end

  describe "audit_drawer/1 — open with events" do
    test "renders deny, allow, mode_set and ledger-run rows with their classes/verbs" do
      deny = event(decision: :deny, action: "policy.check", target_ref: "fs/write")
      allow = event(decision: :allow, action: "policy.check", target_ref: "fs/read")
      mode = event(action: "workspace.mode_set", target_ref: "review")

      run =
        event(
          action: "run.started",
          target_ref: "cmd-1",
          metadata: %{"run_id" => "run-xyz"}
        )

      stream =
        [deny, allow, mode, run]
        |> Enum.map(fn e -> {"audit-events-#{e.id}", e} end)

      assigns = drawer_assigns(streams: %{audit_events: stream})

      html =
        rendered_to_string(~H"""
        <AuditDrawer.audit_drawer
          audit_drawer_open={@audit_drawer_open}
          audit_events_count={@audit_events_count}
          audit_ledger_count={@audit_ledger_count}
          audit_window_filter={@audit_window_filter}
          workspace={@workspace}
          streams={@streams}
        />
        """)

      # dot classes from audit_dot_class/1
      assert html =~ "bg-red-600"
      assert html =~ "bg-green-600"
      assert html =~ "bg-amber-500"
      assert html =~ "bg-zinc-400"

      # verb classes from audit_verb_class/1
      assert html =~ "text-red-700"
      assert html =~ "text-green-700"
      assert html =~ "text-amber-700"
      assert html =~ "text-zinc-600"

      # verbs from audit_verb/1
      assert html =~ "deny"
      assert html =~ "allow"
      assert html =~ "mode"
      assert html =~ "started"

      # details from audit_detail/1
      assert html =~ "fs/write"
      assert html =~ "fs/read"

      # formatted timestamp
      assert html =~ "13:45:07"

      # run button appears only for the event with a run_id
      assert html =~ ~s(phx-click="run_ledger:open")
      assert html =~ ~s(phx-value-id="run-xyz")
      assert html =~ ~s(id="audit-open-run-run-xyz-)
    end

    test "no run button when no event carries a run_id" do
      plain = event(action: "policy.check", decision: :allow, target_ref: "fs/read")
      stream = [{"audit-events-#{plain.id}", plain}]

      assigns = drawer_assigns(streams: %{audit_events: stream})

      html =
        rendered_to_string(~H"""
        <AuditDrawer.audit_drawer
          audit_drawer_open={@audit_drawer_open}
          audit_events_count={@audit_events_count}
          audit_ledger_count={@audit_ledger_count}
          audit_window_filter={@audit_window_filter}
          workspace={@workspace}
          streams={@streams}
        />
        """)

      refute html =~ ~s(phx-click="run_ledger:open")
    end
  end
end
