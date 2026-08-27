defmodule Casein.Agents.JidoWorkcellTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.{JidoPod, JidoWorkcell}

  test "admit exposes a bounded worker through the Workcell identity" do
    workspace_id = "ws-workcell-#{System.unique_integer([:positive])}"
    previous = Application.get_env(:casein, :jido_headless)
    previous_allowlist = Application.get_env(:casein, :jido_workcell_workspace_ids)

    Application.put_env(:casein, :jido_headless, true)
    Application.put_env(:casein, :jido_workcell_workspace_ids, :all)

    on_exit(fn ->
      _ = JidoWorkcell.stop(workspace_id)
      _ = JidoPod.stop_pod(workspace_id)
      restore(:jido_headless, previous)
      restore(:jido_workcell_workspace_ids, previous_allowlist)
    end)

    assert {:ok, admitted} =
             JidoWorkcell.admit(workspace_id, %{runtime: :jido, actions: []})

    assert admitted.state in [:running, :completed]
    assert admitted.workcell_id == JidoWorkcell.workcell_id(workspace_id)
    assert admitted.worker_id =~ ~r/\Aworker-[a-f0-9]{32}\z/
    assert admitted.runtime_id =~ ~r/\Aruntime-[a-f0-9]{32}\z/

    assert {:ok, status} = JidoWorkcell.status(workspace_id, admitted.worker_id)
    assert status.workcell_id == admitted.workcell_id
    assert status.runtime == :jido
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)
end
