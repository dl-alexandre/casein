defmodule Casein.Terminals.PaneLiveness do
  @moduledoc """
  Joins tmux panes to their worktrees, and each worktree to observed liveness.

  tmux already tracks `pane_current_path` for every pane, so the pane → worktree
  link needs no reporting from the agent and survives an agent that has stopped
  answering. That makes it the right join key for two questions an orchestrator
  running a fleet of agent windows has to answer constantly:

    * **Is this agent actually working?** — `Casein.Terminals.AgentLiveness`
      observes the worktree from outside (see its moduledoc for why cooperative
      signals cannot answer this).

    * **Are two windows about to corrupt each other's git state?** — panes whose
      cwd resolves to the same worktree share one index. Adoption of an existing
      worktree is deliberate (`scripts/lib/agent-worktree.sh`), so this is a
      warning rather than a refusal, but it must be *visible*: three agents
      running `git` in one directory is not a state you should have to discover
      by running `tmux list-panes` yourself.

  Enrichment is opt-in because a worktree walk is not free. Callers that render
  on every LiveView update should pass `liveness: false` and refresh on a slower
  cadence — `refresh_async/3` + `cached/1` below are that cadence.

  ## Cockpit cadence (#916 follow-up)

  The cockpit never observed liveness at all: `SessionBarVM` read a `:liveness`
  key that only the MCP topology path (`include_liveness: true`) ever attached.
  So `FleetBoard`'s liveness-based classification — the whole point of #917 —
  was unreachable from the drawer, and every hook-less pane bucketed `:unknown`
  with `agent_state_absent_liveness_not_observed`.

  `refresh_async/3` observes a session's agent panes on a Task, caches the
  result per session, and broadcasts so viewers rebuild. `cached/1` is a pure
  ETS read for the render path. A pane that cannot be observed is stored as
  `%{state: :unknown, reason: reason}` rather than omitted: an omission decays
  into "not observed", which is strictly less information than the reason we
  already hold.

  ## Transcript evidence

  `transcript: true` adds a third answer, to the question the other two cannot
  reach: **is this agent waiting for me?** A worktree looks the same whether the
  agent finished, asked a question, or hit a permission prompt, and the pane
  title is ambiguous by construction (see `Casein.Terminals.AgentState`). The
  shape of the last turn in the agent's own session transcript is not — see
  `Casein.Agents.Transcripts.Evidence`.

  The pane → transcript join runs through the same cwd tmux already tracks, so
  like liveness it needs nothing from the agent. It is off by default: it costs
  a directory listing and a bounded tail read per agent pane, and it is only
  meaningful for panes running a Claude Code CLI.
  """

  alias Casein.Agents.Transcripts
  alias Casein.Agents.Transcripts.Evidence
  alias Casein.Git.Inspector
  alias Casein.Terminals.AgentLiveness
  alias Casein.Terminals.PaneState

  @type liveness_state :: :active | :quiet | :unknown

  @doc """
  Enrich a topology's panes with `:worktree_path`, `:worktree_shared_with` and
  (unless disabled) `:liveness`.

  Options:

    * `:liveness` — set `false` to resolve worktrees only (default `true`)
    * `:window_seconds` — activity window passed to `AgentLiveness.classify/2`
    * `:agent_panes_only` — only observe liveness for role-tagged agent panes
      (default `true`); a plain shell's cwd is not an agent worktree
    * `:transcript` — set `true` to attach `:transcript` conversation-shape
      evidence (default `false`; see "Transcript evidence" above)
    * `:owner` — profile slug whose Claude auth home holds the transcripts
  """
  @spec enrich_topology(map(), keyword()) :: map()
  def enrich_topology(topology, opts \\ [])

  def enrich_topology(%{panes: panes} = topology, opts) when is_list(panes) do
    worktrees = resolve_worktrees(panes)
    shared = shared_worktrees(panes, worktrees)
    observations = observe_all(panes, worktrees, opts)

    panes =
      Enum.map(panes, fn pane ->
        pane_id = PaneState.map_get(pane, :id)
        worktree = Map.get(worktrees, pane_id)

        pane
        |> put_worktree(worktree)
        |> put_shared(shared, worktree, pane_id)
        |> put_liveness(Map.get(observations, worktree), opts)
        |> put_transcript(opts)
      end)

    %{topology | panes: panes}
  end

  def enrich_topology(topology, _opts), do: topology

  ## Cockpit cadence — cached async observation

  @cache_table :casein_pane_liveness_cockpit_cache
  @topic "pane_liveness"
  @default_ttl_ms 20_000

  @doc "Create the cockpit snapshot table (called from application start)."
  @spec ensure_cockpit_cache!() :: :ok
  def ensure_cockpit_cache! do
    case :ets.whereis(@cache_table) do
      :undefined ->
        :ets.new(@cache_table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end

  @doc "PubSub topic broadcast when a cockpit liveness refresh lands."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribe the caller to cockpit liveness refreshes."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Casein.PubSub, @topic)

  @doc """
  Pure ETS read of the last landed observation for a session.

  Returns `%{pane_id => %{liveness: map, worktree_path: path | nil}}`, or an
  empty map before any refresh has landed. Never walks a worktree — safe on the
  render path. An empty map means *not yet observed*, which `FleetBoard` renders
  as `:unknown` with a reason, never as quiet.
  """
  @spec cached(String.t() | nil) :: %{optional(String.t()) => map()}
  def cached(session) when is_binary(session) and session != "" do
    ensure_cockpit_cache!()

    case :ets.lookup(@cache_table, {:snapshot, session}) do
      [{_, snapshot}] -> snapshot
      _ -> %{}
    end
  rescue
    ArgumentError -> %{}
  end

  def cached(_session), do: %{}

  @doc """
  Observe `panes` for `session` in the background when the last look is stale.

  Returns `:started`, `:fresh` (inside `:ttl_ms`, default 20s) or `:busy` (an
  observation is already in flight). Safe to call on every topology assign — the
  TTL and the single-flight lock are what keep worktree walks off a render loop.

  Pass only the panes worth observing (agent panes); a plain shell's cwd is not
  an agent worktree.
  """
  @spec refresh_async(String.t() | nil, [map()], keyword()) :: :started | :fresh | :busy | :skip
  def refresh_async(session, panes, opts \\ [])

  def refresh_async(session, panes, opts) when is_binary(session) and is_list(panes) do
    ensure_cockpit_cache!()

    cond do
      panes == [] -> :skip
      not Keyword.get(opts, :force, false) and cockpit_fresh?(session, opts) -> :fresh
      not claim_cockpit_refresh(session, opts) -> :busy
      true -> start_cockpit_refresh(session, panes, opts)
    end
  end

  def refresh_async(_session, _panes, _opts), do: :skip

  @doc """
  Observe now and store — the body of `refresh_async/3`, exposed for tests.
  """
  @spec observe_panes(String.t(), [map()], keyword()) :: %{optional(String.t()) => map()}
  def observe_panes(session, panes, opts \\ []) when is_binary(session) and is_list(panes) do
    snapshot =
      Enum.reduce(panes, %{}, fn pane, acc ->
        case PaneState.map_get(pane, :id) do
          id when is_binary(id) and id != "" -> Map.put(acc, id, observation_entry(pane, opts))
          _ -> acc
        end
      end)

    store_cockpit(session, snapshot)
    snapshot
  end

  # An unobservable pane keeps its reason. Dropping it would decay into
  # "not observed", which says less than what we already know.
  defp observation_entry(pane, opts) do
    case observe_pane(pane, opts) do
      {:ok, worktree, liveness} ->
        %{liveness: liveness, worktree_path: worktree}

      {:error, reason} ->
        %{
          liveness: %{state: :unknown, reason: reason},
          worktree_path: pane_worktree(pane)
        }
    end
  end

  defp cockpit_fresh?(session, opts) do
    ttl = cockpit_ttl_ms(opts)

    case :ets.lookup(@cache_table, {:observed_at, session}) do
      [{_, mono}] when is_integer(mono) ->
        System.monotonic_time(:millisecond) - mono < ttl

      _ ->
        false
    end
  end

  defp claim_cockpit_refresh(session, opts) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@cache_table, {:refreshing, session}) do
      [{_, until}] when is_integer(until) and until > now -> false
      _ -> :ets.insert(@cache_table, {{:refreshing, session}, now + cockpit_ttl_ms(opts)})
    end
  end

  defp start_cockpit_refresh(session, panes, opts) do
    observe_opts = Keyword.take(opts, [:window_seconds, :git, :now])

    case Task.Supervisor.start_child(Casein.TaskSupervisor, fn ->
           try do
             observe_panes(session, panes, observe_opts)

             Phoenix.PubSub.broadcast(
               Casein.PubSub,
               @topic,
               {:pane_liveness, :refreshed, session}
             )
           after
             :ets.delete(@cache_table, {:refreshing, session})
           end
         end) do
      {:ok, _pid} ->
        :started

      _ ->
        :ets.delete(@cache_table, {:refreshing, session})
        :busy
    end
  end

  defp store_cockpit(session, snapshot) do
    ensure_cockpit_cache!()
    :ets.insert(@cache_table, {{:snapshot, session}, snapshot})
    :ets.insert(@cache_table, {{:observed_at, session}, System.monotonic_time(:millisecond)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp cockpit_ttl_ms(opts) do
    case Keyword.get(opts, :ttl_ms, @default_ttl_ms) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_ttl_ms
    end
  end

  @doc """
  Worktree paths in this topology that more than one pane is sitting in, mapped
  to the pane ids sharing them.

  Only panes that resolve to a real worktree are counted, so several shells in
  the same non-repo directory are not flagged.
  """
  @spec shared_worktrees(map() | [map()]) :: %{optional(String.t()) => [String.t()]}
  def shared_worktrees(%{panes: panes}) when is_list(panes), do: shared_worktrees(panes)

  def shared_worktrees(panes) when is_list(panes) do
    shared_worktrees(panes, resolve_worktrees(panes))
  end

  def shared_worktrees(_topology), do: %{}

  @doc """
  Observe one pane's worktree directly.

  Returns `{:ok, worktree_path, liveness}` or `{:error, reason}`. Distinct from
  the enrichment path so the MCP tool can report *why* an observation is
  missing rather than silently omitting the pane.
  """
  @spec observe_pane(map(), keyword()) ::
          {:ok, String.t(), map()} | {:error, :no_worktree | AgentLiveness.error_reason()}
  def observe_pane(pane, opts \\ []) when is_map(pane) do
    case pane_worktree(pane) do
      nil ->
        {:error, :no_worktree}

      worktree ->
        case AgentLiveness.observe(worktree, opts) do
          {:ok, observation} -> {:ok, worktree, liveness_map(observation, opts)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Resolve a pane's worktree root from its tmux cwd, or nil.

  Uses the cached git inspector, so repeated calls across a topology cost one
  `rev-parse` per distinct directory.
  """
  @spec pane_worktree(map()) :: String.t() | nil
  def pane_worktree(pane) when is_map(pane) do
    case PaneState.map_get(pane, :current_path) do
      path when is_binary(path) and path != "" -> toplevel(path)
      _ -> nil
    end
  end

  def pane_worktree(_pane), do: nil

  ## Internals

  defp resolve_worktrees(panes) do
    # Panes in one window usually share a cwd; resolve each distinct directory
    # once rather than once per pane.
    panes
    |> Enum.reduce({%{}, %{}}, fn pane, {by_pane, by_dir} ->
      pane_id = PaneState.map_get(pane, :id)
      dir = PaneState.map_get(pane, :current_path)

      case dir do
        path when is_binary(path) and path != "" ->
          {worktree, by_dir} =
            case Map.fetch(by_dir, path) do
              {:ok, cached} -> {cached, by_dir}
              :error -> resolve_and_memo(path, by_dir)
            end

          {maybe_put(by_pane, pane_id, worktree), by_dir}

        _ ->
          {by_pane, by_dir}
      end
    end)
    |> elem(0)
  end

  defp resolve_and_memo(path, by_dir) do
    worktree = toplevel(path)
    {worktree, Map.put(by_dir, path, worktree)}
  end

  defp toplevel(path) do
    case Inspector.inspect_cwd(path) do
      {:ok, %Inspector{toplevel: toplevel}} when is_binary(toplevel) and toplevel != "" ->
        toplevel

      _ ->
        nil
    end
  end

  defp shared_worktrees(panes, worktrees) do
    panes
    |> Enum.map(&PaneState.map_get(&1, :id))
    |> Enum.filter(&Map.has_key?(worktrees, &1))
    |> Enum.group_by(&Map.fetch!(worktrees, &1))
    |> Enum.filter(fn {_worktree, pane_ids} -> length(pane_ids) > 1 end)
    |> Map.new()
  end

  defp observe_all(panes, worktrees, opts) do
    if Keyword.get(opts, :liveness, true) do
      panes
      |> Enum.filter(&observable?(&1, opts))
      |> Enum.map(&PaneState.map_get(&1, :id))
      |> Enum.map(&Map.get(worktrees, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Map.new(&{&1, AgentLiveness.observe(&1, opts)})
    else
      %{}
    end
  end

  defp observable?(pane, opts) do
    if Keyword.get(opts, :agent_panes_only, true) do
      PaneState.agent_role?(pane)
    else
      true
    end
  end

  defp put_worktree(pane, nil), do: pane
  defp put_worktree(pane, worktree), do: Map.put(pane, :worktree_path, worktree)

  defp put_shared(pane, _shared, nil, _pane_id), do: pane

  defp put_shared(pane, shared, worktree, pane_id) do
    case Map.get(shared, worktree) do
      nil ->
        pane

      pane_ids ->
        Map.put(pane, :worktree_shared_with, Enum.reject(pane_ids, &(&1 == pane_id)))
    end
  end

  defp put_liveness(pane, nil, _opts), do: pane

  defp put_liveness(pane, {:ok, observation}, opts),
    do: Map.put(pane, :liveness, liveness_map(observation, opts))

  # An unscannable worktree is reported as :unknown *with its reason*, never
  # omitted and never quietly downgraded to :quiet. A caller that cannot tell
  # "nothing happened" from "the check did not run" will report false stalls.
  defp put_liveness(pane, {:error, reason}, _opts),
    do: Map.put(pane, :liveness, %{state: :unknown, reason: reason})

  # Only agent panes, and only on request: this costs a directory listing plus a
  # tail read per pane. A plain shell sharing the agent's worktree would resolve
  # to the agent's own transcript, so `agent_panes_only` is doing load-bearing
  # correctness work here, not just saving syscalls.
  defp put_transcript(pane, opts) do
    if Keyword.get(opts, :transcript, false) and observable?(pane, opts) do
      Map.put(pane, :transcript, transcript_evidence(pane, opts))
    else
      pane
    end
  end

  defp transcript_evidence(pane, opts) do
    with {:ok, path} <- discover_transcript(pane, opts),
         {:ok, observation} <- Transcripts.evidence(path, opts) do
      %{
        state: Evidence.classify(observation, opts),
        transcript_path: path,
        last_shape: observation.last_shape,
        silent_for_seconds: observation.silent_for_seconds
      }
    else
      # Same discipline as liveness: report *why* there is no verdict rather
      # than omitting the pane, so "no transcript found" cannot be mistaken for
      # "this agent is not waiting".
      {:error, reason} -> %{state: :unknown, reason: reason}
    end
  end

  # The transcript directory is keyed on the cwd the agent was launched in.
  # That is normally the worktree root, but a pane that has since `cd`-ed
  # elsewhere still belongs to its launch directory, so the worktree is tried as
  # a fallback.
  defp discover_transcript(pane, opts) do
    cwd = PaneState.map_get(pane, :current_path)
    worktree = pane_worktree(pane)

    case Transcripts.discover(cwd, opts) do
      {:ok, path} -> {:ok, path}
      {:error, reason} when worktree in [nil, cwd] -> {:error, reason}
      {:error, _reason} -> Transcripts.discover(worktree, opts)
    end
  end

  defp liveness_map(observation, opts) do
    %{
      state: AgentLiveness.classify(observation, opts),
      last_write_at: observation.last_write_at,
      quiet_for_seconds: observation.quiet_for_seconds,
      head_sha: observation.head_sha,
      commit_count: observation.commit_count,
      files_scanned: observation.files_scanned,
      truncated?: observation.truncated?
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
