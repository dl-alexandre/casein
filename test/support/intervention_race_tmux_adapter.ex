defmodule TmuxCtl.Test.InterventionRaceAdapter do
  @moduledoc false

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

  defp send_to_test(message) do
    if pid = FakeState.get(:intervention_race_test_pid), do: send(pid, message)
    :ok
  end
end
