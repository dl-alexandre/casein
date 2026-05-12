defmodule DevIDE.Fleet.RemoteRunner.Transport do
  @moduledoc """
  Transport contract used by the standalone runner process.

  Implementations move controller-approved protocol envelopes. They do not
  decide placement, mutate assignments, or interpret artifacts.
  """

  alias DevIDE.Fleet.Protocol.Envelope

  @type state :: map()
  @type offer :: map()

  @callback init(keyword()) :: {:ok, state()} | {:error, term()}
  @callback register(state()) :: {:ok, state()} | {:error, term()}
  @callback heartbeat(state()) :: {:ok, state()} | {:error, term()}
  @callback drain(state()) :: {:ok, state()} | {:error, term()}
  @callback shutdown(state()) :: {:ok, state()} | {:error, term()}
  @callback poll_offer(state(), keyword()) :: {:ok, offer()} | :none | {:error, term()}
  @callback send_envelope(state(), Envelope.t()) :: {:ok, term()} | {:error, term()}
end
