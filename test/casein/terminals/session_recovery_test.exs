defmodule Casein.Terminals.SessionRecoveryTest do
  use ExUnit.Case, async: false

  alias Casein.Terminals.{ScrollbackArchive, SessionRecovery, TemplatePreference}

  setup do
    archive_dir =
      Path.join(
        System.tmp_dir!(),
        "casein-recovery-archive-#{System.unique_integer([:positive])}"
      )

    pref_dir =
      Path.join(System.tmp_dir!(), "casein-recovery-prefs-#{System.unique_integer([:positive])}")

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
    assert {<<>>, false} = SessionRecovery.seed_from_archive("casein_missing_session")
  end

  test "seed_from_archive prepends banner when archive present" do
    session = "casein_seed_#{System.unique_integer([:positive])}"
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
        tmux_session: "casein_#{ws}_#{sid}",
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
               tmux_session: "casein_#{ws}_#{sid}",
               workspace_id: ws,
               sid: sid,
               reason: :test_again,
               history_restored?: false
             )

    refute_receive {:terminal_recovery, _}, 100
  end

  test "notify_session_recreated caps a flapping session per window" do
    ws = "ws-flap-#{System.unique_integer([:positive])}"
    sid = "sid-#{System.unique_integer([:positive])}"
    SessionRecovery.ensure_table!()
    :ok = SessionRecovery.subscribe_workspace(ws)

    # Collapse the dedupe window so repeated notifies represent successive
    # drift ticks rather than one burst.
    Application.put_env(:casein, :session_recovery_dedupe_ms, 0)
    Application.put_env(:casein, :session_recovery_flap_window_ms, 60_000)
    Application.put_env(:casein, :session_recovery_max_notices, 2)

    on_exit(fn ->
      Application.delete_env(:casein, :session_recovery_dedupe_ms)
      Application.delete_env(:casein, :session_recovery_flap_window_ms)
      Application.delete_env(:casein, :session_recovery_max_notices)
    end)

    notify = fn ->
      SessionRecovery.notify_session_recreated(
        tmux_session: "casein_#{ws}_#{sid}",
        workspace_id: ws,
        sid: sid,
        reason: :session_missing_on_recover,
        history_restored?: false
      )
    end

    assert is_map(notify.())
    assert is_map(notify.())
    assert_receive {:terminal_recovery, _}, 1_000
    assert_receive {:terminal_recovery, _}, 1_000

    # Past the cap the session is flapping: no further broadcasts.
    assert :flapping = notify.()
    assert :flapping = notify.()
    refute_receive {:terminal_recovery, _}, 100

    # A different session in the same workspace is counted separately.
    other_sid = "sid-#{System.unique_integer([:positive])}"

    assert is_map(
             SessionRecovery.notify_session_recreated(
               tmux_session: "casein_#{ws}_#{other_sid}",
               workspace_id: ws,
               sid: other_sid,
               reason: :session_missing_on_recover,
               history_restored?: false
             )
           )

    assert_receive {:terminal_recovery, _}, 1_000
  end

  test "notify_session_recreated notifies again once the flap window elapses" do
    ws = "ws-flap-reset-#{System.unique_integer([:positive])}"
    sid = "sid-#{System.unique_integer([:positive])}"
    SessionRecovery.ensure_table!()
    :ok = SessionRecovery.subscribe_workspace(ws)

    Application.put_env(:casein, :session_recovery_dedupe_ms, 0)
    Application.put_env(:casein, :session_recovery_flap_window_ms, 50)
    Application.put_env(:casein, :session_recovery_max_notices, 1)

    on_exit(fn ->
      Application.delete_env(:casein, :session_recovery_dedupe_ms)
      Application.delete_env(:casein, :session_recovery_flap_window_ms)
      Application.delete_env(:casein, :session_recovery_max_notices)
    end)

    notify = fn ->
      SessionRecovery.notify_session_recreated(
        tmux_session: "casein_#{ws}_#{sid}",
        workspace_id: ws,
        sid: sid,
        reason: :session_missing_on_recover,
        history_restored?: false
      )
    end

    assert is_map(notify.())
    assert :flapping = notify.()

    Process.sleep(60)

    assert is_map(notify.()), "counter should restart after the flap window elapses"
  end

  test "template preference put/get and recovery_template fallback" do
    ws = "ws-pref-#{System.unique_integer([:positive])}"
    assert SessionRecovery.recovery_template(ws) == "agent_pair"
    TemplatePreference.put(ws, "my_layout")
    assert TemplatePreference.get(ws) == "my_layout"
    assert SessionRecovery.recovery_template(ws) == "my_layout"
  end
end
