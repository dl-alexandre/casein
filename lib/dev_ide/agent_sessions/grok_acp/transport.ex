defmodule DevIDE.AgentSessions.GrokACP.Transport do
  @moduledoc false

  @type handle :: term()

  @callback start(owner :: pid(), keyword()) :: {:ok, handle()} | {:error, term()}
  @callback write(handle(), iodata()) :: :ok | {:error, term()}
  @callback stop(handle()) :: :ok
end
