defmodule Casein.Workspaces.AgentWriteUnlockExpirer do
  @moduledoc """
  Always-on sweeper that revokes agent-write unlocks whose timestamp has
  passed and audits the expiry — same category as `Casein.Terminals.TmuxJanitor`.

  Necessary because nothing else re-reads the unlock flag continuously: a
  workspace with zero connected viewers would otherwise sit with a stale
  `agent_write_unlocked_until` in the past forever (harmless — `agent_write_unlock_for/1`
  already treats a past timestamp as `:expired`/inactive — but the DB row and
  connected viewers wouldn't reflect it until someone happened to reconnect).
  """
  use GenServer

  require Logger

  alias Casein.Workspaces

  @sweep_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  defp sweep do
    now = DateTime.utc_now()

    Workspaces.list_records()
    |> Enum.filter(&expired?(&1, now))
    |> Enum.each(&expire_one/1)
  end

  defp expired?(%{agent_write_unlocked_until: nil}, _now), do: false

  defp expired?(%{agent_write_unlocked_until: until}, now),
    do: DateTime.compare(until, now) != :gt

  defp expire_one(record) do
    was_by = record.agent_write_unlocked_by
    was_until = record.agent_write_unlocked_until

    case Workspaces.revoke_agent_write_unlock(record.external_id) do
      {:ok, _} ->
        _ =
          Casein.Audit.emit!(%{
            action: "workspace.agent_write_unlock_expired",
            workspace_id: record.external_id,
            target_type: "workspace",
            target_ref: record.external_id,
            metadata: %{
              "was_granted_by" => was_by,
              "was_until" => was_until && DateTime.to_iso8601(was_until)
            }
          })

      {:error, reason} ->
        Logger.warning(
          "AgentWriteUnlockExpirer: could not revoke #{record.external_id}: #{inspect(reason)}"
        )
    end
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
end
