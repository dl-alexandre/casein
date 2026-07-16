defmodule DevIDE.Deployment.DeployAudit do
  @moduledoc """
  Persists durable audit rows on deploy-pipeline and drift *transitions*.

  `DevIDE.Deployment.PollerWatcher` re-reads the poller status file (and
  re-checks drift) every tick; this module keeps the last-seen
  `{outcome, target_sha}` key and drift flag so each transition writes exactly
  one row instead of one per poll:

    * `deploy.started` — a new `target_sha` reached `in_progress`
    * `deploy.succeeded` / `deploy.failed` — the attempt finished (failed rows
      carry phase + reason)
    * `deploy.drift_detected` / `deploy.drift_cleared` — the running revision
      diverged from / reconverged with the remote branch head

  Deploy events are box-global, not workspace-scoped, and
  `audit_events.workspace_id` is NOT NULL — rows use the `"_deploy"` sentinel
  workspace id. The first observation after boot seeds the deploy key silently
  (re-logging the previous deploy on every release restart would be noise);
  drift is the exception: a box that boots already drifted emits
  `deploy.drift_detected` immediately because that state is actionable now.
  """

  alias DevIDE.Audit
  alias DevIDE.Export.Sanitizer

  @workspace_id "_deploy"

  @type t :: %{
          deploy: {String.t(), String.t(), String.t() | nil} | nil,
          drifted: boolean() | nil
        }

  @doc "Sentinel workspace id used for box-global deploy audit rows."
  @spec workspace_id() :: String.t()
  def workspace_id, do: @workspace_id

  @doc "Fresh transition-tracking state (nothing observed yet)."
  @spec new() :: t()
  def new, do: %{deploy: nil, drifted: nil}

  @doc """
  Observe the current poller record and drift status, emitting audit rows for
  any transitions since the previous observation. Returns the updated state.

  `record` is the decoded last-deploy JSON map (or nil when missing/invalid);
  `drift_status` is `DevIDE.Deployment.Drift.check_and_broadcast/0` output.
  """
  @spec observe(t(), map() | nil, DevIDE.Deployment.Drift.status() | nil) :: t()
  def observe(state, record, drift_status) do
    state
    |> observe_deploy(record)
    |> observe_drift(drift_status)
  end

  ## Deploy pipeline transitions

  defp observe_deploy(state, record) when is_map(record) do
    case deploy_key(record) do
      nil ->
        state

      key ->
        cond do
          state.deploy == key -> state
          # First observation after boot: seed without emitting, so a restart
          # does not re-log the deploy that shipped it.
          state.deploy == nil -> %{state | deploy: key}
          true -> emit_deploy(state, key, record)
        end
    end
  end

  defp observe_deploy(state, _record), do: state

  # started_at joins the key so a *re-deploy* of the same sha ending in the
  # same outcome (retry the failed gate, fail again) is a new attempt with its
  # own rows, not a duplicate observation of the previous one.
  defp deploy_key(record) do
    outcome = record["outcome"]
    target = normalize(record["target_sha"])

    if is_binary(outcome) and outcome != "" and is_binary(target),
      do: {outcome, target, normalize(record["started_at"])},
      else: nil
  end

  defp emit_deploy(state, {outcome, _target, _started_at} = key, record) do
    case deploy_action(outcome) do
      nil ->
        :ok

      action ->
        Audit.emit!(%{
          workspace_id: @workspace_id,
          actor_id: "deploy_poller",
          action: action,
          source: "deploy",
          target_type: "git_sha",
          target_ref: record["target_sha"],
          metadata: deploy_metadata(record)
        })
    end

    %{state | deploy: key}
  end

  defp deploy_action("in_progress"), do: "deploy.started"
  defp deploy_action("success"), do: "deploy.succeeded"
  defp deploy_action("failed"), do: "deploy.failed"
  defp deploy_action(_outcome), do: nil

  defp deploy_metadata(record) do
    %{
      target_sha: record["target_sha"],
      target_short: record["target_short"],
      from_sha: record["from_sha"],
      phase: record["phase"],
      reason: redact(record["reason"]),
      started_at: record["started_at"],
      finished_at: record["finished_at"]
    }
    |> reject_blank()
  end

  ## Drift transitions

  defp observe_drift(state, :current), do: drift_transition(state, false, %{})

  defp observe_drift(state, {:drift, info}), do: drift_transition(state, true, info)

  # Lookup failures (and a nil status when the check is disabled) are not
  # evidence either way — keep the previous flag so drift does not flap.
  defp observe_drift(state, _status), do: state

  defp drift_transition(%{drifted: drifted} = state, drifted, _info), do: state

  defp drift_transition(state, true, info) do
    Audit.emit!(%{
      workspace_id: @workspace_id,
      actor_id: "deploy_poller",
      action: "deploy.drift_detected",
      source: "deploy",
      metadata: drift_metadata(info)
    })

    %{state | drifted: true}
  end

  defp drift_transition(state, false, _info) do
    # nil -> false is a seed, not a transition: booting in the healthy state
    # is not an event.
    if state.drifted == true do
      Audit.emit!(%{
        workspace_id: @workspace_id,
        actor_id: "deploy_poller",
        action: "deploy.drift_cleared",
        source: "deploy",
        metadata: %{}
      })
    end

    %{state | drifted: false}
  end

  defp drift_metadata(info) when is_map(info) do
    %{
      reason: info[:reason],
      current: info[:current],
      remote: info[:remote],
      branch: info[:branch],
      message: redact(info[:message])
    }
    |> reject_blank()
  end

  defp redact(value) when is_binary(value), do: Sanitizer.redact_text(value)
  defp redact(value), do: value

  defp reject_blank(map) do
    map
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
  end

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(_value), do: nil
end
