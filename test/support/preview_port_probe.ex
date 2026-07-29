defmodule Casein.Test.PreviewPortProbe do
  @moduledoc false

  @behaviour Casein.Runtimes.PreviewPortProbe

  @unavailable_key {__MODULE__, :unavailable_ports}

  @impl true
  def available?(port) when is_integer(port) do
    port not in Process.get(@unavailable_key, MapSet.new())
  end

  def available?(_port), do: false

  def mark_unavailable(port) when is_integer(port) do
    unavailable =
      @unavailable_key
      |> Process.get(MapSet.new())
      |> MapSet.put(port)

    Process.put(@unavailable_key, unavailable)
    :ok
  end
end
