defmodule Casein.Runtimes.PreviewPortProbe do
  @moduledoc """
  Probes whether a runtime-preview port can be bound on loopback.

  Runtime allocation uses this system implementation by default. Tests inject
  a process-local deterministic probe so a gate running on the production host
  cannot contend with authoritative live preview listeners.
  """

  @callback available?(integer()) :: boolean()

  @behaviour __MODULE__

  @impl true
  def available?(port) when is_integer(port) and port > 0 and port < 65_536 do
    case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  def available?(_port), do: false
end
