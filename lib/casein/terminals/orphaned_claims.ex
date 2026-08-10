defmodule Casein.Terminals.OrphanedClaims do
  @moduledoc """
  Operator projection: **open `queue/claimed` issues with no live IssueBinding**.

  A claim is a lease. GitHub labels alone cannot answer "is anyone on #N?" —
  that is `IssueBinding`. The inverse gap (claimed-on-GH, unbound in topology)
  left p0 work invisible on the fleet board (#812).

  ## Kind discipline

  Same contract as `AgentLiveness` / `GateQueue`:

    * `{:error, reason}` / unscanned → `observe_state: :unknown`. **Never**
      render as calm/empty/no-orphans.
    * `{:ok, claims}` fed through `project/2` → `observe_state: :ok` with an
      explicit orphan list (may be empty).

  ## Ports

  This module does not scrape GitHub inside LiveView render. Callers supply
  the claimed set (tests, Ops helper, or `list_claimed/1` which shells out to
  `gh` when configured). Bindings come from live topology / `IssueBinding`.

  Attention membership reuses fleet `needs_you` counting — orphans are
  operator work, ranked via `Casein.Attention.Delivery.session_reason_urgency/1`
  with reason `:orphaned_claim` (not a second ranker).
  """

  alias Casein.Attention.Delivery
  alias Casein.Terminals.IssueBinding

  @default_repo "dl-alexandre/casein"
  @default_workspace_label "workspace/casein"
  @default_cache_ttl_ms 30_000
  @cache_table :casein_orphaned_claims_cache

  @type claim :: %{
          number: pos_integer(),
          title: String.t() | nil,
          url: String.t() | nil,
          priority: String.t() | nil,
          labels: [String.t()]
        }

  @type orphan :: %{
          number: pos_integer(),
          title: String.t() | nil,
          url: String.t() | nil,
          priority: String.t() | nil,
          labels: [String.t()],
          attention_reason: :orphaned_claim,
          needs_you?: true
        }

  @type snapshot :: %{
          observe_state: :ok | :unknown,
          reason: atom() | nil,
          orphans: [orphan()],
          orphan_count: non_neg_integer() | nil,
          claimed_count: non_neg_integer() | nil,
          bound_count: non_neg_integer() | nil,
          claimed: [claim()],
          bound_issues: [pos_integer()],
          observed_at: DateTime.t() | nil,
          source: :supplied | :gh | :unknown
        }

  @doc "Empty / unknown-safe placeholder when observation has not run."
  @spec unknown(keyword()) :: snapshot()
  def unknown(opts \\ []) do
    %{
      observe_state: :unknown,
      reason: Keyword.get(opts, :reason, :unscanned),
      orphans: [],
      orphan_count: nil,
      claimed_count: nil,
      bound_count: nil,
      claimed: [],
      bound_issues: [],
      observed_at: nil,
      source: :unknown
    }
  end

  @doc "True when observation succeeded and at least one orphan exists."
  @spec any?(snapshot() | map()) :: boolean()
  def any?(%{observe_state: :ok, orphan_count: n}) when is_integer(n) and n > 0, do: true
  def any?(_), do: false

  @doc """
  True when observation failed or has not run — UI must not claim "no orphans".
  """
  @spec unknown?(snapshot() | map()) :: boolean()
  def unknown?(%{observe_state: :unknown}), do: true
  def unknown?(_), do: false

  @doc "Operator-facing one-line summary (never claims clear on unknown)."
  @spec summary(snapshot() | map()) :: String.t()
  def summary(%{observe_state: :ok, orphan_count: 0}), do: "no orphaned claims"

  def summary(%{observe_state: :ok, orphan_count: n}) when is_integer(n) and n > 0 do
    "orphaned claims · #{n}"
  end

  def summary(%{observe_state: :unknown, reason: reason}) when not is_nil(reason) do
    "orphaned claims unknown · #{reason}"
  end

  def summary(%{observe_state: :unknown}), do: "orphaned claims unknown"
  def summary(_), do: "orphaned claims unknown"

  @doc "Urgency for sort — delegates to shared Delivery table."
  @spec urgency() :: non_neg_integer()
  def urgency, do: Delivery.session_reason_urgency(:orphaned_claim)

  @doc """
  Pure projection: claimed issues minus live bindings.

  `claimed` accepts maps with `:number` / `"number"` and optional title/url/labels.
  `bound` accepts integers, binding entries, pane→entry maps, or tab rows with `:issue`.
  """
  @spec project(term(), term(), keyword()) :: snapshot()
  def project(claimed, bound, opts \\ [])

  def project({:error, reason}, bound, opts) do
    unknown(reason: normalize_reason(reason))
    |> Map.put(:bound_issues, normalize_bound(bound))
    |> Map.put(:bound_count, length(normalize_bound(bound)))
    |> Map.put(:observed_at, Keyword.get(opts, :now) || DateTime.utc_now())
    |> Map.put(:source, Keyword.get(opts, :source, :unknown))
  end

  def project(claimed, bound, opts) when is_list(claimed) or is_map(claimed) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    claims = normalize_claimed(claimed)
    bound_issues = normalize_bound(bound)
    bound_set = MapSet.new(bound_issues)

    orphans =
      claims
      |> Enum.reject(fn %{number: n} -> MapSet.member?(bound_set, n) end)
      |> Enum.map(&to_orphan/1)
      |> Enum.sort_by(&orphan_sort_key/1)

    %{
      observe_state: :ok,
      reason: nil,
      orphans: orphans,
      orphan_count: length(orphans),
      claimed_count: length(claims),
      bound_count: length(bound_issues),
      claimed: claims,
      bound_issues: bound_issues,
      observed_at: now,
      source: Keyword.get(opts, :source, :supplied)
    }
  end

  def project(_claimed, bound, opts) do
    project({:error, :bad_claimed}, bound, opts)
  end

  @doc """
  Observe orphaned claims for a session.

  Options:

    * `:claimed` — precomputed claim list or `{:error, reason}` (tests / inject)
    * `:bound` — binding map, issue list, or window tabs (default: empty)
    * `:tmux_session` — when set and `:bound` omitted, read `IssueBinding.for_session/1`
    * `:list_claimed` — zero-arity or 1-arity fun returning claims or `{:error, _}`
    * `:repo`, `:workspace_label` — for default `gh` list
    * `:cache` — false to force refresh (default true)
    * `:cache_ttl_ms` — default #{@default_cache_ttl_ms}
    * `:now` — reference time
  """
  @spec observe(keyword()) :: snapshot()
  def observe(opts \\ []) do
    bound = resolve_bound(opts)
    source_tag = if Keyword.has_key?(opts, :claimed), do: :supplied, else: :gh

    case resolve_claimed(opts) do
      {:error, reason} ->
        project({:error, reason}, bound, Keyword.put(opts, :source, source_tag))

      claimed when is_list(claimed) ->
        project(claimed, bound, Keyword.put(opts, :source, source_tag))
    end
  end

  @doc """
  List open `queue/claimed` issues via `gh` (host-side port).

  Returns `{:ok, [claim]}` or `{:error, reason}`. Never returns an empty ok on
  transport failure — callers must treat error as unknown.
  """
  @spec list_claimed(keyword()) :: {:ok, [claim()]} | {:error, atom()}
  def list_claimed(opts \\ []) do
    if Keyword.get(opts, :cache, true) do
      case cache_lookup(cache_key(opts)) do
        {:ok, claims} -> {:ok, claims}
        :miss -> list_claimed_uncached(opts)
      end
    else
      list_claimed_uncached(opts)
    end
  end

  ## Internals

  defp resolve_bound(opts) do
    cond do
      Keyword.has_key?(opts, :bound) ->
        Keyword.get(opts, :bound)

      is_binary(Keyword.get(opts, :tmux_session)) ->
        IssueBinding.for_session(Keyword.fetch!(opts, :tmux_session))

      true ->
        []
    end
  end

  defp resolve_claimed(opts) do
    cond do
      Keyword.has_key?(opts, :claimed) ->
        unwrap_claimed(Keyword.get(opts, :claimed))

      is_function(Keyword.get(opts, :list_claimed), 0) ->
        unwrap_claimed(opts[:list_claimed].())

      is_function(Keyword.get(opts, :list_claimed), 1) ->
        unwrap_claimed(opts[:list_claimed].(opts))

      true ->
        unwrap_claimed(list_claimed(opts))
    end
  end

  defp unwrap_claimed({:ok, list}) when is_list(list), do: list
  defp unwrap_claimed({:error, reason}), do: {:error, reason}
  defp unwrap_claimed(list) when is_list(list), do: list
  defp unwrap_claimed(_), do: {:error, :bad_claimed}

  # Host-side `gh` only — binary is the fixed string "gh", args are label/repo
  # filters (not shell). Injection risk is the variable-executable form Sobelow
  # flags; we never take the executable from caller input.
  # sobelow_skip ["CI.System"]
  defp list_claimed_uncached(opts) do
    repo = Keyword.get(opts, :repo, @default_repo)
    workspace_label = Keyword.get(opts, :workspace_label, @default_workspace_label)

    if not is_binary(repo) or repo == "" do
      {:error, :bad_repo}
    else
      args = [
        "issue",
        "list",
        "--repo",
        repo,
        "--label",
        "queue/claimed",
        "--label",
        workspace_label,
        "--state",
        "open",
        "--json",
        "number,title,url,labels",
        "--limit",
        "100"
      ]

      env = gh_env(opts)

      case System.cmd("gh", args, env: env, stderr_to_stdout: true) do
        {body, 0} ->
          case decode_issues(body) do
            {:ok, claims} ->
              cache_put(cache_key(opts), claims, opts)
              {:ok, claims}

            {:error, reason} ->
              {:error, reason}
          end

        {_body, _code} ->
          {:error, :gh_failed}
      end
    end
  rescue
    error ->
      _ = error
      {:error, :gh_unavailable}
  end

  defp gh_env(opts) do
    config_dir =
      Keyword.get(opts, :gh_config_dir) ||
        System.get_env("GH_CONFIG_DIR") ||
        default_gh_config_dir()

    base = [
      {"GH_TOKEN", ""},
      {"GITHUB_TOKEN", ""},
      {"GH_PROMPT_DISABLED", "1"},
      {"GH_NO_UPDATE_NOTIFIER", "1"}
    ]

    if is_binary(config_dir) and config_dir != "" do
      [{"GH_CONFIG_DIR", config_dir} | base]
    else
      base
    end
  end

  defp default_gh_config_dir do
    Path.expand("~/.config/gh-dalexandre")
  end

  defp decode_issues(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, list} when is_list(list) ->
        {:ok, normalize_claimed(list)}

      {:ok, _} ->
        {:error, :bad_gh_json}

      {:error, _} ->
        {:error, :bad_gh_json}
    end
  end

  defp normalize_claimed(list) when is_list(list) do
    list
    |> Enum.map(&normalize_claim/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.number)
    |> Enum.sort_by(& &1.number)
  end

  defp normalize_claimed(_), do: []

  defp normalize_claim(raw) when is_map(raw) do
    number =
      case Map.get(raw, :number) || Map.get(raw, "number") || Map.get(raw, :issue) ||
             Map.get(raw, "issue") do
        n when is_integer(n) and n > 0 -> n
        n when is_binary(n) -> IssueBinding.normalize_issue(n)
        _ -> nil
      end

    if is_nil(number) do
      nil
    else
      labels = normalize_labels(Map.get(raw, :labels) || Map.get(raw, "labels") || [])

      %{
        number: number,
        title: blank_to_nil(Map.get(raw, :title) || Map.get(raw, "title")),
        url: blank_to_nil(Map.get(raw, :url) || Map.get(raw, "url")),
        priority: priority_from_labels(labels),
        labels: labels
      }
    end
  end

  defp normalize_claim(n) when is_integer(n) and n > 0 do
    %{number: n, title: nil, url: nil, priority: nil, labels: []}
  end

  defp normalize_claim(n) when is_binary(n) do
    case IssueBinding.normalize_issue(n) do
      nil -> nil
      number -> %{number: number, title: nil, url: nil, priority: nil, labels: []}
    end
  end

  defp normalize_claim(_), do: nil

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

  defp normalize_bound(bound) when is_list(bound) do
    bound
    |> Enum.flat_map(&bound_numbers/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_bound(bound) when is_map(bound) do
    # pane_id => entry, or a single claim-like map
    cond do
      match?(%{issue: _}, bound) or match?(%{"issue" => _}, bound) or
          match?(%{number: _}, bound) ->
        bound_numbers(bound)

      true ->
        bound
        |> Map.values()
        |> Enum.flat_map(&bound_numbers/1)
        |> Enum.uniq()
        |> Enum.sort()
    end
  end

  defp normalize_bound(_), do: []

  defp bound_numbers(%{issue: n}) when is_integer(n) and n > 0, do: [n]
  defp bound_numbers(%{"issue" => n}) when is_integer(n) and n > 0, do: [n]
  defp bound_numbers(%{number: n}) when is_integer(n) and n > 0, do: [n]
  defp bound_numbers(%{"number" => n}) when is_integer(n) and n > 0, do: [n]
  defp bound_numbers(n) when is_integer(n) and n > 0, do: [n]

  defp bound_numbers(n) when is_binary(n) do
    case IssueBinding.normalize_issue(n) do
      nil -> []
      i -> [i]
    end
  end

  defp bound_numbers(_), do: []

  defp to_orphan(claim) do
    %{
      number: claim.number,
      title: claim.title,
      url: claim.url,
      priority: claim.priority,
      labels: claim.labels,
      attention_reason: :orphaned_claim,
      needs_you?: true
    }
  end

  defp orphan_sort_key(orphan) do
    {
      priority_rank(orphan.priority),
      Delivery.session_reason_urgency(:orphaned_claim),
      orphan.number
    }
  end

  defp priority_rank("p0"), do: 0
  defp priority_rank("p1"), do: 1
  defp priority_rank("p2"), do: 2
  defp priority_rank(_), do: 3

  defp normalize_reason(reason) when is_atom(reason), do: reason
  defp normalize_reason(_), do: :error

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp cache_key(opts) do
    {
      Keyword.get(opts, :repo, @default_repo),
      Keyword.get(opts, :workspace_label, @default_workspace_label)
    }
  end

  defp cache_lookup(key) do
    ensure_cache_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@cache_table, key) do
      [{^key, claims, expires_at}] when is_integer(expires_at) and expires_at > now ->
        {:ok, claims}

      _ ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp cache_put(key, claims, opts) do
    ensure_cache_table()
    ttl = Keyword.get(opts, :cache_ttl_ms, @default_cache_ttl_ms)
    ttl = if is_integer(ttl) and ttl > 0, do: ttl, else: @default_cache_ttl_ms
    expires = System.monotonic_time(:millisecond) + ttl
    true = :ets.insert(@cache_table, {key, claims, expires})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp ensure_cache_table do
    case :ets.whereis(@cache_table) do
      :undefined ->
        :ets.new(@cache_table, [:named_table, :public, :set, read_concurrency: true])

      _ ->
        @cache_table
    end
  end
end
