defmodule Casein.Terminals.FleetChrome do
  @moduledoc """
  Pure fleet-operator projection over existing pane signals.

  Does **not** own state. It reads fields already attached by the topology
  enrich pipeline (`Labels`, `IssueBinding`, `AgentState`, `PaneLiveness`,
  `PaneState`) and attaches:

    * `:fleet_role` — `:manager` | `:worker` when a label/window convention
      matches (see below)
    * `:fleet_readiness` — `:ready_no_task` when an agent pane is idle/ready
      with no issue binding and no real task summary
    * `:ready_no_task_for_seconds` — how long that readiness has held, from
      liveness `quiet_for_seconds` or the agent-state report age

  ## Label convention (manager vs worker)

  Set with `terminal_set_agent_label` (freeze recommended for fleet roles):

    * `manager` or `manager: <note>` — orchestrator / solo implementer
    * `worker` or `worker: <note>` — spawned implementer

  `scripts/spawn-agent-worker.sh` already names windows `worker-<slug>`; that
  window name alone is enough to classify the pane as `:worker` without a
  label. There is no automatic `:manager` inference — an unlabeled solo agent
  stays role-unset so chrome does not lie.

  ## Ready, no task, > N minutes

  Computable without scrollback capture when:

    1. pane `role` is `"agent"`
    2. resolved `agent_state` is `:idle` or `:done`, or title heuristic
       `pane_state` is `:ready`
    3. no `:issue` binding
    4. `task_summary` is nil (bare runtime titles like "OpenCode" /
       "Claude Code" are stripped by `PaneState`)
    5. quiet duration ≥ threshold (default 120s) from
       `liveness.quiet_for_seconds` or `agent_state_age_s`

  Call with `include_liveness: true` on `terminal_topology` for the external
  quiet clock; without it, readiness still projects when a live agent-state
  report carries age.
  """

  alias Casein.Terminals.PaneState

  @default_ready_seconds 120

  @type fleet_role :: :manager | :worker
  @type fleet_readiness :: :ready_no_task

  @doc "Default seconds of quiet before a pane is `ready_no_task`."
  @spec default_ready_seconds() :: pos_integer()
  def default_ready_seconds, do: @default_ready_seconds

  @doc """
  Attach fleet chrome fields to every pane (and agent window) in a topology.

  Options:

    * `:ready_seconds` — quiet threshold (default #{@default_ready_seconds})
  """
  @spec enrich_topology(map(), keyword()) :: map()
  def enrich_topology(topology, opts \\ [])

  def enrich_topology(%{panes: panes, windows: windows} = topology, opts)
      when is_list(panes) and is_list(windows) do
    ready_seconds = ready_seconds(opts)
    panes = Enum.map(panes, &enrich_pane(&1, ready_seconds))
    panes_by_id = Map.new(panes, &{PaneState.map_get(&1, :id), &1})

    windows =
      Enum.map(windows, fn window ->
        case PaneState.agent_or_active_pane(window) do
          nil ->
            window

          pane ->
            case Map.get(panes_by_id, PaneState.map_get(pane, :id)) do
              %{} = enriched ->
                window
                |> maybe_copy(enriched, :fleet_role)
                |> maybe_copy(enriched, :fleet_readiness)
                |> maybe_copy(enriched, :ready_no_task_for_seconds)

              _ ->
                window
            end
        end
      end)

    %{topology | panes: panes, windows: windows}
  end

  def enrich_topology(%{panes: panes} = topology, opts) when is_list(panes) do
    ready_seconds = ready_seconds(opts)
    %{topology | panes: Enum.map(panes, &enrich_pane(&1, ready_seconds))}
  end

  def enrich_topology(topology, _opts), do: topology

  @doc "Pure classification for one already-enriched pane map."
  @spec enrich_pane(map(), pos_integer()) :: map()
  def enrich_pane(pane, ready_seconds \\ @default_ready_seconds)

  def enrich_pane(pane, ready_seconds) when is_map(pane) and is_integer(ready_seconds) do
    pane
    |> put_fleet_role()
    |> put_ready_no_task(ready_seconds)
  end

  def enrich_pane(pane, _ready_seconds), do: pane

  @doc """
  Parse a fleet role from a chrome label or tmux window name.

  Accepts `manager`, `manager: …`, `worker`, `worker: …`, and spawn window
  names `worker-<slug>`.
  """
  @spec role_from_text(term()) :: fleet_role() | nil
  def role_from_text(text) when is_binary(text) do
    case text |> String.trim() |> String.downcase() do
      "manager" <> rest -> role_token_rest(rest, :manager)
      "mgr" <> rest -> role_token_rest(rest, :manager)
      "worker" <> rest -> role_token_rest(rest, :worker)
      _ -> nil
    end
  end

  def role_from_text(_), do: nil

  @doc """
  True when the pane looks idle/ready with no assigned task signal.

  Does not apply the quiet-duration threshold — see `ready_no_task?/2`.
  """
  @spec idle_without_task?(map()) :: boolean()
  def idle_without_task?(pane) when is_map(pane) do
    PaneState.agent_role?(pane) and
      idle_or_ready?(pane) and
      is_nil(PaneState.map_get(pane, :issue)) and
      is_nil(blank_to_nil(PaneState.map_get(pane, :task_summary)))
  end

  def idle_without_task?(_), do: false

  @doc "Idle-without-task and quiet for at least `ready_seconds`."
  @spec ready_no_task?(map(), pos_integer()) :: boolean()
  def ready_no_task?(pane, ready_seconds \\ @default_ready_seconds)

  def ready_no_task?(pane, ready_seconds)
      when is_map(pane) and is_integer(ready_seconds) and ready_seconds > 0 do
    idle_without_task?(pane) and quiet_for(pane) >= ready_seconds
  end

  def ready_no_task?(_, _), do: false

  ## Internals

  defp put_fleet_role(pane) do
    role =
      role_from_text(label_text(pane)) ||
        role_from_text(PaneState.map_get(pane, :window_name)) ||
        role_from_text(PaneState.map_get(pane, :window_title))

    if role, do: Map.put(pane, :fleet_role, role), else: pane
  end

  defp put_ready_no_task(pane, ready_seconds) do
    quiet = quiet_for(pane)

    if idle_without_task?(pane) and is_integer(quiet) and quiet >= ready_seconds do
      pane
      |> Map.put(:fleet_readiness, :ready_no_task)
      |> Map.put(:ready_no_task_for_seconds, quiet)
    else
      pane
    end
  end

  defp quiet_for(pane) do
    case PaneState.map_get(pane, :liveness) do
      %{quiet_for_seconds: n} when is_integer(n) and n >= 0 ->
        n

      %{"quiet_for_seconds" => n} when is_integer(n) and n >= 0 ->
        n

      _ ->
        case PaneState.map_get(pane, :agent_state_age_s) do
          n when is_integer(n) and n >= 0 -> n
          _ -> -1
        end
    end
  end

  defp idle_or_ready?(pane) do
    case normalize_agent_state(PaneState.map_get(pane, :agent_state)) do
      state when state in [:idle, :done] ->
        true

      _ ->
        normalize_pane_state(PaneState.map_get(pane, :pane_state)) == :ready
    end
  end

  defp label_text(pane) do
    case PaneState.map_get(pane, :label) do
      text when is_binary(text) ->
        text

      %{label: text} when is_binary(text) ->
        text

      %{"label" => text} when is_binary(text) ->
        text

      _ ->
        PaneState.map_get(pane, :agent_label)
    end
  end

  # `manager` / `manager: note` / `manager - note` / `worker-slug` (spawn windows)
  defp role_token_rest("", role), do: role
  defp role_token_rest(<<sep, _::binary>>, role) when sep in [?:, ?\s, ?-, ?/], do: role
  defp role_token_rest(_, _), do: nil

  defp normalize_agent_state(state)
       when state in [:idle, :done, :working, :blocked, :errored, :stalled, :awaiting_input],
       do: state

  defp normalize_agent_state("idle"), do: :idle
  defp normalize_agent_state("done"), do: :done
  defp normalize_agent_state(_), do: nil

  defp normalize_pane_state(:ready), do: :ready
  defp normalize_pane_state("ready"), do: :ready
  defp normalize_pane_state(_), do: nil

  defp ready_seconds(opts) do
    case Keyword.get(opts, :ready_seconds, @default_ready_seconds) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_ready_seconds
    end
  end

  defp maybe_copy(target, source, key) do
    case Map.fetch(source, key) do
      {:ok, value} -> Map.put(target, key, value)
      :error -> target
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil
end
