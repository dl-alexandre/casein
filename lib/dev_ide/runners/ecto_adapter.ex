defmodule DevIDE.Runners.EctoAdapter do
  @moduledoc "Postgres-backed adapter for the JX runner protocol."

  @behaviour DevIDE.Runners

  import Ecto.Query

  alias DevIDE.Runners.{
    Assignment,
    AssignmentRow,
    ProgressReport,
    ProgressReportRow,
    SafeAction,
    StateMachine
  }

  alias DevIde.Repo

  @impl true
  def create_assignment(%Assignment{} = assignment) do
    assignment
    |> assignment_attrs()
    |> insert_assignment()
  end

  @impl true
  def claim_one(claim) do
    Repo.transaction(fn ->
      workflow_enabled? = "command:workflow:" in claim.safe_action_ids

      query =
        AssignmentRow
        |> where([a], a.status == "queued")
        |> where(
          [a],
          a.safe_action_id in ^claim.safe_action_ids or
            (^workflow_enabled? and like(a.safe_action_id, "command:workflow:%"))
        )
        |> maybe_workspace_filter(claim.workspace_ids)
        |> order_by([a], asc: a.queued_at)
        |> limit(50)
        |> lock("FOR UPDATE SKIP LOCKED")

      case query
           |> Repo.all()
           |> Enum.find(&claimable?(&1, claim)) do
        nil ->
          :none

        row ->
          {:ok, next_status} = StateMachine.transition(row.status, :claim)

          row
          |> Ecto.Changeset.change(%{
            status: next_status,
            claimed_by: claim.runner_id,
            claim_token: claim.claim_token,
            claimed_at: claim.claimed_at,
            lease_expires_at: claim.lease_expires_at
          })
          |> Repo.update!()
          |> to_assignment()
      end
    end)
    |> case do
      {:ok, :none} -> :none
      {:ok, %Assignment{} = assignment} -> {:ok, assignment}
      {:error, _reason} = error -> error
    end
  end

  defp claimable?(row, claim) do
    safe_action_claimable?(row.safe_action_id, claim.safe_action_ids) and
      routing_match?(row.metadata || %{}, claim.routing || %{})
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

  @impl true
  def append_report(assignment_id, claim_token, attrs) do
    Repo.transaction(fn ->
      assignment_id
      |> locked_claimed_assignment(claim_token)
      |> case do
        {:ok, row} ->
          case existing_client_report(row.id, Map.get(attrs, :client_report_id)) do
            %ProgressReport{} = report ->
              if same_report?(report, attrs),
                do: report,
                else: Repo.rollback(:duplicate_report_conflict)

            nil ->
              row
              |> maybe_mark_running(attrs)
              |> build_report(attrs)
              |> insert_report!()
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, %ProgressReport{} = report} -> {:ok, report}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def complete(assignment_id, claim_token, attrs) do
    Repo.transaction(fn ->
      case locked_claimed_assignment(assignment_id, claim_token) do
        {:ok, row} ->
          case existing_client_report(row.id, Map.get(attrs, :client_report_id)) do
            %ProgressReport{} = report ->
              if same_terminal_report?(report, attrs),
                do: {to_assignment(row), report},
                else: Repo.rollback(:duplicate_report_conflict)

            nil ->
              complete_claimed!(row, attrs)
          end

        {:ok_terminal, row} ->
          case existing_client_report(row.id, Map.get(attrs, :client_report_id)) do
            %ProgressReport{} = report ->
              if same_terminal_report?(report, attrs),
                do: {to_assignment(row), report},
                else: Repo.rollback(:duplicate_report_conflict)

            nil ->
              Repo.rollback(:assignment_terminal)
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {%Assignment{} = assignment, %ProgressReport{} = report}} ->
        {:ok, assignment, report}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def expire_leases(%DateTime{} = now) do
    Repo.transaction(fn ->
      AssignmentRow
      |> where([a], a.status in ["claimed", "running"])
      |> where([a], not is_nil(a.lease_expires_at) and a.lease_expires_at <= ^now)
      |> lock("FOR UPDATE")
      |> Repo.all()
      |> Enum.map(&expire_row!(&1, now, "lease expired"))
    end)
    |> case do
      {:ok, assignments} -> assignments
      {:error, _reason} -> []
    end
  end

  @impl true
  def abandon(assignment_id, attrs) do
    Repo.transaction(fn ->
      query =
        AssignmentRow
        |> where([a], a.id == ^assignment_id)
        |> lock("FOR UPDATE")

      case Repo.one(query) do
        nil ->
          Repo.rollback(:not_found)

        row ->
          case StateMachine.transition(row.status, :abandon) do
            {:ok, next_status} ->
              row
              |> Ecto.Changeset.change(%{
                status: next_status,
                completed_at: Map.get(attrs, :completed_at, DateTime.utc_now()),
                failure_reason: Map.get(attrs, :reason),
                evidence: Map.get(attrs, :evidence, %{})
              })
              |> Repo.update!()
              |> to_assignment()

            {:error, reason} ->
              Repo.rollback(reason)
          end
      end
    end)
    |> case do
      {:ok, %Assignment{} = assignment} -> {:ok, assignment}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get_assignment(id) do
    case Repo.get(AssignmentRow, id) do
      nil -> :error
      row -> {:ok, to_assignment(row)}
    end
  end

  @impl true
  def reports_for(assignment_id) do
    ProgressReportRow
    |> where([r], r.assignment_id == ^assignment_id)
    |> order_by([r], asc: r.position)
    |> Repo.all()
    |> Enum.map(&to_report/1)
  end

  @impl true
  def clear do
    Repo.delete_all(ProgressReportRow)
    Repo.delete_all(AssignmentRow)
    :ok
  end

  defp maybe_workspace_filter(query, []), do: query

  defp maybe_workspace_filter(query, workspace_ids),
    do: where(query, [a], a.workspace_id in ^workspace_ids)

  defp locked_claimed_assignment(assignment_id, claim_token) do
    query =
      AssignmentRow
      |> where([a], a.id == ^assignment_id)
      |> lock("FOR UPDATE")

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      %AssignmentRow{status: status, claim_token: ^claim_token} = row
      when status in ["claimed", "running"] ->
        if lease_expired?(row, DateTime.utc_now()), do: {:error, :lease_expired}, else: {:ok, row}

      %AssignmentRow{status: status} = row when status in ["claimed", "running"] ->
        if lease_expired?(row, DateTime.utc_now()),
          do: {:error, :lease_expired},
          else: {:error, :claim_token_invalid}

      %AssignmentRow{status: status, claim_token: ^claim_token} = row
      when status in ["succeeded", "failed", "expired", "abandoned"] ->
        {:ok_terminal, row}

      %AssignmentRow{status: status}
      when status in ["succeeded", "failed", "expired", "abandoned"] ->
        {:error, :assignment_terminal}

      %AssignmentRow{} ->
        {:error, :assignment_not_claimed}
    end
  end

  defp insert_assignment(attrs) do
    %AssignmentRow{}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert()
    |> case do
      {:ok, row} -> {:ok, to_assignment(row)}
      {:error, _} = error -> error
    end
  end

  defp maybe_mark_running(%AssignmentRow{status: "claimed"} = row, attrs) do
    if StateMachine.start_event?(Map.get(attrs, :event)) do
      {:ok, "running"} = StateMachine.transition(row.status, :start)

      row
      |> Ecto.Changeset.change(%{status: "running"})
      |> Repo.update!()
    else
      row
    end
  end

  defp maybe_mark_running(%AssignmentRow{} = row, _attrs), do: row

  defp complete_claimed!(%AssignmentRow{} = row, attrs) do
    event = if attrs.status == "succeeded", do: :succeed, else: :fail

    case StateMachine.transition(row.status, event) do
      {:ok, next_status} ->
        evidence = maybe_put_failure_class(attrs.evidence, Map.get(attrs, :failure_class))

        completed =
          row
          |> Ecto.Changeset.change(%{
            status: next_status,
            completed_at: DateTime.utc_now(),
            failure_reason: attrs.failure_reason,
            evidence: evidence
          })
          |> Repo.update!()

        report =
          completed
          |> build_report(%{
            client_report_id: Map.get(attrs, :client_report_id),
            event: terminal_event(attrs.status),
            message: attrs.message,
            evidence: evidence,
            observed_at: attrs.observed_at
          })
          |> insert_report!()

        {to_assignment(completed), report}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp build_report(%AssignmentRow{} = row, attrs) do
    %ProgressReportRow{
      id: Ecto.UUID.generate(),
      assignment_id: row.id,
      client_report_id: Map.get(attrs, :client_report_id),
      runner_id: row.claimed_by,
      position: next_position(row.id),
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

  defp insert_report!(%ProgressReportRow{} = row) do
    row
    |> Ecto.Changeset.change(%{})
    |> Repo.insert!()
    |> to_report()
  end

  defp next_position(assignment_id) do
    ProgressReportRow
    |> where([r], r.assignment_id == ^assignment_id)
    |> select([r], max(r.position))
    |> Repo.one()
    |> case do
      nil -> 1
      n -> n + 1
    end
  end

  defp existing_client_report(_assignment_id, nil), do: nil
  defp existing_client_report(_assignment_id, ""), do: nil

  defp existing_client_report(assignment_id, client_report_id) do
    ProgressReportRow
    |> where([r], r.assignment_id == ^assignment_id and r.client_report_id == ^client_report_id)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> nil
      row -> to_report(row)
    end
  end

  defp assignment_attrs(%Assignment{} = a) do
    %{
      id: a.id,
      workspace_id: a.workspace_id,
      safe_action_id: a.safe_action_id,
      safe_action_version: a.safe_action_version,
      status: a.status,
      requested_by: a.requested_by,
      claimed_by: a.claimed_by,
      claim_token: a.claim_token,
      queued_at: a.queued_at,
      claimed_at: a.claimed_at,
      lease_expires_at: a.lease_expires_at,
      completed_at: a.completed_at,
      failure_reason: a.failure_reason,
      evidence: a.evidence || %{},
      metadata: a.metadata || %{}
    }
  end

  defp to_assignment(%AssignmentRow{} = r) do
    %Assignment{
      id: r.id,
      workspace_id: r.workspace_id,
      safe_action_id: r.safe_action_id,
      safe_action_version: r.safe_action_version,
      status: r.status,
      requested_by: r.requested_by,
      claimed_by: r.claimed_by,
      claim_token: r.claim_token,
      queued_at: r.queued_at,
      claimed_at: r.claimed_at,
      lease_expires_at: r.lease_expires_at,
      completed_at: r.completed_at,
      failure_reason: r.failure_reason,
      evidence: r.evidence || %{},
      metadata: r.metadata || %{},
      inserted_at: r.inserted_at,
      updated_at: r.updated_at
    }
  end

  defp to_report(%ProgressReportRow{} = r) do
    %ProgressReport{
      id: r.id,
      assignment_id: r.assignment_id,
      client_report_id: r.client_report_id,
      runner_id: r.runner_id,
      position: r.position,
      event: r.event,
      stream: r.stream,
      message: r.message,
      data: r.data,
      data_truncated: r.data_truncated || false,
      evidence: r.evidence || %{},
      observed_at: r.observed_at,
      inserted_at: r.inserted_at
    }
  end

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

  defp lease_expired?(%{lease_expires_at: nil}, _now), do: false

  defp lease_expired?(%{lease_expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) != :gt

  defp expire_row!(%AssignmentRow{} = row, now, reason) do
    {:ok, next_status} = StateMachine.transition(row.status, :expire)

    row
    |> Ecto.Changeset.change(%{
      status: next_status,
      completed_at: now,
      failure_reason: reason,
      evidence: %{"failure_class" => "lease_expired"}
    })
    |> Repo.update!()
    |> to_assignment()
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
