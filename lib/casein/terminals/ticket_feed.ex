defmodule Casein.Terminals.TicketFeed do
  @moduledoc """
  Open GitHub work for **this** repo — issues and PRs — as an ETS snapshot
  refreshed off the LiveView render path.

  ## Why this exists

  `FleetBoard` answers "what is this pane doing?" from live topology. It cannot
  answer *which ticket that is* — a pane name is not work. This module is the
  ticket half of the join: one cached list of open issues and PRs that
  `FleetBoard.join_tickets/2` attaches to panes by issue binding, by `#NNNN` in
  the window label, or by **PR head branch → worktree branch**.

  The branch join is the one that matters on this fleet: Casein work is mostly
  PRs, and a worker on `agent/claude/fix-thing` has no issue binding and no
  `#NNNN` anywhere in its window name. Without it the drawer shows an unjoined
  ticket next to an unjoined pane for the same worker.

  ## Kind discipline

  Same contract as `OrphanedClaims` / `GateQueue` / `AgentLiveness`:

    * `{:error, _}` or never-observed → `observe_state: :unknown`. **Never** an
      empty `:ok`. A drawer that cannot reach `gh` must not render "no work".
    * `--state open` only. Merged is not live: closed/merged are dropped at the
      port, not filtered in chrome, so no `#1485`-style ghost can survive.

  ## Render-path discipline

  `cached/1` is a pure ETS read and never shells out. `refresh_async/1` is the
  only path that runs `gh`, on `Casein.TaskSupervisor`, at most once per
  `:ttl_ms` (default 120s), broadcasting on completion so subscribed cockpits
  re-render. **LiveView render calls `cached/1` only** — the pre-existing
  synchronous `gh` call on the topology path was a render-blocking shell-out
  every time its 30s cache missed.

  Branch resolution rides the same refresh: `Git.Inspector.inspect_cwd/1` per
  supplied worktree (itself TTL-cached), so a 15-window fleet resolves branches
  once per refresh instead of once per render.

  ## Scope

  One repo — the workspace's own. Cross-fleet aggregation is the LAN board's
  job, deliberately not this drawer's.
  """

  alias Casein.Git.Inspector
  alias Phoenix.PubSub

  @default_repo "dl-alexandre/casein"
  @default_ttl_ms 120_000
  @default_limit 100
  @cache_table :casein_ticket_feed_cache
  @topic "ticket_feed"

  @type ticket :: %{
          kind: :issue | :pr,
          number: pos_integer(),
          title: String.t() | nil,
          url: String.t() | nil,
          updated_at: DateTime.t() | nil,
          head_ref: String.t() | nil,
          draft?: boolean(),
          labels: [String.t()],
          priority: String.t() | nil,
          repo: String.t() | nil
        }

  @type snapshot :: %{
          observe_state: :ok | :unknown,
          reason: atom() | nil,
          tickets: [ticket()],
          by_number: %{pos_integer() => ticket()},
          by_head_ref: %{String.t() => ticket()},
          branch_by_worktree: %{String.t() => String.t()},
          observed_at: DateTime.t() | nil,
          source: :gh | :supplied | :unknown
        }

  @doc "Create the snapshot table (called from application start)."
  @spec ensure_table!() :: :ok
  def ensure_table! do
    case :ets.whereis(@cache_table) do
      :undefined ->
        :ets.new(@cache_table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end

  @doc "PubSub topic broadcast when a refresh lands."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribe the caller to refresh broadcasts."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: PubSub.subscribe(Casein.PubSub, @topic)

  @doc """
  Unknown-safe placeholder. Every absence path resolves here, never to an
  empty `:ok` snapshot.
  """
  @spec unknown(keyword()) :: snapshot()
  def unknown(opts \\ []) do
    %{
      observe_state: :unknown,
      reason: Keyword.get(opts, :reason, :unscanned),
      tickets: [],
      by_number: %{},
      by_head_ref: %{},
      branch_by_worktree: Keyword.get(opts, :branch_by_worktree, %{}),
      observed_at: nil,
      source: :unknown
    }
  end

  @doc ~S(True when observation has not succeeded — chrome must not claim "no work".)
  @spec unknown?(snapshot() | map()) :: boolean()
  def unknown?(%{observe_state: :unknown}), do: true
  def unknown?(_), do: false

  @doc "Operator-facing one-liner (never claims clear on unknown)."
  @spec summary(snapshot() | map()) :: String.t()
  def summary(%{observe_state: :ok, tickets: tickets}) do
    {prs, issues} = Enum.split_with(tickets, &(&1.kind == :pr))
    "#{length(issues)} open issues · #{length(prs)} open PRs"
  end

  def summary(%{observe_state: :unknown, reason: reason}) when not is_nil(reason) do
    "tickets unknown · #{reason}"
  end

  def summary(_), do: "tickets unknown"

  @doc """
  Pure ETS read of the last landed snapshot. Never shells out.

  Returns `unknown/1` when no refresh has landed yet, so a cold cockpit renders
  "unknown", not "no work".
  """
  @spec cached(keyword()) :: snapshot()
  def cached(opts \\ []) do
    ensure_table!()
    key = cache_key(opts)

    case :ets.lookup(@cache_table, {:snapshot, key}) do
      [{_, snapshot}] -> snapshot
      _ -> unknown(reason: :unscanned)
    end
  rescue
    ArgumentError -> unknown(reason: :no_cache)
  end

  @doc """
  Refresh in the background when the snapshot is older than `:ttl_ms`.

  Returns `:started`, `:fresh` (still inside TTL), or `:busy` (a refresh is in
  flight). Safe to call on every topology assign — the TTL and the in-flight
  lock are what keep `gh` off a 30s loop.

  Options:

    * `:worktrees` — paths whose branch should be resolved in this refresh
    * `:ttl_ms` — staleness window (default 120s)
    * `:repo` — target repo (default #{@default_repo})
    * `:force` — refresh even when fresh
  """
  @spec refresh_async(keyword()) :: :started | :fresh | :busy
  def refresh_async(opts \\ []) do
    ensure_table!()
    key = cache_key(opts)

    cond do
      not Keyword.get(opts, :force, false) and fresh?(key, opts) ->
        :fresh

      not claim_refresh(key, opts) ->
        :busy

      true ->
        start_refresh(key, opts)
    end
  end

  @doc """
  Synchronous observation — tests, MCP, and the async refresh body.

  Accepts injected `:tickets` (list or `{:error, reason}`) or a `:list_tickets`
  fun; otherwise shells `gh`. Stores the result and returns it.
  """
  @spec observe(keyword()) :: snapshot()
  def observe(opts \\ []) do
    source = if injected?(opts), do: :supplied, else: :gh
    branches = resolve_branches(opts)

    snapshot =
      case resolve_tickets(opts) do
        {:error, reason} ->
          unknown(reason: normalize_reason(reason), branch_by_worktree: branches)

        tickets when is_list(tickets) ->
          project(tickets, Keyword.put(opts, :branch_by_worktree, branches))
      end

    snapshot = Map.put(snapshot, :source, source)
    store(cache_key(opts), snapshot)
    snapshot
  end

  @doc """
  Pure projection of raw ticket maps into a snapshot (no I/O).

  Sorted newest-updated first — the drawer's continuous list takes its order
  from here, not from a bucket rank.
  """
  @spec project([map()], keyword()) :: snapshot()
  def project(raw, opts \\ []) when is_list(raw) do
    tickets =
      raw
      |> Enum.map(&normalize_ticket(&1, opts))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(&{&1.kind, &1.number})
      |> Enum.sort_by(&sort_key/1)

    %{
      observe_state: :ok,
      reason: nil,
      tickets: tickets,
      by_number: Map.new(tickets, &{&1.number, &1}),
      by_head_ref:
        tickets
        |> Enum.filter(&(&1.kind == :pr and is_binary(&1.head_ref)))
        |> Map.new(&{&1.head_ref, &1}),
      branch_by_worktree: Keyword.get(opts, :branch_by_worktree, %{}),
      observed_at: Keyword.get(opts, :now) || DateTime.utc_now(),
      source: Keyword.get(opts, :source, :supplied)
    }
  end

  @doc """
  Open `queue/claimed` issue numbers from a landed snapshot.

  Lets `OrphanedClaims` read the same cached observation instead of running its
  own synchronous `gh` on the render path.
  """
  @spec claimed_from(snapshot() | map(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  def claimed_from(snapshot, opts \\ [])

  def claimed_from(%{observe_state: :ok, tickets: tickets}, opts) do
    label = Keyword.get(opts, :workspace_label, "workspace/casein")

    claims =
      tickets
      |> Enum.filter(fn t ->
        t.kind == :issue and "queue/claimed" in t.labels and
          (is_nil(label) or label in t.labels)
      end)
      |> Enum.map(&Map.take(&1, [:number, :title, :url, :priority, :labels]))

    {:ok, claims}
  end

  def claimed_from(%{observe_state: :unknown, reason: reason}, _opts) do
    {:error, reason || :unscanned}
  end

  def claimed_from(_, _opts), do: {:error, :unscanned}

  ## Internals — refresh lifecycle

  defp fresh?(key, opts) do
    ttl = ttl_ms(opts)

    case :ets.lookup(@cache_table, {:observed_at, key}) do
      [{_, mono}] when is_integer(mono) ->
        System.monotonic_time(:millisecond) - mono < ttl

      _ ->
        false
    end
  end

  # Single-flight: a refresh in flight blocks another for one TTL, so a burst of
  # topology assigns cannot fan out into a burst of `gh`.
  defp claim_refresh(key, opts) do
    now = System.monotonic_time(:millisecond)
    deadline = now + ttl_ms(opts)

    case :ets.lookup(@cache_table, {:refreshing, key}) do
      [{_, until}] when is_integer(until) and until > now -> false
      _ -> :ets.insert(@cache_table, {{:refreshing, key}, deadline})
    end
  end

  defp release_refresh(key), do: :ets.delete(@cache_table, {:refreshing, key})

  defp start_refresh(key, opts) do
    task_opts = Keyword.take(opts, [:repo, :worktrees, :limit, :tickets, :list_tickets, :gh_env])

    case Task.Supervisor.start_child(Casein.TaskSupervisor, fn ->
           try do
             observe(task_opts)
             PubSub.broadcast(Casein.PubSub, @topic, {:ticket_feed, :refreshed, key})
           after
             release_refresh(key)
           end
         end) do
      {:ok, _pid} ->
        :started

      _ ->
        release_refresh(key)
        :busy
    end
  end

  defp store(key, snapshot) do
    ensure_table!()
    :ets.insert(@cache_table, {{:snapshot, key}, snapshot})
    :ets.insert(@cache_table, {{:observed_at, key}, System.monotonic_time(:millisecond)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  ## Internals — branch resolution

  defp resolve_branches(opts) do
    cond do
      is_map(Keyword.get(opts, :branch_by_worktree)) ->
        Keyword.get(opts, :branch_by_worktree)

      is_list(Keyword.get(opts, :worktrees)) ->
        branches_for(Keyword.fetch!(opts, :worktrees))

      true ->
        %{}
    end
  end

  defp branches_for(paths) do
    paths
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.reduce(%{}, &put_branch/2)
  end

  defp put_branch(path, acc) do
    case Inspector.inspect_cwd(path) do
      {:ok, %{branch: branch}} when is_binary(branch) and branch != "" ->
        Map.put(acc, path, branch)

      _ ->
        acc
    end
  end

  ## Internals — gh port

  defp injected?(opts) do
    Keyword.has_key?(opts, :tickets) or is_function(Keyword.get(opts, :list_tickets), 0) or
      is_function(Keyword.get(opts, :list_tickets), 1)
  end

  defp resolve_tickets(opts) do
    cond do
      Keyword.has_key?(opts, :tickets) ->
        unwrap(Keyword.get(opts, :tickets))

      is_function(Keyword.get(opts, :list_tickets), 0) ->
        unwrap(opts[:list_tickets].())

      is_function(Keyword.get(opts, :list_tickets), 1) ->
        unwrap(opts[:list_tickets].(opts))

      true ->
        unwrap(list_tickets(opts))
    end
  end

  defp unwrap({:ok, list}) when is_list(list), do: list
  defp unwrap({:error, reason}), do: {:error, reason}
  defp unwrap(list) when is_list(list), do: list
  defp unwrap(_), do: {:error, :bad_tickets}

  @doc """
  Shell `gh` for open issues + open PRs. Never returns an empty ok on transport
  failure — a partial result (one of the two calls failing) is an error, because
  half a fleet picture read as a whole one is worse than an honest unknown.
  """
  @spec list_tickets(keyword()) :: {:ok, [map()]} | {:error, atom()}
  def list_tickets(opts \\ []) do
    repo = Keyword.get(opts, :repo, @default_repo)

    if not is_binary(repo) or repo == "" do
      {:error, :bad_repo}
    else
      with {:ok, issues} <- gh_json(repo, :issue, opts),
           {:ok, prs} <- gh_json(repo, :pr, opts) do
        {:ok, tag_kind(issues, :issue) ++ tag_kind(prs, :pr)}
      end
    end
  end

  defp tag_kind(list, kind), do: Enum.map(list, &Map.put(&1, "__kind", kind))

  # Host-side `gh` only — the binary is the fixed string "gh" and every argument
  # is a literal or a repo/limit value, never a shell string. The variable
  # executable form is what Sobelow flags; we never take one from caller input.
  # sobelow_skip ["CI.System"]
  defp gh_json(repo, kind, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)

    fields =
      case kind do
        :issue -> "number,title,url,updatedAt,labels"
        :pr -> "number,title,url,updatedAt,labels,headRefName,isDraft"
      end

    args = [
      to_string(kind),
      "list",
      "--repo",
      repo,
      "--state",
      "open",
      "--json",
      fields,
      "--limit",
      to_string(limit)
    ]

    case System.cmd("gh", args, env: gh_env(opts), stderr_to_stdout: true) do
      {body, 0} ->
        case Jason.decode(body) do
          {:ok, list} when is_list(list) -> {:ok, list}
          _ -> {:error, :bad_gh_json}
        end

      {_body, _code} ->
        {:error, :gh_failed}
    end
  rescue
    _ -> {:error, :gh_unavailable}
  end

  # Identity for read-only `gh issue list`. See `Casein.Identity.gh_env/1` —
  # this used to hardcode one engineer's config dir as the fallback.
  defp gh_env(opts), do: Casein.Identity.gh_env(opts)

  ## Internals — normalization

  defp normalize_ticket(raw, opts) when is_map(raw) do
    number = normalize_number(get(raw, :number))

    if is_nil(number) do
      nil
    else
      labels = normalize_labels(get(raw, :labels) || [])
      head_ref = blank_to_nil(get(raw, :headRefName) || get(raw, :head_ref))

      %{
        kind: normalize_kind(raw, head_ref),
        number: number,
        title: blank_to_nil(get(raw, :title)),
        url: blank_to_nil(get(raw, :url)),
        updated_at: normalize_time(get(raw, :updatedAt) || get(raw, :updated_at)),
        head_ref: head_ref,
        draft?: get(raw, :isDraft) == true or get(raw, :draft?) == true,
        labels: labels,
        priority: priority_from_labels(labels),
        repo: Keyword.get(opts, :repo, @default_repo)
      }
    end
  end

  defp normalize_ticket(_, _), do: nil

  defp normalize_kind(raw, head_ref) do
    case get(raw, :__kind) || get(raw, :kind) do
      k when k in [:pr, "pr"] -> :pr
      k when k in [:issue, "issue"] -> :issue
      # A head branch is the only unambiguous PR tell when kind is absent.
      _ -> if is_binary(head_ref), do: :pr, else: :issue
    end
  end

  defp get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp normalize_number(n) when is_integer(n) and n > 0, do: n

  defp normalize_number(n) when is_binary(n) do
    case Integer.parse(String.trim_leading(String.trim(n), "#")) do
      {i, _} when i > 0 -> i
      _ -> nil
    end
  end

  defp normalize_number(_), do: nil

  defp normalize_time(%DateTime{} = dt), do: dt

  defp normalize_time(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp normalize_time(_), do: nil

  defp normalize_labels(labels) when is_list(labels) do
    Enum.flat_map(labels, fn
      name when is_binary(name) -> [name]
      %{name: name} when is_binary(name) -> [name]
      %{"name" => name} when is_binary(name) -> [name]
      _ -> []
    end)
  end

  defp normalize_labels(_), do: []

  defp priority_from_labels(labels) do
    cond do
      "priority/p0" in labels -> "p0"
      "priority/p1" in labels -> "p1"
      "priority/p2" in labels -> "p2"
      true -> nil
    end
  end

  # Newest-updated first; tickets with no timestamp sink rather than float, so a
  # missing `updatedAt` cannot masquerade as the freshest work.
  defp sort_key(%{updated_at: %DateTime{} = dt, number: n}), do: {0, -DateTime.to_unix(dt), n}
  defp sort_key(%{number: n}), do: {1, 0, n}

  defp normalize_reason(reason) when is_atom(reason), do: reason
  defp normalize_reason(_), do: :error

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp ttl_ms(opts) do
    case Keyword.get(opts, :ttl_ms, @default_ttl_ms) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_ttl_ms
    end
  end

  defp cache_key(opts), do: Keyword.get(opts, :repo, @default_repo)
end
