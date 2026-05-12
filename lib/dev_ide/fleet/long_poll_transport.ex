defmodule DevIDE.Fleet.LongPollTransport do
  @moduledoc """
  HTTP long-poll transport for the fleet protocol.

  This is the first real controller <-> runner boundary for the M45+
  fleet execution protocol. A runner registers, long-polls for an assignment
  offer, then posts protocol envelopes back to the controller.

  The transport only moves already-approved safe-action assignment ids. It
  does not accept raw argv, shell text, or arbitrary command payloads.
  """

  alias DevIDE.Assignments
  alias DevIDE.Assignments.Assignment
  alias DevIDE.Fleet
  alias DevIDE.Fleet.{Lease, Placement, Queue, Runner, RunnerDirectory}
  alias DevIDE.Fleet.Protocol
  alias DevIDE.Fleet.Protocol.Messages

  @protocol "devide.fleet.http.v1"
  @default_timeout_ms 20_000
  @max_timeout_ms 30_000
  @poll_interval_ms 50

  @type offer :: %{
          protocol: String.t(),
          envelope: map(),
          lease: Lease.t(),
          assignment: Assignment.t()
        }

  @spec protocol() :: String.t()
  def protocol, do: @protocol

  @spec poll_offer(String.t(), keyword()) :: {:ok, offer()} | :none | {:error, term()}
  def poll_offer(runner_id, opts \\ [])

  def poll_offer(runner_id, opts) when is_binary(runner_id) do
    timeout_ms =
      opts
      |> Keyword.get(:timeout_ms, @default_timeout_ms)
      |> normalize_timeout()

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll_offer(runner_id, deadline, Keyword.get(opts, :poll_interval_ms, @poll_interval_ms))
  end

  def poll_offer(_runner_id, _opts), do: {:error, :invalid_runner_id}

  defp do_poll_offer(runner_id, deadline, interval_ms) do
    case offer_once(runner_id) do
      :none ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          :none
        else
          receive do
          after
            min(interval_ms, remaining) -> do_poll_offer(runner_id, deadline, interval_ms)
          end
        end

      other ->
        other
    end
  end

  defp offer_once(runner_id) do
    with {:ok, %Runner{} = runner} <- fetch_runner(runner_id),
         {:ok, entry} <- next_eligible_entry(runner),
         {:ok, assignment} <- fetch_assignment(entry.assignment_id),
         {:ok, safe_action_id} <- safe_action_id(assignment),
         {:ok, lease} <- acquire_lease(runner, entry),
         {:ok, claimed} <- claim_with_lease(assignment, lease),
         :ok <- Queue.remove(entry.assignment_id) do
      message = %Messages.AssignmentOffered{
        assignment_id: claimed.id,
        safe_action_id: safe_action_id,
        workspace_id: claimed.workspace_id,
        lease_duration_ms: lease_duration_ms(lease)
      }

      envelope = Protocol.wrap(message, runner_id: runner.id, lease_id: lease.id)

      {:ok,
       %{
         protocol: @protocol,
         envelope: Protocol.serialize(envelope),
         lease: lease,
         assignment: claimed
       }}
    end
  end

  defp fetch_runner(runner_id) do
    with :ok <- runner_not_revoked(runner_id) do
      case Fleet.get_runner(runner_id) do
        {:ok, runner} -> {:ok, runner}
        :error -> {:error, :runner_not_found}
      end
    end
  end

  defp runner_not_revoked(runner_id) do
    case RunnerDirectory.get(runner_id) do
      {:ok, %{trust_state: :revoked}} -> {:error, :runner_revoked}
      _ -> :ok
    end
  end

  defp next_eligible_entry(%Runner{} = runner) do
    snapshot = enriched_snapshot()

    Queue.list()
    |> Enum.find(fn entry ->
      runner.id in Placement.compute_eligible(entry.requirements, snapshot)
    end)
    |> case do
      nil -> :none
      entry -> {:ok, entry}
    end
  end

  defp fetch_assignment(assignment_id) do
    case Assignments.get(assignment_id) do
      {:ok, assignment} -> {:ok, assignment}
      :error -> {:error, :assignment_not_found}
    end
  end

  defp acquire_lease(%Runner{} = runner, entry) do
    Fleet.acquire_lease(runner.id, entry.assignment_id,
      duration_ms: entry.requirements.max_runtime_ms || default_lease_duration_ms()
    )
  end

  defp claim_with_lease(%Assignment{} = assignment, %Lease{} = lease) do
    case claim_assignment(assignment, lease) do
      {:ok, claimed} ->
        {:ok, claimed}

      {:error, reason} ->
        Fleet.release_lease(assignment.id)
        {:error, reason}
    end
  end

  defp claim_assignment(%Assignment{state: state} = assignment, %Lease{} = lease)
       when state in ["requested", "queued"] do
    Assignments.claim(assignment.id, lease.runner_id, lease_ms: lease_duration_ms(lease))
  end

  defp claim_assignment(
         %Assignment{state: "claimed", lease_owner: runner_id} = assignment,
         %Lease{
           runner_id: runner_id
         }
       ) do
    {:ok, assignment}
  end

  defp claim_assignment(%Assignment{} = assignment, _lease) do
    {:error, {:assignment_not_claimable, assignment.state}}
  end

  defp safe_action_id(%Assignment{metadata: metadata}) do
    safe_action_id = metadata_value(metadata, "safe_action_id")
    command_id = metadata_value(metadata, "command_id")

    cond do
      is_binary(safe_action_id) and safe_action_id != "" ->
        {:ok, safe_action_id}

      is_binary(command_id) and command_id != "" ->
        {:ok, "command:" <> command_id}

      true ->
        {:error, :safe_action_missing}
    end
  end

  defp enriched_snapshot do
    active_leases_by_runner =
      Fleet.active_leases()
      |> Enum.group_by(& &1.runner_id)
      |> Map.new(fn {id, leases} -> {id, leases} end)

    Fleet.snapshot()
    |> Map.put(:runners, Fleet.list_runners())
    |> Map.put(:active_leases_by_runner, active_leases_by_runner)
  end

  defp lease_duration_ms(%Lease{} = lease) do
    max(DateTime.diff(lease.expires_at, lease.acquired_at, :millisecond), 1)
  end

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, String.to_atom(key))
  end

  defp metadata_value(_metadata, _key), do: nil

  defp normalize_timeout(value) when is_integer(value) do
    value
    |> max(0)
    |> min(@max_timeout_ms)
  end

  defp normalize_timeout(_value), do: @default_timeout_ms

  defp default_lease_duration_ms do
    Application.get_env(:dev_ide, :fleet_lease_duration_ms, 15 * 60 * 1000)
  end
end
