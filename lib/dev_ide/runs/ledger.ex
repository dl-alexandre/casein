defmodule DevIDE.Runs.Ledger do
  @moduledoc """
  Canonical event ledger for operational execution.

  The backing store is `DevIDE.Audit`; this module owns the normalized run
  vocabulary on top of it:

    * Session — interactive raw terminal attachment.
    * Run — execution lifecycle for a command.

  This keeps audit as the durable event stream while preventing terminal and
  run surfaces from inventing incompatible event shapes.
  """

  alias DevIDE.Audit
  alias DevIDE.Audit.Event
  alias DevIDE.Policy.Decision
  alias DevIDE.Runs.Status

  @ledger "run"
  @version 1

  # Every ledger event's action is emitted under this prefix (see action/1),
  # so readers can pull just the run family via the [action, inserted_at]
  # index rather than scanning the whole workspace audit stream.
  @run_action_prefix "run."

  @type noun :: :session | :run
  @type event_name ::
          :session_attached
          | :session_denied
          | :run_started
          | :run_succeeded
          | :run_failed
          | :run_timed_out
          | :approval_requested
          | :approval_granted
          | :approval_denied

  @spec new_run_id() :: String.t()
  def new_run_id, do: Ecto.UUID.generate()

  @spec run_started(map()) :: Event.t() | nil
  def run_started(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.put_new(:decision, :allow)
      |> put_meta(:status, "running")

    emit(:run_started, :run, attrs)
  end

  @spec run_finished(atom() | String.t(), map()) :: Event.t() | nil
  def run_finished(status, attrs) when is_map(attrs) do
    name =
      case Status.normalize(status) do
        "succeeded" -> :run_succeeded
        "timed_out" -> :run_timed_out
        _ -> :run_failed
      end

    attrs =
      attrs
      |> Map.put_new(:decision, :allow)
      |> put_meta(:status, status)

    emit(name, :run, attrs)
  end

  @spec approval_requested(map()) :: Event.t() | nil
  def approval_requested(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.put_new(:decision, :allow)
      |> put_meta(:approval_status, "requested")

    emit(:approval_requested, :run, attrs)
  end

  @spec approval_granted(map()) :: Event.t() | nil
  def approval_granted(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.put_new(:decision, :allow)
      |> put_meta(:approval_status, "granted")

    emit(:approval_granted, :run, attrs)
  end

  @spec approval_denied(map()) :: Event.t() | nil
  def approval_denied(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.put_new(:decision, :deny)
      |> put_meta(:approval_status, "denied")

    emit(:approval_denied, :run, attrs)
  end

  @spec raw_session_attached(Decision.t(), map()) :: Event.t() | nil
  def raw_session_attached(%Decision{} = decision, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.put(:decision, decision.verdict)
      |> Map.put(:reason, decision.reason)
      |> put_meta(:policy_mode, decision.mode)
      |> put_meta(:plane, "raw")

    name = if decision.verdict == :allow, do: :session_attached, else: :session_denied

    emit(name, :session, attrs)
  end

  @spec recent_runs_for(String.t(), pos_integer()) :: [map()]
  def recent_runs_for(workspace_id, limit \\ 20) do
    workspace_id
    |> recent_for(max(limit * 20, 100))
    |> Enum.filter(&run_scoped_event?/1)
    |> Enum.group_by(&run_ref/1)
    |> Enum.reject(fn {run_id, _events} -> run_id in [nil, ""] end)
    |> Enum.map(fn {run_id, events} -> run_summary(run_id, events) end)
    |> Enum.sort_by(& &1.last_event_at, {:desc, DateTime})
    |> Enum.take(limit)
    |> Enum.map(&Map.drop(&1, [:last_event_at]))
  end

  @spec timeline_for(String.t(), String.t()) :: [Event.t()]
  def timeline_for(workspace_id, run_id) when is_binary(workspace_id) and is_binary(run_id) do
    workspace_id
    |> recent_for(500)
    |> Enum.filter(&(run_ref(&1) == run_id))
    |> Enum.reverse()
  end

  @spec summary_for(String.t(), String.t()) :: {:ok, map()} | :error
  def summary_for(workspace_id, run_id) when is_binary(workspace_id) and is_binary(run_id) do
    case timeline_for(workspace_id, run_id) do
      [] -> :error
      events -> {:ok, run_id |> run_summary(events) |> Map.drop([:last_event_at])}
    end
  end

  @spec recent_for(String.t(), pos_integer()) :: [Event.t()]
  def recent_for(workspace_id, limit \\ 50) do
    # The action-prefix fetch already returns only run.* rows via the
    # [action, inserted_at] index, so there is no dilution to over-fetch
    # around; ledger_event?/1 stays as the precise (metadata) gate.
    workspace_id
    |> Audit.recent_with_action_prefix(@run_action_prefix, limit)
    |> Enum.filter(&ledger_event?/1)
    |> Enum.take(limit)
  end

  @spec ledger_event?(Event.t()) :: boolean()
  def ledger_event?(%Event{metadata: metadata}) do
    meta(metadata, "ledger") == @ledger and meta(metadata, "ledger_version") == @version
  end

  def ledger_event?(_), do: false

  defp emit(name, noun, attrs) do
    Audit.emit!(
      attrs
      |> Map.take([:workspace_id, :actor_id, :decision, :reason])
      |> Map.put(:action, action(name))
      |> Map.put(:target_type, Atom.to_string(noun))
      |> Map.put(:target_ref, target_ref(noun, attrs))
      |> Map.put(:metadata, metadata(name, noun, attrs))
    )
  end

  defp metadata(name, noun, attrs) do
    attrs
    |> Map.get(:metadata, %{})
    |> stringify_keys()
    |> Map.merge(%{
      "ledger" => @ledger,
      "ledger_version" => @version,
      "event" => Atom.to_string(name),
      "noun" => Atom.to_string(noun)
    })
    |> maybe_put("session_id", Map.get(attrs, :session_id))
    |> maybe_put("command_id", Map.get(attrs, :command_id))
    |> maybe_put("command_line", Map.get(attrs, :command_line))
    |> maybe_put("run_id", Map.get(attrs, :run_id))
    |> maybe_put("plane", Map.get(attrs, :plane))
  end

  defp action(:session_attached), do: "run.session_attached"
  defp action(:session_denied), do: "run.session_denied"
  defp action(:run_started), do: "run.started"
  defp action(:run_succeeded), do: "run.succeeded"
  defp action(:run_failed), do: "run.failed"
  defp action(:run_timed_out), do: "run.timed_out"
  defp action(:approval_requested), do: "run.approval_requested"
  defp action(:approval_granted), do: "run.approval_granted"
  defp action(:approval_denied), do: "run.approval_denied"

  defp target_ref(:session, attrs), do: Map.get(attrs, :session_id) || Map.get(attrs, :run_id)

  defp target_ref(:run, attrs),
    do: Map.get(attrs, :run_id) || meta(Map.get(attrs, :metadata, %{}), "run_id")

  defp run_scoped_event?(%Event{} = event) do
    event.action in [
      "run.started",
      "run.succeeded",
      "run.failed",
      "run.timed_out",
      "run.approval_requested",
      "run.approval_granted",
      "run.approval_denied"
    ]
  end

  defp run_ref(%Event{target_type: "run", target_ref: run_id}) when is_binary(run_id),
    do: run_id

  defp run_ref(%Event{metadata: metadata}), do: meta(metadata, "run_id")

  defp run_summary(run_id, events) do
    latest =
      events
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
      |> List.first()

    metadata = merged_metadata(events)

    %{
      id: run_id,
      command_id: meta(metadata, "command_id"),
      status: run_status(events),
      exit_code: meta(metadata, "exit_code"),
      assignment_id: meta(metadata, "assignment_id"),
      safe_action_id: meta(metadata, "safe_action_id"),
      protocol: meta(metadata, "protocol"),
      source: meta(metadata, "source"),
      trigger: meta(metadata, "trigger"),
      plane: meta(metadata, "plane"),
      requested_at: event_time(events, ["run.started"]),
      started_at: event_time(events, ["run.started"]),
      finished_at:
        event_time(events, [
          "run.succeeded",
          "run.failed",
          "run.timed_out",
          "run.approval_denied"
        ]),
      last_event_at: latest.inserted_at
    }
    |> drop_nil_values()
    |> stringify_datetimes([:requested_at, :started_at, :finished_at])
  end

  defp merged_metadata(events) do
    events
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn %Event{metadata: metadata}, acc ->
      Map.merge(acc, stringify_keys(metadata || %{}))
    end)
  end

  defp run_status(events) do
    events
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> Enum.map(&status_for_action/1)
    |> Enum.find(& &1)
  end

  defp status_for_action(%Event{action: "run.succeeded"}), do: "succeeded"
  defp status_for_action(%Event{action: "run.failed"}), do: "failed"
  defp status_for_action(%Event{action: "run.timed_out"}), do: "timed_out"
  defp status_for_action(%Event{action: "run.approval_denied"}), do: "approval_denied"
  defp status_for_action(%Event{action: "run.started"}), do: "running"
  defp status_for_action(%Event{action: "run.approval_requested"}), do: "approval_requested"
  defp status_for_action(%Event{action: "run.approval_granted"}), do: "approval_granted"
  defp status_for_action(_), do: nil

  defp event_time(events, actions) do
    events
    |> Enum.filter(&(&1.action in actions))
    |> Enum.sort_by(& &1.inserted_at, DateTime)
    |> List.first()
    |> case do
      %Event{inserted_at: inserted_at} -> inserted_at
      _ -> nil
    end
  end

  defp drop_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp stringify_datetimes(map, keys) do
    Enum.reduce(keys, map, fn key, acc ->
      case Map.get(acc, key) do
        %DateTime{} = value -> Map.put(acc, key, DateTime.to_iso8601(value))
        _ -> acc
      end
    end)
  end

  defp put_meta(attrs, key, value),
    do: update_meta(attrs, &maybe_put(&1, Atom.to_string(key), value))

  defp update_meta(attrs, fun) do
    Map.update(attrs, :metadata, fun.(%{}), fun)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_keys(_), do: %{}

  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map

  defp maybe_put(map, key, value) when is_atom(value),
    do: Map.put(map, key, Atom.to_string(value))

  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp meta(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp meta(_, _), do: nil
end
