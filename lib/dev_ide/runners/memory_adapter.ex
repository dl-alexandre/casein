defmodule DevIDE.Runners.MemoryAdapter do
  @moduledoc "In-memory adapter for the JX runner protocol. Used by tests and dev fallback."

  use GenServer

  @behaviour DevIDE.Runners

  alias DevIDE.Runners.{Assignment, ProgressReport, SafeAction, StateMachine}

  def start_link(_opts \\ []),
    do: GenServer.start_link(__MODULE__, %{assignments: %{}, reports: %{}}, name: __MODULE__)

  @impl true
  def create_assignment(%Assignment{} = assignment),
    do: GenServer.call(__MODULE__, {:create_assignment, assignment})

  @impl true
  def claim_one(claim), do: GenServer.call(__MODULE__, {:claim_one, claim})

  @impl true
  def append_report(assignment_id, claim_token, attrs),
    do: GenServer.call(__MODULE__, {:append_report, assignment_id, claim_token, attrs})

  @impl true
  def complete(assignment_id, claim_token, attrs),
    do: GenServer.call(__MODULE__, {:complete, assignment_id, claim_token, attrs})

  @impl true
  def expire_leases(now), do: GenServer.call(__MODULE__, {:expire_leases, now})

  @impl true
  def abandon(assignment_id, attrs),
    do: GenServer.call(__MODULE__, {:abandon, assignment_id, attrs})

  @impl true
  def get_assignment(id), do: GenServer.call(__MODULE__, {:get_assignment, id})

  @impl true
  def reports_for(assignment_id), do: GenServer.call(__MODULE__, {:reports_for, assignment_id})

  @impl true
  def clear, do: GenServer.call(__MODULE__, :clear)

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:create_assignment, %Assignment{} = assignment}, _from, state) do
    now = DateTime.utc_now()
    assignment = %{assignment | inserted_at: assignment.inserted_at || now, updated_at: now}

    {:reply, {:ok, assignment}, put_in(state, [:assignments, assignment.id], assignment)}
  end

  def handle_call({:claim_one, claim}, _from, state) do
    case find_claimable(state.assignments, claim) do
      nil ->
        {:reply, :none, state}

      %Assignment{} = assignment ->
        {:ok, next_status} = StateMachine.transition(assignment.status, :claim)

        claimed = %{
          assignment
          | status: next_status,
            claimed_by: claim.runner_id,
            claim_token: claim.claim_token,
            claimed_at: claim.claimed_at,
            lease_expires_at: claim.lease_expires_at,
            updated_at: DateTime.utc_now()
        }

        {:reply, {:ok, claimed}, put_in(state, [:assignments, assignment.id], claimed)}
    end
  end

  def handle_call({:append_report, assignment_id, claim_token, attrs}, _from, state) do
    case fetch_claimed(state, assignment_id, claim_token) do
      {:ok, assignment} ->
        case existing_client_report(state, assignment_id, Map.get(attrs, :client_report_id)) do
          %ProgressReport{} = report ->
            if same_report?(report, attrs),
              do: {:reply, {:ok, report}, state},
              else: {:reply, {:error, :duplicate_report_conflict}, state}

          nil ->
            with {:ok, assignment, state} <- maybe_mark_running(assignment, attrs, state) do
              report = build_report(assignment, attrs, state)
              state = put_report(state, report)
              {:reply, {:ok, report}, state}
            else
              {:error, _reason} = error -> {:reply, error, state}
            end
        end

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:complete, assignment_id, claim_token, attrs}, _from, state) do
    case fetch_claimed(state, assignment_id, claim_token) do
      {:ok, assignment} ->
        case existing_client_report(state, assignment_id, Map.get(attrs, :client_report_id)) do
          %ProgressReport{} = report ->
            if same_terminal_report?(report, attrs),
              do: {:reply, {:ok, assignment, report}, state},
              else: {:reply, {:error, :duplicate_report_conflict}, state}

          nil ->
            complete_claimed(state, assignment_id, assignment, attrs)
        end

      {:ok_terminal, assignment} ->
        case existing_client_report(state, assignment_id, Map.get(attrs, :client_report_id)) do
          %ProgressReport{} = report ->
            if same_terminal_report?(report, attrs),
              do: {:reply, {:ok, assignment, report}, state},
              else: {:reply, {:error, :duplicate_report_conflict}, state}

          nil ->
            {:reply, {:error, :assignment_terminal}, state}
        end

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:expire_leases, now}, _from, state) do
    {pairs, expired} =
      Enum.map_reduce(state.assignments, [], fn {id, assignment}, acc ->
        if lease_expired?(assignment, now) do
          expired = expire_assignment(assignment, now, "lease expired")
          {{id, expired}, [expired | acc]}
        else
          {{id, assignment}, acc}
        end
      end)

    {:reply, Enum.reverse(expired), %{state | assignments: Map.new(pairs)}}
  end

  def handle_call({:abandon, assignment_id, attrs}, _from, state) do
    case Map.fetch(state.assignments, assignment_id) do
      {:ok, %Assignment{} = assignment} ->
        case StateMachine.transition(assignment.status, :abandon) do
          {:ok, next_status} ->
            now = Map.get(attrs, :completed_at, DateTime.utc_now())

            abandoned = %{
              assignment
              | status: next_status,
                completed_at: now,
                failure_reason: Map.get(attrs, :reason),
                evidence: Map.get(attrs, :evidence, %{}),
                updated_at: now
            }

            {:reply, {:ok, abandoned}, put_in(state, [:assignments, assignment_id], abandoned)}

          {:error, _reason} = error ->
            {:reply, error, state}
        end

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:get_assignment, id}, _from, state) do
    case Map.fetch(state.assignments, id) do
      {:ok, assignment} -> {:reply, {:ok, assignment}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call({:reports_for, assignment_id}, _from, state) do
    reports =
      state.reports
      |> Map.get(assignment_id, [])
      |> Enum.sort_by(& &1.position)

    {:reply, reports, state}
  end

  def handle_call(:clear, _from, _state),
    do: {:reply, :ok, %{assignments: %{}, reports: %{}}}

  defp complete_claimed(state, assignment_id, assignment, attrs) do
    event = if attrs.status == "succeeded", do: :succeed, else: :fail

    with {:ok, next_status} <- StateMachine.transition(assignment.status, event) do
      now = DateTime.utc_now()
      evidence = maybe_put_failure_class(attrs.evidence, Map.get(attrs, :failure_class))

      completed = %{
        assignment
        | status: next_status,
          completed_at: now,
          failure_reason: attrs.failure_reason,
          evidence: evidence,
          updated_at: now
      }

      report =
        build_report(
          completed,
          %{
            client_report_id: Map.get(attrs, :client_report_id),
            event: terminal_event(attrs.status),
            message: attrs.message,
            evidence: evidence,
            observed_at: attrs.observed_at
          },
          state
        )

      state =
        state
        |> put_in([:assignments, assignment_id], completed)
        |> put_report(report)

      {:reply, {:ok, completed, report}, state}
    end
  end

  defp find_claimable(assignments, claim) do
    assignments
    |> Map.values()
    |> Enum.filter(&claimable?(&1, claim))
    |> Enum.sort_by(& &1.queued_at, {:asc, DateTime})
    |> List.first()
  end

  defp claimable?(%Assignment{} = assignment, claim) do
    assignment.status == "queued" and
      safe_action_claimable?(assignment.safe_action_id, claim.safe_action_ids) and
      (claim.workspace_ids == [] or assignment.workspace_id in claim.workspace_ids) and
      routing_match?(assignment.metadata || %{}, claim.routing || %{})
  end

  defp safe_action_claimable?(safe_action_id, safe_action_ids) do
    safe_action_id in safe_action_ids or
      workflow_action_claimable?(safe_action_id, safe_action_ids)
  end

  defp workflow_action_claimable?("command:workflow:" <> _ = safe_action_id, safe_action_ids) do
    with true <- "command:workflow:" in safe_action_ids,
         {:ok, action} <- SafeAction.fetch(safe_action_id) do
      SafeAction.compatible?(action, ["workspace-command:v1"])
    else
      _ -> false
    end
  end

  defp workflow_action_claimable?(_, _), do: false

  defp fetch_claimed(state, assignment_id, claim_token) do
    case Map.fetch(state.assignments, assignment_id) do
      {:ok, %Assignment{status: status, claim_token: ^claim_token} = assignment}
      when status in ["claimed", "running"] ->
        if lease_expired?(assignment, DateTime.utc_now()),
          do: {:error, :lease_expired},
          else: {:ok, assignment}

      {:ok, %Assignment{status: status} = assignment} when status in ["claimed", "running"] ->
        if lease_expired?(assignment, DateTime.utc_now()),
          do: {:error, :lease_expired},
          else: {:error, :claim_token_invalid}

      {:ok, %Assignment{status: status, claim_token: ^claim_token} = assignment}
      when status in ["succeeded", "failed", "expired", "abandoned"] ->
        {:ok_terminal, assignment}

      {:ok, %Assignment{status: status}}
      when status in ["succeeded", "failed", "expired", "abandoned"] ->
        {:error, :assignment_terminal}

      {:ok, %Assignment{}} ->
        {:error, :assignment_not_claimed}

      :error ->
        {:error, :not_found}
    end
  end

  defp maybe_mark_running(%Assignment{status: "claimed"} = assignment, attrs, state) do
    if StateMachine.start_event?(Map.get(attrs, :event)) do
      with {:ok, "running"} <- StateMachine.transition(assignment.status, :start) do
        running = %{assignment | status: "running", updated_at: DateTime.utc_now()}
        {:ok, running, put_in(state, [:assignments, assignment.id], running)}
      end
    else
      {:ok, assignment, state}
    end
  end

  defp maybe_mark_running(%Assignment{} = assignment, _attrs, state), do: {:ok, assignment, state}

  defp build_report(%Assignment{} = assignment, attrs, state) do
    %ProgressReport{
      id: Ecto.UUID.generate(),
      assignment_id: assignment.id,
      client_report_id: Map.get(attrs, :client_report_id),
      runner_id: assignment.claimed_by,
      position: next_position(state, assignment.id),
      event: attrs.event,
      stream: Map.get(attrs, :stream),
      message: Map.get(attrs, :message),
      data: Map.get(attrs, :data),
      data_truncated: Map.get(attrs, :data_truncated, false),
      evidence: Map.get(attrs, :evidence, %{}),
      observed_at: Map.get(attrs, :observed_at, DateTime.utc_now()),
      inserted_at: DateTime.utc_now()
    }
  end

  defp next_position(state, assignment_id),
    do: length(Map.get(state.reports, assignment_id, [])) + 1

  defp existing_client_report(_state, _assignment_id, nil), do: nil
  defp existing_client_report(_state, _assignment_id, ""), do: nil

  defp existing_client_report(state, assignment_id, client_report_id) do
    state.reports
    |> Map.get(assignment_id, [])
    |> Enum.find(&(&1.client_report_id == client_report_id))
  end

  defp put_report(state, %ProgressReport{} = report),
    do: update_in(state, [:reports, report.assignment_id], &[report | &1 || []])

  defp terminal_event("succeeded"), do: "completed"
  defp terminal_event("failed"), do: "failed"

  defp same_report?(%ProgressReport{} = report, attrs) do
    report.event == Map.get(attrs, :event) and
      report.stream == Map.get(attrs, :stream) and
      report.message == Map.get(attrs, :message) and
      report.data == Map.get(attrs, :data) and
      report.evidence == Map.get(attrs, :evidence, %{})
  end

  defp same_terminal_report?(%ProgressReport{} = report, attrs) do
    report.event == terminal_event(attrs.status) and
      report.message == attrs.message and
      report.evidence == maybe_put_failure_class(attrs.evidence, Map.get(attrs, :failure_class))
  end

  defp maybe_put_failure_class(evidence, nil), do: evidence || %{}

  defp maybe_put_failure_class(evidence, failure_class),
    do: Map.put(evidence || %{}, "failure_class", failure_class)

  defp lease_expired?(%Assignment{status: status}, _now)
       when status in ["queued", "succeeded", "failed", "expired", "abandoned"],
       do: false

  defp lease_expired?(%Assignment{lease_expires_at: nil}, _now), do: false

  defp lease_expired?(%Assignment{lease_expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) != :gt

  defp expire_assignment(%Assignment{} = assignment, now, reason) do
    {:ok, next_status} = StateMachine.transition(assignment.status, :expire)

    %{
      assignment
      | status: next_status,
        completed_at: now,
        failure_reason: reason,
        evidence: %{"failure_class" => "lease_expired"},
        updated_at: now
    }
  end

  defp routing_match?(metadata, routing) do
    requirements = Map.get(metadata, "routing") || Map.get(metadata, :routing) || %{}

    concurrency_ok?(routing) and
      string_requirement_met?(requirements, routing, "host") and
      string_requirement_met?(requirements, routing, "os") and
      string_requirement_met?(requirements, routing, "repo") and
      string_requirement_met?(requirements, routing, "branch_isolation") and
      string_requirement_met?(requirements, routing, "runtime_id") and
      string_requirement_met?(requirements, routing, "runtime_path") and
      tools_requirement_met?(requirements, routing)
  end

  defp concurrency_ok?(routing) do
    Map.get(routing, "active_assignments", 0) < Map.get(routing, "concurrency_limit", 1)
  end

  defp string_requirement_met?(requirements, routing, key) do
    case DevIDE.Attrs.get(requirements, key) do
      value when value in [nil, ""] -> true
      required -> Map.get(routing, key) == required
    end
  end

  defp tools_requirement_met?(requirements, routing) do
    required = Map.get(requirements, "tools") || Map.get(requirements, :tools) || []
    available = Map.get(routing, "tools", [])

    is_list(required) and Enum.all?(required, &(&1 in available))
  end
end
