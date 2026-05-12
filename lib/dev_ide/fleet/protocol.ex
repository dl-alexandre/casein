defmodule DevIDE.Fleet.Protocol do
  @moduledoc """
  Public API for the controller ↔ runner protocol.

  ## Vocabulary

    * `Assignment` — orchestration intent (what work should happen)
    * `Execution` — a concrete runner attempt at that work
    * `Run Ledger` — durable artifact/output timeline

  ## Usage

  ### Controller side (offering work)

      offer = %Messages.AssignmentOffered{
        assignment_id: "a-1",
        safe_action_id: "command:build",
        workspace_id: "ws-1"
      }

      Protocol.offer_to_runner("runner-1", offer)

  ### Runner side (reporting progress)

      started = %Messages.ExecutionStarted{
        assignment_id: "a-1",
        execution_id: "e-1",
        started_at: DateTime.utc_now()
      }

      envelope = Protocol.wrap(started, runner_id: "runner-1", lease_id: "a-1")
      Protocol.send_to_controller(envelope)

  All messages must be wrapped in an envelope before transport.
  No raw payloads are valid.
  """

  alias DevIDE.Fleet.LocalRunnerAdapter
  alias DevIDE.Fleet.Protocol.Envelope
  alias DevIDE.Fleet.Protocol.Messages
  alias DevIDE.Fleet.Protocol.Validator

  @doc "Wrap a message in a protocol envelope."
  @spec wrap(struct(), keyword()) :: Envelope.t()
  def wrap(payload, opts), do: Envelope.wrap(payload, opts)

  @doc "Serialize an envelope to a transport map."
  @spec serialize(Envelope.t()) :: map()
  def serialize(envelope), do: Envelope.to_map(envelope)

  @doc "Deserialize a transport map back to an envelope."
  @spec deserialize(map()) :: {:ok, Envelope.t()} | {:error, term()}
  def deserialize(map), do: Envelope.from_map(map)

  @doc "Validate an envelope through all four layers."
  @spec validate(Envelope.t()) :: {:ok, Validator.context()} | {:error, term()}
  def validate(envelope), do: Validator.validate(envelope)

  @doc "Send a message from runner to controller through the local boundary."
  @spec send_to_controller(Envelope.t()) :: {:ok, term()} | {:error, term()}
  def send_to_controller(envelope), do: LocalRunnerAdapter.send_to_controller(envelope)

  @doc "Offer an assignment to a runner."
  @spec offer_to_runner(String.t(), Messages.AssignmentOffered.t()) ::
          {:ok, Messages.AssignmentAccepted.t() | Messages.AssignmentRejected.t()}
          | {:error, term()}
  def offer_to_runner(runner_id, offer), do: LocalRunnerAdapter.offer_assignment(runner_id, offer)

  @doc "Classify a message."
  @spec classify(struct()) :: :state_transition | :observational | :lifecycle | :control
  def classify(msg) do
    cond do
      Messages.state_transition?(msg) -> :state_transition
      Messages.observational?(msg) -> :observational
      Messages.lifecycle?(msg) -> :lifecycle
      true -> :control
    end
  end
end
