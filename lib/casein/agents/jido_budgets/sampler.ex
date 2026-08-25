defmodule Casein.Agents.JidoBudgets.Sampler do
  @moduledoc """
  Host and BEAM samples for Jido budgets. Unknown probes are never treated as
  spare capacity.
  """

  alias Casein.Terminals.HostCapacity

  @spec snapshot(keyword()) :: map()
  def snapshot(opts \\ []) do
    case Application.get_env(:casein, :jido_budget_sampler) do
      fun when is_function(fun, 0) ->
        normalize(fun.())

      _ ->
        measure(opts)
    end
  end

  defp measure(opts) do
    host = HostCapacity.snapshot(opts)
    rss = rss_bytes(host)

    %{
      process_count: :erlang.system_info(:process_count),
      memory_bytes: :erlang.memory(:total),
      rss_bytes: rss,
      cpu_ratio: cpu_ratio(host),
      status: host.status,
      reasons: host.reasons,
      available?: host.available?,
      healthy?: host.healthy?
    }
  end

  defp normalize(sample) when is_map(sample) do
    %{
      process_count: Map.get(sample, :process_count, :erlang.system_info(:process_count)),
      memory_bytes: Map.get(sample, :memory_bytes, :erlang.memory(:total)),
      rss_bytes: Map.get(sample, :rss_bytes),
      cpu_ratio: Map.get(sample, :cpu_ratio),
      status: Map.get(sample, :status, "unknown"),
      reasons: List.wrap(Map.get(sample, :reasons, [])),
      available?: Map.get(sample, :available?, false),
      healthy?: Map.get(sample, :healthy?, false)
    }
  end

  defp rss_bytes(%{mem_available_kb: avail, min_mem_available_kb: min})
       when is_integer(avail) and is_integer(min) do
    max(min - avail, 0) * 1024
  end

  defp rss_bytes(_), do: nil

  defp cpu_ratio(%{load1: load, nproc: nproc})
       when is_float(load) and is_integer(nproc) and nproc > 0 do
    load / nproc
  end

  defp cpu_ratio(_), do: nil
end
