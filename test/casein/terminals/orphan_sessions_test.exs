defmodule Casein.Terminals.OrphanSessionsTest do
  @moduledoc """
  Classification only. `classify/2` is pure so the interesting cases — a
  workspace name that is a prefix of another, scratch, another developer's
  session — can be pinned without tmux or a database.
  """
  use ExUnit.Case, async: true

  alias Casein.Terminals.OrphanSessions
  alias Casein.Terminals.TmuxPolicy
  alias Casein.Workspaces.Scratch
  alias Casein.Workspaces.State.WorkspaceRecord

  defp session(name, attached \\ false), do: %{session: name, attached: attached, activity: 0}

  defp record(name, status \\ "running"),
    do: %WorkspaceRecord{external_id: name, name: name, status: status}

  defp retired(name), do: record(name, WorkspaceRecord.stale_status())

  describe "classify/2" do
    test "a session whose workspace is live is not reported" do
      sessions = [session(TmuxPolicy.session_name("acme", "wt-1"))]

      assert OrphanSessions.classify(sessions, [record("acme")]) == []
    end

    test "a session whose workspace the reconciler retired is reported as :retired" do
      sessions = [session(TmuxPolicy.session_name("acme", "wt-1"))]

      assert [orphan] = OrphanSessions.classify(sessions, [retired("acme")])
      assert orphan.workspace == "acme"
      assert orphan.confidence == :retired
    end

    test "a session with no matching record is :unknown, not :retired" do
      # On a shared box this may simply be another developer's workspace, which
      # Casein never listed. Reporting it as a confirmed orphan is how a sweep
      # turns into killing someone else's panes.
      sessions = [session(TmuxPolicy.session_name("someone-else", "wt-9"))]

      assert [orphan] = OrphanSessions.classify(sessions, [record("acme")])
      assert orphan.workspace == nil
      assert orphan.confidence == :unknown
    end

    test "a workspace name that prefixes another does not adopt its sessions" do
      # `casein_acme_` is a genuine prefix of `casein_acme_prod_1`, so a bare
      # starts_with? would attribute acme_prod's live session to retired acme.
      sessions = [session(TmuxPolicy.session_name("acme_prod", "1"))]
      records = [retired("acme"), record("acme_prod")]

      assert OrphanSessions.classify(sessions, records) == []
    end

    test "the scratch workspace is never reported" do
      # Scratch is workspaceless by design; without the exclusion it would be an
      # orphan on every run, forever.
      sessions = [session(TmuxPolicy.session_name(Scratch.id(), "1"))]

      assert OrphanSessions.classify(sessions, []) == []
    end

    test "sessions tmux did not create for Casein are ignored" do
      sessions = [session("someone-elses-shell"), session("0")]

      assert OrphanSessions.classify(sessions, []) == []
    end

    test "reports the attached flag so a live pane is distinguishable" do
      sessions = [session(TmuxPolicy.session_name("acme", "wt-1"), true)]

      assert [%{attached: true}] = OrphanSessions.classify(sessions, [retired("acme")])
    end

    test "a record with no usable name cannot swallow every session" do
      # A blank name would build the prefix `casein__`, which must not be
      # allowed to claim unrelated sessions.
      sessions = [session(TmuxPolicy.session_name("acme", "wt-1"))]

      assert [%{confidence: :unknown}] =
               OrphanSessions.classify(sessions, [record(""), record(nil)])
    end

    test "results are sorted by session name" do
      sessions = [
        session(TmuxPolicy.session_name("zeta", "1")),
        session(TmuxPolicy.session_name("alpha", "1"))
      ]

      assert [first, second] = OrphanSessions.classify(sessions, [])
      assert first.session < second.session
    end
  end
end
