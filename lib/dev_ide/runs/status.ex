defmodule DevIDE.Runs.Status do
  @moduledoc """
  Centralized run-status semantics across run lifecycle and audit events.

  Consumers (Runs.Ledger, Export.WorkspaceStatus, WorkspaceLive.Show)
  normalize into this module so that "failed", "timed_out", "denied",
  "expired", and "abandoned" have a single source of truth.
  """

  alias DevIDE.Policy

  @terminal ~w(succeeded failed timed_out denied approval_denied expired abandoned)
  @failed ~w(failed timed_out denied approval_denied expired abandoned)
  @blocked ~w(denied approval_denied)
  @in_progress ~w(requested approval_requested queued claimed running)

  @doc """
  Returns the canonical string form of a status.
  Accepts atoms (`:running`, `:succeeded`, `:failed`, `:timed_out`) and
  strings (`"running"`, `"succeeded"`, etc.).
  """
  @spec normalize(atom() | String.t()) :: String.t()
  def normalize(status) when is_atom(status) and not is_nil(status), do: Atom.to_string(status)
  def normalize(status) when is_binary(status), do: status
  def normalize(_), do: "unknown"

  @doc """
  Is the run in a terminal state (no further transitions possible)?
  """
  @spec terminal?(atom() | String.t()) :: boolean()
  def terminal?(status), do: normalize(status) in @terminal

  @doc """
  Did the run end in some kind of failure or blockage?
  Includes timeouts, denials, expirations, and abandonments.
  """
  @spec failed?(atom() | String.t()) :: boolean()
  def failed?(status), do: normalize(status) in @failed

  @doc """
  Was the run blocked by policy before it could start?
  """
  @spec blocked?(atom() | String.t()) :: boolean()
  def blocked?(status), do: normalize(status) in @blocked

  @doc """
  Is the run currently in-flight (not yet terminal)?
  """
  @spec in_progress?(atom() | String.t()) :: boolean()
  def in_progress?(status), do: normalize(status) in @in_progress

  @doc """
  Can this run be retried from the UI?

  A run is retryable when:
    * it has a command_id
    * it is in a terminal state
    * it was NOT blocked by policy (denied/approval_denied)
    * the current policy context allows the command

  The caller must supply the run summary and a function that returns a
  `%DevIDE.Policy.Decision{}` for the command.
  """
  @spec retryable?(map(), (String.t() -> Policy.Decision.t())) :: boolean()
  def retryable?(%{command_id: command_id, status: status}, decision_fun)
      when is_binary(command_id) and is_function(decision_fun, 1) do
    terminal?(status) and not blocked?(status) and
      Policy.Decision.allow?(decision_fun.(command_id))
  end

  def retryable?(_summary, _decision_fun), do: false

  @doc """
  Extract a human-readable failure reason from a run summary and its
  canonical audit timeline.

  Returns `nil` when the run is not in a failed state.
  """
  @spec failure_reason(map(), [DevIDE.Audit.Event.t()]) :: String.t() | nil
  def failure_reason(%{status: status} = summary, timeline) do
    cond do
      blocked?(status) ->
        timeline
        |> Enum.find_value(fn e ->
          if e.action in ["run.command_denied", "run.approval_denied"] and e.reason do
            Atom.to_string(e.reason)
          else
            nil
          end
        end)

      status in ["failed", :failed] ->
        case Map.get(summary, :exit_code) do
          nil -> "failed"
          code -> "exit #{code}"
        end

      status in ["timed_out", :timed_out] ->
        "timed out"

      status in ["expired", :expired] ->
        "runner lease expired"

      status in ["abandoned", :abandoned] ->
        "abandoned"

      true ->
        nil
    end
  end

  def failure_reason(_summary, _timeline), do: nil

  @doc """
  Returns a UI-friendly atom for CSS class selection.

  Maps ledger/runner status strings to a small set of atoms:
    :running, :succeeded, :failed, :timed_out, :unknown
  """
  @spec status_class(atom() | String.t()) :: atom()
  def status_class(status) do
    case normalize(status) do
      s when s in ["requested", "approval_requested", "queued", "claimed", "running"] ->
        :running

      "succeeded" ->
        :succeeded

      s when s in ["failed", "denied", "approval_denied", "abandoned"] ->
        :failed

      "timed_out" ->
        :timed_out

      "expired" ->
        :timed_out

      _ ->
        :unknown
    end
  end
end
