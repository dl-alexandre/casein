defmodule DevIDE.Fleet.RemoteRunner.LocalTransport do
  @moduledoc """
  Localhost transport adapter for the standalone runner process.

  This intentionally still serializes/deserializes envelopes through the public
  protocol API. Tests can run the runner and controller in one BEAM while
  preserving the same wire contract a remote transport uses.
  """

  @behaviour DevIDE.Fleet.RemoteRunner.Transport

  alias DevIDE.Fleet
  alias DevIDE.Fleet.Protocol
  alias FleetCtl.Protocol.Envelope

  @impl true
  def init(opts) do
    {:ok,
     %{
       runner_id: Keyword.get(opts, :runner_id) || Ecto.UUID.generate(),
       hostname: Keyword.get(opts, :hostname) || "local-runner",
       capabilities: Keyword.get(opts, :capabilities, ["workspace-command:v1"]),
       metadata: Keyword.get(opts, :metadata, %{}),
       protocol_versions: Keyword.get(opts, :protocol_versions, [1]),
       transports: ["local"]
     }}
  end

  @impl true
  def register(state) do
    attrs =
      state
      |> Map.take([
        :runner_id,
        :hostname,
        :capabilities,
        :metadata,
        :protocol_versions,
        :transports
      ])
      |> Map.put(:id, state.runner_id)
      |> Map.delete(:runner_id)

    case Fleet.register(attrs) do
      {:ok, runner} -> {:ok, Map.put(state, :runner, runner)}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def heartbeat(state) do
    case Fleet.heartbeat(state.runner_id) do
      {:ok, runner} -> {:ok, Map.put(state, :runner, runner)}
      {:error, _reason} = error -> error
      :error -> {:error, :runner_not_found}
    end
  end

  @impl true
  def drain(state) do
    case Fleet.drain_runner(state.runner_id, actor_id: "runner") do
      {:ok, identity} -> {:ok, Map.put(state, :identity, identity)}
      :error -> {:error, :runner_not_found}
    end
  end

  @impl true
  def shutdown(state) do
    case Fleet.shutdown_runner(state.runner_id, actor_id: "runner") do
      {:ok, runner} -> {:ok, Map.put(state, :runner, runner)}
      :error -> {:error, :runner_not_found}
    end
  end

  @impl true
  def poll_offer(state, opts) do
    Fleet.poll_transport_offer(state.runner_id, opts)
  end

  @impl true
  def send_envelope(_state, %Envelope{} = envelope) do
    envelope
    |> Protocol.serialize()
    |> Protocol.deserialize()
    |> case do
      {:ok, decoded} -> Protocol.send_to_controller(decoded)
      {:error, _reason} = error -> error
    end
  end
end
