defmodule DevIDE.Fleet.Approvals do
  @moduledoc """
  Approval gates for risky operator actions.

  Approvals are recorded in the run ledger (`DevIDE.Runs.Ledger`) so the audit
  log remains the durable record. This module only interprets those audit
  events and does not own independent state.
  """

  alias DevIDE.Audit
  alias DevIDE.Audit.Event
  alias DevIDE.Runs.Ledger

  @type target :: %{
          required(:type) => String.t(),
          required(:ref) => String.t(),
          optional(:workspace_id) => String.t()
        }

  @type approval :: %{
          id: String.t(),
          status: String.t(),
          action: String.t(),
          target_type: String.t(),
          target_ref: String.t(),
          workspace_id: String.t() | nil,
          actor_id: String.t() | nil,
          event: Event.t()
        }

  @spec request(atom() | String.t(), map(), keyword()) ::
          {:ok, approval()} | {:error, term()}
  def request(action, target, opts \\ []) do
    with {:ok, target} <- normalize_target(target),
         action <- action_key(action) do
      approval_id = Keyword.get(opts, :approval_id) || Ecto.UUID.generate()

      metadata =
        opts
        |> Keyword.get(:metadata, %{})
        |> stringify_keys()
        |> Map.merge(%{
          "approval_id" => approval_id,
          "approval_action" => action,
          "approval_target_type" => target.type,
          "approval_target_ref" => target.ref
        })
        |> maybe_put("approval_reason", Keyword.get(opts, :reason))

      %{
        workspace_id: target.workspace_id,
        actor_id: Keyword.get(opts, :actor_id, "operator"),
        run_id: approval_id,
        metadata: metadata
      }
      |> Ledger.approval_requested()
      |> event_result()
    end
  end

  @spec grant(String.t(), keyword()) :: {:ok, approval()} | {:error, term()}
  def grant(approval_id, opts \\ [])

  def grant(approval_id, opts) when is_binary(approval_id) do
    with {:ok, request} <- request_event(approval_id) do
      metadata =
        request.metadata
        |> stringify_keys()
        |> Map.put("approval_id", approval_id)
        |> Map.put("approved_by", Keyword.get(opts, :actor_id, "operator"))
        |> maybe_put("approval_decision_reason", Keyword.get(opts, :reason))

      %{
        workspace_id: request.workspace_id,
        actor_id: Keyword.get(opts, :actor_id, "operator"),
        run_id: approval_id,
        metadata: metadata
      }
      |> Ledger.approval_granted()
      |> event_result()
    end
  end

  def grant(_approval_id, _opts), do: {:error, :invalid_approval_id}

  @spec deny(String.t(), keyword()) :: {:ok, approval()} | {:error, term()}
  def deny(approval_id, opts \\ [])

  def deny(approval_id, opts) when is_binary(approval_id) do
    with {:ok, request} <- request_event(approval_id) do
      metadata =
        request.metadata
        |> stringify_keys()
        |> Map.put("approval_id", approval_id)
        |> Map.put("denied_by", Keyword.get(opts, :actor_id, "operator"))
        |> maybe_put("approval_decision_reason", Keyword.get(opts, :reason))

      %{
        workspace_id: request.workspace_id,
        actor_id: Keyword.get(opts, :actor_id, "operator"),
        run_id: approval_id,
        reason: Keyword.get(opts, :reason),
        metadata: metadata
      }
      |> Ledger.approval_denied()
      |> event_result()
    end
  end

  def deny(_approval_id, _opts), do: {:error, :invalid_approval_id}

  @spec require_granted(String.t() | nil, atom() | String.t(), String.t()) ::
          {:ok, approval()} | {:error, term()}
  def require_granted(approval_id, action, target_ref)

  def require_granted(approval_id, _action, _target_ref) when approval_id in [nil, ""],
    do: {:error, :approval_required}

  def require_granted(approval_id, action, target_ref)
      when is_binary(approval_id) and is_binary(target_ref) do
    expected_action = action_key(action)

    with {:ok, approval} <- current_decision(approval_id) do
      cond do
        approval.status == "denied" ->
          {:error, :approval_denied}

        approval.status != "granted" ->
          {:error, :approval_required}

        approval.action != expected_action ->
          {:error, :approval_mismatch}

        approval.target_ref != target_ref ->
          {:error, :approval_mismatch}

        true ->
          {:ok, approval}
      end
    end
  end

  def require_granted(_approval_id, _action, _target_ref), do: {:error, :invalid_approval}

  @spec list(keyword()) :: [approval()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 1_000)

    Audit.list(limit: limit)
    |> Enum.filter(&approval_event?/1)
    |> Enum.map(&event_to_approval/1)
  end

  @spec action_key(atom() | String.t()) :: String.t()
  def action_key(action) when is_atom(action), do: Atom.to_string(action)
  def action_key(action) when is_binary(action), do: action
  def action_key(action), do: inspect(action)

  defp normalize_target(target) when is_map(target) do
    target_type =
      metadata_value(target, "type") || metadata_value(target, "target_type") || "assignment"

    target_ref =
      metadata_value(target, "ref") ||
        metadata_value(target, "target_ref") ||
        metadata_value(target, "assignment_id")

    workspace_id = metadata_value(target, "workspace_id")

    if is_binary(target_ref) and target_ref != "" do
      {:ok, %{type: target_type, ref: target_ref, workspace_id: workspace_id}}
    else
      {:error, :invalid_target}
    end
  end

  defp normalize_target(_target), do: {:error, :invalid_target}

  defp current_decision(approval_id) do
    case approval_events(approval_id) do
      [] ->
        {:error, :approval_not_found}

      events ->
        decisive =
          Enum.find(events, fn event ->
            event.action in ["run.approval_granted", "run.approval_denied"]
          end)

        event = decisive || Enum.find(events, &(&1.action == "run.approval_requested"))
        {:ok, event_to_approval(event)}
    end
  end

  defp request_event(approval_id) do
    approval_id
    |> approval_events()
    |> Enum.find(&(&1.action == "run.approval_requested"))
    |> case do
      %Event{} = event -> {:ok, event}
      nil -> {:error, :approval_not_found}
    end
  end

  defp approval_events(approval_id) do
    Audit.list(limit: 1_000)
    |> Enum.filter(fn %Event{} = event ->
      approval_event?(event) and
        (metadata_value(event.metadata, "approval_id") == approval_id or
           event.target_ref == approval_id)
    end)
  end

  defp approval_event?(%Event{action: action}) when is_binary(action),
    do: String.starts_with?(action, "run.approval_")

  defp approval_event?(_event), do: false

  defp event_result(%Event{} = event), do: {:ok, event_to_approval(event)}
  defp event_result(nil), do: {:error, :approval_not_recorded}

  defp event_to_approval(%Event{} = event) do
    metadata = stringify_keys(event.metadata || %{})

    %{
      id: metadata_value(metadata, "approval_id") || event.target_ref,
      status: approval_status(event),
      action: metadata_value(metadata, "approval_action"),
      target_type: metadata_value(metadata, "approval_target_type"),
      target_ref: metadata_value(metadata, "approval_target_ref"),
      workspace_id: event.workspace_id,
      actor_id: event.actor_id,
      event: event
    }
  end

  defp approval_status(%Event{action: "run.approval_requested"}), do: "requested"
  defp approval_status(%Event{action: "run.approval_granted"}), do: "granted"
  defp approval_status(%Event{action: "run.approval_denied"}), do: "denied"

  defp approval_status(%Event{metadata: metadata}),
    do: metadata_value(metadata, "approval_status")

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp stringify_keys(_map), do: %{}

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp metadata_value(nil, _key), do: nil

  defp metadata_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, existing_atom(key))
  end

  defp metadata_value(_value, _key), do: nil

  defp existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
