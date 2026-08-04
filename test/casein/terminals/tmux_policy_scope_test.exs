defmodule Casein.Terminals.TmuxPolicyScopeTest do
  @moduledoc """
  Security regression: tmux workspace scoping must be an exact namespace match.

  Session names are `casein_<sanitized_name>_<sid>` and `_` is legal inside a
  sanitized workspace name, so a bare `String.starts_with?/2` check made
  workspace `acme`'s prefix (`casein_acme_`) match workspace `acme_prod`'s
  session (`casein_acme_prod_1`). A capability token scoped to `acme` could
  therefore list and drive `acme_prod`'s panes — cross-workspace command
  execution across the boundary that constrains external agent tokens.
  """
  use ExUnit.Case, async: true

  alias Casein.Terminals.TmuxPolicy

  describe "session_in_namespace?/2 — the cross-workspace escape" do
    test "a workspace prefix does NOT match a longer-named sibling workspace" do
      acme_prefix = TmuxPolicy.workspace_session_prefix("acme")
      sibling_session = TmuxPolicy.session_name("acme_prod", "1")

      # The precondition that made this exploitable: it really is a string prefix.
      assert String.starts_with?(sibling_session, acme_prefix),
             "precondition: the collision exists at the string level"

      refute TmuxPolicy.session_in_namespace?(sibling_session, acme_prefix)
    end

    test "a workspace still matches its own sessions" do
      prefix = TmuxPolicy.workspace_session_prefix("acme_prod")

      assert TmuxPolicy.session_in_namespace?(TmuxPolicy.session_name("acme_prod", "1"), prefix)

      assert TmuxPolicy.session_in_namespace?(
               TmuxPolicy.session_name("acme_prod", "wt-3229c98a-a7f9-4b5f"),
               prefix
             )
    end

    test "collisions from sanitization are also rejected" do
      # sanitize/1 folds every non [A-Za-z0-9_-] char to `_`, so distinct names
      # can converge on the same prefix shape.
      prefix = TmuxPolicy.workspace_session_prefix("acme")

      for hostile <- ["acme.prod", "acme prod", "acme/prod"] do
        refute TmuxPolicy.session_in_namespace?(TmuxPolicy.session_name(hostile, "1"), prefix),
               "#{hostile} must not fall inside the acme namespace"
      end
    end

    test "real-world session shapes on the host all resolve to their own workspace" do
      cases = [
        {"dalexandre-audit", "wt-3229c98a-a7f9-4b5f-9e7e-c1e4746a0721"},
        {"dalexandre-pr-watch", "u-dalexandre-998j4dlp"},
        {"dalexandre-mira", "art-142632e1-3f15-4b55-8017-54db1204468a"},
        {"jgiles-facility-wf", "u-sconde-i1lt7l2n"},
        {"__scratch__", "u-dalexandre-rkgh0ice"}
      ]

      for {name, sid} <- cases do
        session = TmuxPolicy.session_name(name, sid)
        prefix = TmuxPolicy.workspace_session_prefix(name)

        assert TmuxPolicy.session_in_namespace?(session, prefix),
               "#{session} must belong to its own workspace"
      end
    end

    test "fails closed on junk input" do
      prefix = TmuxPolicy.workspace_session_prefix("acme")

      # Bare prefix with no sid is not a session.
      refute TmuxPolicy.session_in_namespace?(prefix, prefix)
      refute TmuxPolicy.session_in_namespace?("", prefix)
      refute TmuxPolicy.session_in_namespace?("unrelated", prefix)
      refute TmuxPolicy.session_in_namespace?(nil, prefix)
      refute TmuxPolicy.session_in_namespace?("casein_acme_1", nil)
    end
  end

  describe "sanitize_sid/1 keeps the parse unambiguous by construction" do
    test "folds underscores out of the sid segment" do
      # Without this, a user/workspace id that sanitized into an `_` would
      # reintroduce the collision inside the sid itself.
      assert TmuxPolicy.sanitize_sid("u-first.last-abc") == "u-first-last-abc"
      refute String.contains?(TmuxPolicy.sanitize_sid("a_b_c"), "_")
    end

    test "is a no-op for every sid shape the app generates today" do
      for sid <- ["main", "wt-3229c98a-a7f9", "u-dalexandre-998j4dlp", "art-142632e1"] do
        assert TmuxPolicy.sanitize_sid(sid) == sid,
               "#{sid} must not be renamed — live sessions depend on it"
      end
    end

    test "a sid that would collide is neutralised end to end" do
      prefix = TmuxPolicy.workspace_session_prefix("acme")
      # "prod_1" as a sid would otherwise produce casein_acme_prod_1 and be
      # indistinguishable from workspace acme_prod's session.
      session = TmuxPolicy.session_name("acme", "prod_1")

      assert session == "casein_acme_prod-1"
      assert TmuxPolicy.session_in_namespace?(session, prefix)

      refute TmuxPolicy.session_in_namespace?(
               session,
               TmuxPolicy.workspace_session_prefix("acme_prod")
             )
    end
  end
end
