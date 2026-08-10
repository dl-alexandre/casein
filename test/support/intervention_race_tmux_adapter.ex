defmodule TmuxCtl.Test.InterventionRaceAdapter do
  @moduledoc false

  # Partial scenario adapter installed as `:tmux_adapter` for intervention-race
  # tests. Scenario-specific functions stay local (and must reflect FakeState
  # scenario data — never constants). Everything else delegates to FakeAdapter
  # so unguarded product paths (`session_exists?/1`, `list_session_windows/1`,
  # `server_version/0`, …) cannot mystery-red the gate (#817 strategy a).

  @behaviour TmuxCtl.Adapter

  alias TmuxCtl.Test.FakeAdapter
  alias TmuxCtl.Test.FakeState

  def list_session_panes(session) do
    call_count = FakeState.get(:intervention_race_list_calls, 0) + 1
    FakeState.put(:intervention_race_list_calls, call_count)
    send_to_test({:intervention_race_list_panes, call_count})

    panes = FakeState.get(:intervention_race_panes, %{}) |> Map.get(session, [])

    if call_count == 1 do
      panes
    else
      Enum.map(panes, &Map.put(&1, :role, "verify"))
    end
  end

  def paste_text(session, text, opts) do
    send_to_test({:intervention_race_paste, session, text, opts})
    :ok
  end

  # Mobile terminal lease cleanup calls this unguarded (TerminalSessions).
  # Sessions seeded into :intervention_race_panes are live; unknown names are not.
  def session_exists?(session) do
    FakeState.get(:intervention_race_panes, %{}) |> Map.has_key?(session)
  end

  def session_exists?(session, _opts), do: session_exists?(session)

  # Topology / agent-prompt naming call this unguarded. Derive windows from the
  # panes seeded for the scenario — do not invent a constant "yes" window set
  # (that changed shutdown behaviour when session_exists?/1 was stubbed).
  def list_session_windows(session) do
    panes = FakeState.get(:intervention_race_panes, %{}) |> Map.get(session, [])

    panes
    |> Enum.map(&window_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(fn id ->
      %{id: id, name: "shell", active: true, last: false}
    end)
  end

  # Product paths call TmuxCtl.Adapter.server_version/0 unguarded. Scenario
  # override via FakeState; default matches FakeAdapter so stubs stay contract-
  # complete (#817).
  def server_version do
    FakeState.get(:fake_tmux_server_version, {3, 4})
  end

  def session_alive?(session), do: session_exists?(session)

  def session_topology(session), do: {list_session_windows(session), list_session_panes(session)}

  def list_sessions do
    FakeState.get(:intervention_race_panes, %{})
    |> Map.keys()
    |> Enum.map(fn session ->
      %{session: session, attached: false, activity: 0}
    end)
  end

  def directory_inventory do
    panes_by_session = FakeState.get(:intervention_race_panes, %{})

    windows =
      Map.new(panes_by_session, fn {session, panes} ->
        {session, list_session_windows(session) |> maybe_with_panes_count(panes)}
      end)

    {:ok, %{windows: windows, panes: panes_by_session}}
  end

  defdelegate ensure_session(session, cwd), to: FakeAdapter
  defdelegate attach(session), to: FakeAdapter
  defdelegate inject(target, text), to: FakeAdapter
  defdelegate inject(target, text, opts), to: FakeAdapter
  defdelegate capture_recent(target), to: FakeAdapter
  defdelegate capture_recent(target, lines), to: FakeAdapter
  defdelegate capture_recent(target, lines, opts), to: FakeAdapter
  defdelegate send_keys(session, keys), to: FakeAdapter
  defdelegate send_keys(session, keys, opts), to: FakeAdapter
  defdelegate capture_scrollback(session), to: FakeAdapter
  defdelegate capture_scrollback(session, opts), to: FakeAdapter
  defdelegate new_window(session), to: FakeAdapter
  defdelegate new_window(session, opts), to: FakeAdapter
  defdelegate select_window(session, window_id), to: FakeAdapter
  defdelegate last_window(session), to: FakeAdapter
  defdelegate cycle_window(session, dir), to: FakeAdapter
  defdelegate consolidate_sessions(target_session, source_sessions), to: FakeAdapter
  defdelegate select_pane(session, pane_id), to: FakeAdapter
  defdelegate navigate_pane(session, dir), to: FakeAdapter
  defdelegate zoom_pane(session, pane_id), to: FakeAdapter
  defdelegate swap_pane(session, pane_id, direction), to: FakeAdapter
  defdelegate ensure_zoomed(session, pane_id, desired?), to: FakeAdapter
  defdelegate kill_other_panes(session, pane_id), to: FakeAdapter
  defdelegate select_layout(session, layout), to: FakeAdapter
  defdelegate next_layout(session), to: FakeAdapter
  defdelegate kill_pane(session, pane_id), to: FakeAdapter
  defdelegate split_pane(session, pane_id, direction), to: FakeAdapter
  defdelegate split_pane(session, pane_id, direction, opts), to: FakeAdapter
  defdelegate resize_pane(session, pane_id, direction), to: FakeAdapter
  defdelegate resize_pane(session, pane_id, direction, amount), to: FakeAdapter
  defdelegate resize_amount_default(), to: FakeAdapter
  defdelegate resize_amount_max(), to: FakeAdapter
  defdelegate rename_window(session, window_id, name), to: FakeAdapter
  defdelegate set_session_alias(session, name), to: FakeAdapter
  defdelegate set_pane_role(session, pane_id, role), to: FakeAdapter
  defdelegate list_windows(), to: FakeAdapter
  defdelegate list_panes(), to: FakeAdapter
  defdelegate kill_window(session, window_id), to: FakeAdapter
  defdelegate kill(session), to: FakeAdapter
  defdelegate apply_defaults(session), to: FakeAdapter
  defdelegate set_environment(session, key, value), to: FakeAdapter
  defdelegate set_environments(session, env), to: FakeAdapter
  defdelegate send_command(session, command), to: FakeAdapter
  defdelegate send_command(session, command, opts), to: FakeAdapter
  defdelegate resize_window(session, cols, rows), to: FakeAdapter
  defdelegate refresh_client(session), to: FakeAdapter
  defdelegate tail_lines(output, n), to: FakeAdapter

  defp maybe_with_panes_count(windows, panes) do
    Enum.map(windows, fn window ->
      count =
        Enum.count(panes, fn pane ->
          window_id(pane) == Map.get(window, :id)
        end)

      Map.put(window, :panes, max(count, 1))
    end)
  end

  defp window_id(%{window_id: id}) when is_binary(id) and id != "", do: id
  defp window_id(%{"window_id" => id}) when is_binary(id) and id != "", do: id
  defp window_id(_), do: nil

  defp send_to_test(message) do
    if pid = FakeState.get(:intervention_race_test_pid), do: send(pid, message)
    :ok
  end
end
