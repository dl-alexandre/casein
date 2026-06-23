defmodule DevIDE.Loops.Quarantine do
  @moduledoc """
  Policy + audit gate for the experimental Loops subsystem.

  Loops can mutate git worktrees and run `mix` off the request path. It is
  **disabled by default** (`config :dev_ide, DevIDE.Loops, enabled: true` to
  opt in). Every entry seam calls `authorize!/1` before side effects.
  """

  alias DevIDE.{Audit, Policy}
  alias DevIDE.Policy.Decision

  @doc "True when `config :dev_ide, DevIDE.Loops, enabled: true`."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:dev_ide, DevIDE.Loops, [])[:enabled] == true

  @doc """
  Policy check + audit emit. Returns `:ok` or `{:error, reason}`.
  """
  @spec authorize!(map()) :: :ok | {:error, atom()}
  def authorize!(ctx \\ %{}) when is_map(ctx) do
    decision = Policy.can_run_loop?(ctx)

    Audit.emit_decision(decision, %{
      action: "loops.authorize",
      workspace_id: Map.get(ctx, :workspace_id),
      target_type: "loop",
      actor_id: to_string(Map.get(ctx, :actor_type, :system)),
      metadata: %{
        loop_run_id: Map.get(ctx, :loop_run_id),
        actor_type: Map.get(ctx, :actor_type, :system)
      }
    })

    if Decision.allow?(decision), do: :ok, else: {:error, decision.reason}
  end
end
