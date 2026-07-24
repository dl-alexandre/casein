defmodule Casein.Previews.PortProbe do
  @moduledoc """
  Fast loopback TCP liveness probe for discovered preview surfaces.

  Runtime-recorded and terminal-detected surfaces are provenance, not
  liveness: the dev server that registered a port may have exited long ago
  (worktree reaped, process killed) while its registration lives on. Listing
  those surfaces as active sends agents to dead ports.

  `probe/1` answers the question `preview_open`'s preflight would ask — can
  the Casein node connect to this loopback port right now — with a bounded
  concurrent TCP connect per port. Best-effort: any failure is `false`,
  never an exception.
  """

  @default_timeout_ms 250
  @max_concurrency 16

  @doc "True when a TCP connect to 127.0.0.1:port succeeds within the timeout."
  @spec alive?(:inet.port_number()) :: boolean()
  def alive?(port) when is_integer(port) and port > 0 and port < 65_536 do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [active: false], timeout_ms()) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end

  def alive?(_), do: false

  @doc "Probe ports concurrently. Returns `%{port => alive?}` for the unique integer ports."
  @spec probe(Enumerable.t()) :: %{integer() => boolean()}
  def probe(ports) do
    ports =
      ports
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    results =
      ports
      |> Task.async_stream(&alive?/1,
        max_concurrency: @max_concurrency,
        timeout: timeout_ms() + 250,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.map(fn
        {:ok, alive?} -> alive?
        _ -> false
      end)

    ports |> Enum.zip(results) |> Map.new()
  end

  defp timeout_ms do
    Application.get_env(:casein, :preview_surface_probe_timeout_ms, @default_timeout_ms)
  end
end
