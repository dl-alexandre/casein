defmodule Casein.Agents.JidoBudgets.Limits do
  @moduledoc """
  Documented Jido resource budgets. Operators change these through
  `config :casein, :jido_pod` or the matching `CASEIN_JIDO_*` env vars.
  """

  @defaults [
    max_running_per_workspace: 2,
    max_queued_per_workspace: 4,
    max_running_fleet: 8,
    max_share_per_workspace: 0.5,
    max_provider_inflight: 4,
    max_worker_memory_bytes: 2_000_000,
    max_action_output_bytes: 256_000,
    max_fleet_memory_bytes: 16_000_000,
    max_crash_rate: 5,
    crash_window_ms: 60_000,
    max_leaked_leases: 0,
    default_attempt_deadline_ms: 60_000,
    default_action_timeout_ms: 5_000,
    max_retries: 1,
    opencode_rss_per_worker_bytes: 262_144_000,
    go_process_ratio: 0.5,
    go_rss_ratio: 0.5,
    go_max_error_rate: 0.05,
    rollback_process_ratio: 1.0,
    cpu_pressure_ratio: 0.9
  ]

  @type t :: keyword()

  @spec defaults() :: t()
  def defaults, do: @defaults

  @spec get() :: t()
  def get do
    Keyword.merge(@defaults, Application.get_env(:casein, :jido_pod, []))
  end

  @spec get(atom()) :: term()
  def get(key) when is_atom(key) do
    Keyword.get(get(), key, Keyword.get(@defaults, key))
  end

  @spec public() :: map()
  def public do
    Map.new(get())
  end

  @spec max_workspace_share(non_neg_integer()) :: pos_integer()
  def max_workspace_share(fleet_max \\ get(:max_running_fleet)) do
    share = get(:max_share_per_workspace)

    share =
      cond do
        is_float(share) and share > 0 and share <= 1 -> share
        is_integer(share) and share > 0 and share <= 1 -> share * 1.0
        true -> 0.5
      end

    max(1, trunc(fleet_max * share))
  end
end
