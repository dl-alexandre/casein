defmodule Casein.Terminals.SessionRecoveryTest do
  use ExUnit.Case, async: false

  alias Casein.Terminals.{ScrollbackArchive, SessionRecovery, TemplatePreference}

  setup do
    archive_dir =
      Path.join(
        System.tmp_dir!(),
        "devide-recovery-archive-#{System.unique_integer([:positive])}"
      )

    pref_dir =
      Path.join(System.tmp_dir!(), "devide-recovery-prefs-#{System.unique_integer([:positive])}")

    Application.put_env(:casein, :tmux_scrollback_archive_dir, archive_dir)
    Application.put_env(:casein, :tmux_template_preference_dir, pref_dir)
    ScrollbackArchive.ensure_table!()
    TemplatePreference.ensure_table!()

    on_exit(fn ->
      File.rm_rf(archive_dir)
      File.rm_rf(pref_dir)
    end)

    :ok
  end

  test "seed_from_archive returns empty when no archive" do
    assert {<<>>, false} = SessionRecovery.seed_from_archive("devide_missing_session")
  end

  test "seed_from_archive prepends banner when archive present" do
    session = "devide_seed_#{System.unique_integer([:positive])}"
    ScrollbackArchive.put(session, "prior output\n")
    {buf, true} = SessionRecovery.seed_from_archive(session)
    assert String.contains?(buf, "prior output")
    assert String.contains?(buf, "Casein")
  end

  test "notify_session_recreated broadcasts recovery notice" do
    ws = "ws-recovery-#{System.unique_integer([:positive])}"
    sid = "sid-#{System.unique_integer([:positive])}"
    SessionRecovery.ensure_table!()
    :ok = SessionRecovery.subscribe_workspace(ws)

    notice =
      SessionRecovery.notify_session_recreated(
        tmux_session: "devide_#{ws}_#{sid}",
        workspace_id: ws,
        sid: sid,
        reason: :test,
        history_restored?: true,
        template_id: "agent_pair"
      )

    assert is_map(notice)
    assert notice.type == :session_recreated
    assert_receive {:terminal_recovery, ^notice}, 1_000

    # Same workspace+sid within the dedupe window is suppressed.
    assert :deduped =
             SessionRecovery.notify_session_recreated(
               tmux_session: "devide_#{ws}_#{sid}",
               workspace_id: ws,
               sid: sid,
               reason: :test_again,
               history_restored?: false
             )

    refute_receive {:terminal_recovery, _}, 100
  end

  test "template preference put/get and recovery_template fallback" do
    ws = "ws-pref-#{System.unique_integer([:positive])}"
    assert SessionRecovery.recovery_template(ws) == "agent_pair"
    TemplatePreference.put(ws, "my_layout")
    assert TemplatePreference.get(ws) == "my_layout"
    assert SessionRecovery.recovery_template(ws) == "my_layout"
  end
end
