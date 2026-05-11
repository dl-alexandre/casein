defmodule DevIDE.Runners do
  @moduledoc """
  JX runner execution protocol v1.

  The protocol is pull/report oriented:

    * DevIDE enqueues assignments internally after policy and safe-action
      checks.
    * Durable runners poll for one compatible assignment and receive a claim
      token.
    * Runners append progress reports and complete/fail only their claimed
      assignment.
    * Replay uses the persisted assignment plus append-only reports.

  The public HTTP API is intentionally missing an assignment-create endpoint.
  Runner requests can claim and report work, but cannot introduce new argv,
  shell strings, HTTP proxy targets, or DevIDE workspace mutations.
  """

  alias DevIDE.Policy
  alias DevIDE.Policy.Decision
  alias DevIDE.Runners.{Assignment, Failure, ProgressReport, SafeAction, StateMachine}
  alias DevIDE.Runs.Ledger
  alias DevIDE.Runtimes
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.WorkspaceRecord

  @protocol "jx.runner.v1"
  @default_lease_ms 15 * 60 * 1000
  @data_cap 32 * 1024
  @message_cap 8 * 1024
  @allowed_report_events ~w(started progress stdout stderr heartbeat evidence)
  @forbidden_payload_keys ~w(argv command cmd shell executable url uri method headers body request proxy http)

  @callback create_assignment(Assignment.t()) :: {:ok, Assignment.t()} | {:error, term()}
  @callback claim_one(map()) :: {:ok, Assignment.t()} | :none | {:error, term()}
  @callback append_report(String.t(), String.t(), map()) ::
              {:ok, ProgressReport.t()} | {:error, term()}
  @callback complete(String.t(), String.t(), map()) ::
              {:ok, Assignment.t(), ProgressReport.t()} | {:error, term()}
  @callback expire_leases(DateTime.t()) :: [Assignment.t()]
  @callback abandon(String.t(), map()) :: {:ok, Assignment.t()} | {:error, term()}
  @callback get_assignment(String.t()) :: {:ok, Assignment.t()} | :error
  @callback reports_for(String.t()) :: [ProgressReport.t()]
  @callback clear() :: :ok

  @spec protocol() :: String.t()
  def protocol, do: @protocol

  def failure_classes, do: Failure.classes()
  def status_values, do: StateMachine.statuses()

  @spec enqueue_command(String.t(), String.t(), keyword()) ::
          {:ok, Assignment.t()} | {:error, term()}
  def enqueue_command(workspace_id, command_id, opts \\ []) do
    case SafeAction.fetch_command(command_id) do
      {:ok, action} -> enqueue(workspace_id, action.id, opts)
      :error -> {:error, :safe_action_not_allowed}
    end
  end

  @spec enqueue(String.t(), String.t(), keyword()) :: {:ok, Assignment.t()} | {:error, term()}
  def enqueue(workspace_id, safe_action_id, opts \\ [])

  def enqueue(workspace_id, safe_action_id, opts)
      when is_binary(workspace_id) and is_binary(safe_action_id) and is_list(opts) do
    with {:ok, %SafeAction{} = action} <- fetch_action(safe_action_id),
         {:ok, %WorkspaceRecord{} = record} <- fetch_workspace(workspace_id),
         %Decision{} = decision <- policy_decision(record, action) do
      run_id = metadata_value(opts, "run_id") || Ledger.new_run_id()
      opts = Keyword.put(opts, :metadata, assignment_metadata(opts, action, run_id))

      with :ok <- audit_enqueue_decision(decision, record, action, opts),
           true <- Decision.allow?(decision),
           :ok <- reject_forbidden_payload(Map.new(opts)),
           {:ok, metadata} <-
             Runtimes.place_assignment(record, Keyword.get(opts, :metadata, %{})) do
        assignment = %Assignment{
          id: Ecto.UUID.generate(),
          workspace_id: workspace_id,
          safe_action_id: action.id,
          safe_action_version: action.version,
          status: "queued",
          requested_by: Keyword.get(opts, :requested_by, "jx"),
          queued_at: Keyword.get(opts, :queued_at, DateTime.utc_now()),
          metadata: metadata
        }

        case impl().create_assignment(assignment) do
          {:ok, %Assignment{} = created} = ok ->
            _ = Ledger.run_queued(decision, created, %{actor_id: created.requested_by})
            ok

          {:error, _reason} = error ->
            error
        end
      end
    else
      :error -> {:error, :not_found}
      false -> {:error, {:policy_denied, :runner_assignment}}
      {:error, _reason} = error -> error
    end
  end

  def enqueue(_workspace_id, _safe_action_id, _opts), do: {:error, :invalid_attrs}

  @spec poll(map()) :: {:ok, map()} | :none | {:error, term()}
  def poll(attrs) when is_map(attrs) do
    with :ok <- validate_protocol(attrs),
         {:ok, runner_id} <- fetch_nonempty(attrs, "runner_id"),
         {:ok, capabilities} <- fetch_string_list(attrs, "capabilities"),
         {:ok, workspace_ids} <- optional_string_list(attrs, "workspace_ids"),
         true <- capabilities != [] || {:error, :capabilities_required},
         safe_action_ids when safe_action_ids != [] <- SafeAction.compatible_ids(capabilities) do
      claim = %{
        runner_id: runner_id,
        capabilities: capabilities,
        workspace_ids: workspace_ids,
        routing: routing_claim(attrs, capabilities),
        safe_action_ids: safe_action_ids,
        claim_token: Ecto.UUID.generate(),
        claimed_at: DateTime.utc_now(),
        lease_expires_at: DateTime.add(DateTime.utc_now(), default_lease_ms(), :millisecond)
      }

      case impl().claim_one(claim) do
        {:ok, %Assignment{} = assignment} ->
          activate_runtime(assignment, runner_id)
          Ledger.assignment_claimed(assignment, runner_id)
          {:ok, assignment_payload(assignment, include_claim_token: true)}

        :none ->
          :none

        {:error, _reason} = error ->
          error
      end
    else
      [] -> :none
      {:error, _reason} = error -> error
    end
  end

  def poll(_), do: {:error, :invalid_attrs}

  @spec append_report(String.t(), map()) :: {:ok, ProgressReport.t()} | {:error, term()}
  def append_report(assignment_id, attrs) when is_binary(assignment_id) and is_map(attrs) do
    with {:ok, claim_token} <- fetch_nonempty(attrs, "claim_token"),
         {:ok, event} <- fetch_nonempty(attrs, "event"),
         true <- event in @allowed_report_events || {:error, :event_not_allowed},
         :ok <- reject_forbidden_payload(attrs),
         {:ok, report_attrs} <- report_attrs(attrs, event) do
      case impl().append_report(assignment_id, claim_token, report_attrs) do
        {:ok, %ProgressReport{} = report} ->
          heartbeat_runtime(assignment_id, report_attrs)
          {:ok, report}

        {:error, _reason} = error ->
          error
      end
    end
  end

  def append_report(_assignment_id, _attrs), do: {:error, :invalid_attrs}

  @spec complete(String.t(), map()) ::
          {:ok, Assignment.t(), ProgressReport.t()} | {:error, term()}
  def complete(assignment_id, attrs), do: terminal(assignment_id, attrs, "succeeded")

  @spec fail(String.t(), map()) ::
          {:ok, Assignment.t(), ProgressReport.t()} | {:error, term()}
  def fail(assignment_id, attrs), do: terminal(assignment_id, attrs, "failed")

  @spec expire_leases(DateTime.t()) :: [Assignment.t()]
  def expire_leases(%DateTime{} = now) do
    impl().expire_leases(now)
    |> Enum.map(fn %Assignment{} = assignment ->
      release_runtime(assignment, "lease_expired")
      Ledger.assignment_terminal(assignment, assignment.claimed_by || "lease_expiry")
      assignment
    end)
  end

  @spec abandon(String.t(), map()) :: {:ok, Assignment.t()} | {:error, term()}
  def abandon(assignment_id, attrs \\ %{})

  def abandon(assignment_id, attrs) when is_binary(assignment_id) and is_map(attrs) do
    with {:ok, reason} <- optional_binary(attrs, "reason"),
         :ok <- reject_forbidden_payload(attrs) do
      case impl().abandon(assignment_id, %{
             reason: reason,
             evidence: %{"failure_class" => "runner_lost"},
             completed_at: DateTime.utc_now()
           }) do
        {:ok, %Assignment{} = assignment} ->
          release_runtime(assignment, "runner_lost")

          Ledger.assignment_terminal(
            assignment,
            Map.get(attrs, "actor_id") || assignment.claimed_by
          )

          {:ok, assignment}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @spec replay(String.t()) :: {:ok, map()} | :error
  def replay(assignment_id) when is_binary(assignment_id) do
    case impl().get_assignment(assignment_id) do
      {:ok, %Assignment{} = assignment} ->
        {:ok,
         %{
           protocol: @protocol,
           assignment: assignment_payload(assignment),
           reports: Enum.map(impl().reports_for(assignment_id), &report_payload/1)
         }}

      :error ->
        :error
    end
  end

  def replay(_), do: :error

  def clear, do: impl().clear()

  @spec assignment_payload(Assignment.t(), keyword()) :: map()
  def assignment_payload(%Assignment{} = assignment, opts \\ []) do
    action =
      case SafeAction.fetch(assignment.safe_action_id) do
        {:ok, safe_action} -> SafeAction.to_runner_payload(safe_action)
        :error -> %{id: assignment.safe_action_id, unavailable: true}
      end

    metadata = Runtimes.decorate_assignment_metadata(assignment.metadata || %{})

    %{
      id: assignment.id,
      workspace_id: assignment.workspace_id,
      safe_action_id: assignment.safe_action_id,
      safe_action_version: assignment.safe_action_version,
      action: action,
      status: assignment.status,
      requested_by: assignment.requested_by,
      claimed_by: assignment.claimed_by,
      queued_at: iso(assignment.queued_at),
      claimed_at: iso(assignment.claimed_at),
      lease_expires_at: iso(assignment.lease_expires_at),
      completed_at: iso(assignment.completed_at),
      failure_reason: assignment.failure_reason,
      failure_class: failure_class(assignment),
      evidence: assignment.evidence || %{},
      metadata: metadata
    }
    |> maybe_put_claim_token(assignment, Keyword.get(opts, :include_claim_token, false))
  end

  @spec report_payload(ProgressReport.t()) :: map()
  def report_payload(%ProgressReport{} = report) do
    %{
      id: report.id,
      assignment_id: report.assignment_id,
      client_report_id: report.client_report_id,
      runner_id: report.runner_id,
      position: report.position,
      event: report.event,
      stream: report.stream,
      message: report.message,
      data: report.data,
      data_truncated: report.data_truncated,
      evidence: report.evidence || %{},
      failure_class: failure_class(report),
      observed_at: iso(report.observed_at),
      inserted_at: iso(report.inserted_at)
    }
  end

  defp terminal(assignment_id, attrs, status) when is_binary(assignment_id) and is_map(attrs) do
    with {:ok, claim_token} <- fetch_nonempty(attrs, "claim_token"),
         {:ok, evidence} <- terminal_evidence(attrs),
         :ok <- reject_forbidden_payload(attrs) do
      terminal_attrs = %{
        status: status,
        client_report_id: client_report_id(attrs),
        evidence: evidence,
        message: string_value(attrs, "message"),
        failure_reason: if(status == "failed", do: string_value(attrs, "reason"), else: nil),
        failure_class: terminal_failure_class(attrs, status),
        observed_at: observed_at(attrs)
      }

      case impl().complete(assignment_id, claim_token, terminal_attrs) do
        {:ok, %Assignment{} = assignment, %ProgressReport{} = report} ->
          release_runtime(assignment, status)
          Ledger.assignment_terminal(assignment, report.runner_id)
          {:ok, assignment, report}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp terminal(_assignment_id, _attrs, _status), do: {:error, :invalid_attrs}

  defp report_attrs(attrs, event) do
    with {:ok, evidence} <- optional_map(attrs, "evidence"),
         {:ok, data, data_truncated} <- capped_optional_binary(attrs, "data", @data_cap),
         {:ok, message, _} <- capped_optional_binary(attrs, "message", @message_cap) do
      {:ok,
       %{
         client_report_id: client_report_id(attrs),
         event: event,
         stream: stream_for(attrs, event),
         message: message,
         data: data,
         data_truncated: data_truncated,
         evidence: evidence,
         observed_at: observed_at(attrs)
       }}
    end
  end

  defp terminal_evidence(attrs) do
    case optional_map(attrs, "evidence") do
      {:ok, evidence} when map_size(evidence) > 0 -> {:ok, evidence}
      {:ok, _} -> {:error, :evidence_required}
      {:error, _} = error -> error
    end
  end

  defp terminal_failure_class(attrs, status) do
    string_value(attrs, "failure_class") || Failure.terminal_class(status)
  end

  defp metadata_value(opts, key) do
    opts
    |> Keyword.get(:metadata, %{})
    |> value(key)
  end

  defp assignment_metadata(opts, %SafeAction{} = action, run_id) do
    opts
    |> Keyword.get(:metadata, %{})
    |> case do
      metadata when is_map(metadata) -> metadata
      _ -> %{}
    end
    |> Map.put_new(:protocol, @protocol)
    |> Map.put_new(:command_id, action.command_id)
    |> Map.put_new(:safe_action_id, action.id)
    |> Map.put(:run_id, run_id)
  end

  defp stream_for(attrs, event) do
    case string_value(attrs, "stream") do
      stream when stream in ["stdout", "stderr"] -> stream
      _ when event in ["stdout", "stderr"] -> event
      _ -> nil
    end
  end

  defp client_report_id(attrs) do
    first_present([
      string_value(attrs, "client_report_id"),
      string_value(attrs, "report_id"),
      string_value(attrs, "idempotency_key")
    ])
  end

  defp fetch_action(safe_action_id) do
    case SafeAction.fetch(safe_action_id) do
      {:ok, _action} = ok -> ok
      :error -> {:error, :safe_action_not_allowed}
    end
  end

  defp fetch_workspace(workspace_id) do
    case State.get(workspace_id) do
      {:ok, _record} = ok -> ok
      :error -> {:error, :not_found}
    end
  end

  defp policy_decision(
         %WorkspaceRecord{} = record,
         %SafeAction{kind: :workspace_command} = action
       ) do
    Policy.can_run_command?(%{
      workspace_id: record.external_id,
      command_id: action.command_id,
      db_isolation: db_isolation(record.db_isolation),
      actor_type: :jx
    })
  end

  defp audit_enqueue_decision(%Decision{} = decision, %WorkspaceRecord{} = record, action, opts) do
    attrs = %{
      workspace_id: record.external_id,
      actor_id: Keyword.get(opts, :requested_by, "jx"),
      command_id: action.command_id,
      command_line: metadata_value(opts, "command_line") || action.command_id,
      run_id: metadata_value(opts, "run_id"),
      plane: "governed",
      metadata:
        Map.merge(Keyword.get(opts, :metadata, %{}), %{
          protocol: @protocol,
          safe_action_id: action.id,
          db_isolation: record.db_isolation || "unknown"
        })
    }

    _ =
      if Decision.allow?(decision) do
        Ledger.command_requested(attrs)
      else
        Ledger.command_denied(decision, attrs)
      end

    if Decision.allow?(decision), do: :ok, else: {:error, decision.reason}
  end

  defp validate_protocol(attrs) do
    case value(attrs, "protocol") do
      nil -> :ok
      @protocol -> :ok
      _ -> {:error, :protocol_not_supported}
    end
  end

  defp fetch_nonempty(attrs, key) do
    case string_value(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, String.to_atom("#{key}_required")}
    end
  end

  defp fetch_string_list(attrs, key) do
    case value(attrs, key) do
      list when is_list(list) ->
        if list != [] and Enum.all?(list, &valid_string?/1) do
          {:ok, Enum.map(list, &String.trim/1)}
        else
          {:error, String.to_atom("#{key}_required")}
        end

      _ ->
        {:error, String.to_atom("#{key}_required")}
    end
  end

  defp optional_string_list(attrs, key) do
    case value(attrs, key) do
      nil ->
        {:ok, []}

      list when is_list(list) ->
        if Enum.all?(list, &valid_string?/1) do
          {:ok, Enum.map(list, &String.trim/1)}
        else
          {:error, String.to_atom("#{key}_invalid")}
        end

      _ ->
        {:error, String.to_atom("#{key}_invalid")}
    end
  end

  defp optional_map(attrs, key) do
    case value(attrs, key) do
      nil -> {:ok, %{}}
      map when is_map(map) -> {:ok, map}
      _ -> {:error, String.to_atom("#{key}_invalid")}
    end
  end

  defp optional_binary(attrs, key) do
    case value(attrs, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, String.trim(value)}
      _ -> {:error, String.to_atom("#{key}_invalid")}
    end
  end

  defp capped_optional_binary(attrs, key, cap) do
    case value(attrs, key) do
      nil ->
        {:ok, nil, false}

      value when is_binary(value) and byte_size(value) <= cap ->
        {:ok, value, false}

      value when is_binary(value) ->
        drop = byte_size(value) - cap
        <<_::binary-size(drop), tail::binary>> = value
        {:ok, "[...truncated]\n" <> tail, true}

      _ ->
        {:error, String.to_atom("#{key}_invalid")}
    end
  end

  defp observed_at(attrs) do
    case string_value(attrs, "observed_at") do
      nil ->
        DateTime.utc_now()

      value ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _offset} -> dt
          _ -> DateTime.utc_now()
        end
    end
  end

  defp routing_claim(attrs, capabilities) do
    %{
      "host" => string_value(attrs, "host"),
      "os" => string_value(attrs, "os"),
      "repo" => string_value(attrs, "repo"),
      "branch_isolation" => string_value(attrs, "branch_isolation"),
      "runtime_id" => string_value(attrs, "runtime_id"),
      "runtime_path" => string_value(attrs, "runtime_path"),
      "tools" => list_or_capability_suffixes(attrs, "tools", "tool:", capabilities),
      "active_assignments" => integer_value(attrs, "active_assignments", 0),
      "concurrency_limit" => integer_value(attrs, "concurrency_limit", 1)
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  defp list_or_capability_suffixes(attrs, key, prefix, capabilities) do
    case value(attrs, key) do
      list when is_list(list) ->
        list
        |> Enum.filter(&valid_string?/1)
        |> Enum.map(&String.trim/1)

      _ ->
        capabilities
        |> Enum.filter(&String.starts_with?(&1, prefix))
        |> Enum.map(&String.replace_prefix(&1, prefix, ""))
    end
  end

  defp integer_value(attrs, key, fallback) do
    case value(attrs, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> fallback
        end

      _ ->
        fallback
    end
  end

  defp activate_runtime(%Assignment{} = assignment, runner_id) do
    case Runtimes.runtime_id_from_metadata(assignment.metadata || %{}) do
      runtime_id when is_binary(runtime_id) ->
        _ =
          Runtimes.mark_active(runtime_id, %{
            "assignment_id" => assignment.id,
            "runner_id" => runner_id,
            "actor_id" => runner_id
          })

        :ok

      _ ->
        :ok
    end
  end

  defp heartbeat_runtime(assignment_id, attrs) do
    case impl().get_assignment(assignment_id) do
      {:ok, %Assignment{} = assignment} ->
        case Runtimes.runtime_id_from_metadata(assignment.metadata || %{}) do
          runtime_id when is_binary(runtime_id) ->
            runtime_attrs = %{
              "assignment_id" => assignment.id,
              "runner_id" => assignment.claimed_by,
              "actor_id" => assignment.claimed_by
            }

            _ =
              if StateMachine.start_event?(Map.get(attrs, :event)) do
                Runtimes.mark_active(runtime_id, runtime_attrs)
              else
                Runtimes.heartbeat(runtime_id, runtime_attrs)
              end

            :ok

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp release_runtime(%Assignment{} = assignment, reason) do
    case Runtimes.runtime_id_from_metadata(assignment.metadata || %{}) do
      runtime_id when is_binary(runtime_id) ->
        _ =
          Runtimes.mark_idle(runtime_id, %{
            "assignment_id" => assignment.id,
            "runner_id" => assignment.claimed_by,
            "actor_id" => assignment.claimed_by || reason
          })

        :ok

      _ ->
        :ok
    end
  end

  defp failure_class(%Assignment{} = assignment) do
    metadata_failure =
      assignment.metadata
      |> Map.get("failure_class")
      |> case do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end

    metadata_failure ||
      get_in(assignment.evidence || %{}, ["failure_class"]) ||
      if(assignment.status == "failed", do: "action_failed")
  end

  defp failure_class(%ProgressReport{} = report) do
    get_in(report.evidence || %{}, ["failure_class"]) ||
      if(report.event == "failed", do: "action_failed")
  end

  defp reject_forbidden_payload(map) when is_map(map) do
    if forbidden_key_present?(map), do: {:error, :forbidden_payload}, else: :ok
  end

  defp reject_forbidden_payload(nil), do: :ok
  defp reject_forbidden_payload(_), do: {:error, :invalid_payload}

  defp forbidden_key_present?(map) when is_map(map) do
    Enum.any?(map, fn {key, value} ->
      normalized = key |> to_string() |> String.downcase()
      normalized in @forbidden_payload_keys or forbidden_key_present?(value)
    end)
  end

  defp forbidden_key_present?(list) when is_list(list),
    do: Enum.any?(list, &forbidden_key_present?/1)

  defp forbidden_key_present?(_), do: false

  defp string_value(attrs, key) do
    case value(attrs, key) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp value(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))
  end

  defp valid_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp first_present(values) do
    Enum.find(values, fn value -> value not in [nil, ""] end)
  end

  defp maybe_put_claim_token(payload, %Assignment{} = assignment, true),
    do: Map.put(payload, :claim_token, assignment.claim_token)

  defp maybe_put_claim_token(payload, _assignment, _), do: payload

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(_), do: nil

  defp default_lease_ms,
    do: Application.get_env(:dev_ide, :runner_assignment_lease_ms, @default_lease_ms)

  defp db_isolation("shared_stage"), do: :shared_stage
  defp db_isolation("unsafe"), do: :unsafe
  defp db_isolation("ephemeral"), do: :ephemeral
  defp db_isolation("local"), do: :local
  defp db_isolation(_value), do: :unknown

  defp impl,
    do: Application.get_env(:dev_ide, :runner_protocol_adapter, DevIDE.Runners.MemoryAdapter)
end
