defmodule Casein.Agents.JidoWorkcell.Events do
  @moduledoc """
  Structured Workcell supervisor events for the panel and other observers.

  The event stream is deliberately independent of terminal output. Every
  event carries the shared identity tuple, a lifecycle state, a timestamp, and
  a deterministic idempotency key so consumers can safely reconnect.
  """

  alias Casein.Agents.Activity
  alias Phoenix.PubSub

  @topic_prefix "jido_workcell:"

  @states ~w(requested queued provisioning ready active waiting completed failed cancelled draining stopped)a

  @spec topic(String.t()) :: String.t()
  def topic(workcell_id) when is_binary(workcell_id), do: @topic_prefix <> workcell_id

  @spec subscribe(String.t()) :: :ok
  def subscribe(workcell_id) when is_binary(workcell_id) do
    PubSub.subscribe(Casein.PubSub, topic(workcell_id))
  end

  @spec attempt(map()) :: map()
  def attempt(attempt) when is_map(attempt) do
    event =
      base(attempt)
      |> Map.merge(%{
        event_type: "workcell.worker.lifecycle",
        worker_id: attempt[:worker_id],
        runtime_id: attempt[:runtime_id],
        owner_ref: attempt[:owner_ref],
        source: attempt[:source],
        release_sha: attempt[:release_sha],
        task_id: attempt[:task_id],
        lease_id: attempt[:lease_id],
        correlation_id: attempt[:correlation_id],
        handoff_id: attempt[:completion_receipt] && attempt[:completion_receipt][:handoff_id],
        receipt_id: attempt[:receipt_id],
        state: lifecycle_state(attempt[:state]),
        prior_state: attempt[:prior_state],
        progress: attempt[:progress],
        blocker: attempt[:blocker],
        receipt: receipt(attempt[:completion_receipt])
      })
      |> compact()
      |> idempotency_key()

    publish(event)
    event
  end

  @spec cell(String.t(), String.t(), atom(), keyword()) :: map()
  def cell(workspace_id, workcell_id, state, opts \\ [])
      when is_binary(workspace_id) and is_binary(workcell_id) and state in @states do
    event =
      base(%{workspace_id: workspace_id, workcell_id: workcell_id})
      |> Map.merge(%{
        event_type: "workcell.lifecycle",
        state: state,
        worker_id: Keyword.get(opts, :worker_id),
        task_id: Keyword.get(opts, :task_id),
        lease_id: Keyword.get(opts, :lease_id)
      })
      |> compact()
      |> idempotency_key()

    publish(event)
    event
  end

  @spec lifecycle_state(atom() | String.t() | nil) :: atom()
  def lifecycle_state(:admitted), do: :requested
  def lifecycle_state(:queued), do: :queued
  def lifecycle_state(:retrying), do: :provisioning
  def lifecycle_state(:running), do: :active
  def lifecycle_state(:awaiting_human), do: :waiting
  def lifecycle_state(:completed), do: :completed
  def lifecycle_state(:failed), do: :failed
  def lifecycle_state(:cancelled), do: :cancelled
  def lifecycle_state(:timed_out), do: :failed
  def lifecycle_state(:provider_unavailable), do: :failed
  def lifecycle_state(:requested), do: :requested
  def lifecycle_state(:provisioning), do: :provisioning
  def lifecycle_state(:ready), do: :ready
  def lifecycle_state(:active), do: :active
  def lifecycle_state(:waiting), do: :waiting
  def lifecycle_state(:draining), do: :draining
  def lifecycle_state(:stopped), do: :stopped
  def lifecycle_state(_), do: :failed

  defp base(attrs) do
    now = DateTime.utc_now()
    workspace_id = attrs[:workspace_id] || attrs["workspace_id"]
    workcell_id = attrs[:workcell_id] || attrs["workcell_id"]
    worker_id = attrs[:worker_id] || attrs["worker_id"]
    sequence = attrs[:sequence] || 0

    %{
      event_id: Ecto.UUID.generate(),
      session_id: attrs[:session_id] || attrs["session_id"],
      workcell_id: workcell_id,
      workspace_id: workspace_id,
      worker_id: worker_id,
      runtime_id: attrs[:runtime_id] || attrs["runtime_id"],
      owner_ref: attrs[:owner_ref] || attrs["owner_ref"],
      sequence: sequence,
      timestamp: attrs[:updated_at] || attrs[:timestamp] || now
    }
    |> compact()
  end

  defp idempotency_key(event) do
    workcell_id = Map.get(event, :workcell_id) || Map.get(event, :workspace_id, "unknown")
    worker_id = Map.get(event, :worker_id, "unknown")

    Map.put(
      event,
      :idempotency_key,
      "#{workcell_id}:#{worker_id}:#{Map.get(event, :sequence, 0)}:#{Map.get(event, :state, :unknown)}"
    )
  end

  defp publish(event) do
    workspace_id = Map.get(event, :workspace_id)
    workcell_id = Map.get(event, :workcell_id)
    worker_id = Map.get(event, :worker_id, "worker")
    state = Map.get(event, :state, :unknown)
    event_type = Map.get(event, :event_type, "workcell.event")

    _ =
      safe_activity(%{
        workspace_id: workspace_id,
        source: :jido_workcell,
        tool: event_type,
        summary: "#{worker_id} #{state}",
        metadata: Map.drop(event, [:event_id, :receipt]),
        status: if(state in [:failed, :cancelled], do: :error, else: :ok)
      })

    event_topic = workcell_id || workspace_id

    if is_binary(event_topic) do
      PubSub.broadcast(Casein.PubSub, topic(event_topic), {:jido_workcell, event})
    end

    if is_binary(workspace_id) and is_binary(workcell_id) and workspace_id != workcell_id do
      PubSub.broadcast(
        Casein.PubSub,
        "jido_workcell_workspace:" <> workspace_id,
        {:jido_workcell, event}
      )
    end

    :ok
  end

  defp safe_activity(attrs) do
    Activity.record(attrs)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp receipt(receipt) when is_map(receipt),
    do:
      Map.take(receipt, [
        :schema_version,
        :contract,
        :kind,
        :source,
        :receipt_id,
        :repository,
        :base_branch,
        :head_branch,
        :head_sha,
        :changed_files,
        :tests,
        :workspace_id,
        :owner_ref,
        :runtime_id,
        :worker_id,
        :handoff_id,
        :release_sha,
        :git,
        :occurred_at,
        :redaction,
        :idempotency_key,
        :artifacts,
        :blocker
      ])

  defp receipt(_), do: nil

  defp compact(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) or value == "" end)
  end
end
