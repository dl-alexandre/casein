defmodule Casein.Terminals.AgentProgress do
  @moduledoc """
  Composite **agent progress** for fleet summary (#879).

  Process/CPU (`PaneProcessLiveness`) answers "is the pane process still
  running?". That is necessary and **not** sufficient: a wedged worker can burn
  hours of CPU with a frozen build timer, stuck context %, stuck spend, and
  zero commits while jiffies still advance.

  This module samples independent axes and classifies:

    * `:progressing` — at least one strong progress signal moved
    * `:running_but_not_progressing` — process is active **and** ≥2 independent
      axes show no progress (the state that costs fleet time)
    * `:quiet` — process quiet and no progress signals
    * `:unknown` — not enough samples / sensors failed (never collapsed to quiet)

  Axes (each optional; missing sensors do not invent disagreement):

    * process CPU — necessary-not-sufficient presence
    * worktree — commit count **and** `git status --porcelain` fingerprint;
      rebase/merge via `git rev-parse --git-dir` (linked worktrees have `.git`
      as a **file** — never `ls "$wt/.git"/rebase-*`)
    * rendered screen — `capture-pane` content hash; a **changing** screen is
      positive proof of progress; frozen is not conclusive alone
    * agent context size + spend — scraped from the pane screen when the TUI
      prints them (e.g. `54.9K (11%)`, `$0.11`)

  Detached HEAD + staged files mid-rebase is **normal**, not broken.
  """

  alias Casein.Terminals.TmuxRunner

  # Axes that prove agent progress on their own. process_cpu is intentionally
  # absent — advancing jiffies is necessary-not-sufficient presence only.
  @progress_axes [:worktree, :screen, :context, :spend]

  @cache_table :casein_agent_progress
  @default_cache_ttl_ms 180_000
  # Wall time a process can stay "active" with frozen progress axes before we
  # call running_but_not_progressing. Shorter than the 2h production incident;
  # long enough that a brief think pause does not flap.
  @default_stall_after_ms 45_000
  @screen_lines 80

  @type state :: :progressing | :running_but_not_progressing | :quiet | :unknown

  @type axis_verdict :: :advanced | :stalled | :unknown | :in_flight

  @type observation :: %{
          state: state(),
          reason: atom() | nil,
          axes: map(),
          sample_age_ms: non_neg_integer() | nil,
          stalled_axis_count: non_neg_integer(),
          advanced_axis_count: non_neg_integer()
        }

  @doc "Default stall threshold in milliseconds."
  @spec default_stall_after_ms() :: pos_integer()
  def default_stall_after_ms, do: @default_stall_after_ms

  @doc false
  @spec cache_table() :: atom()
  def cache_table,
    do: Application.get_env(:casein, :agent_progress_cache_table, @cache_table)

  @doc false
  @spec ensure_cache_table() :: :ok
  def ensure_cache_table do
    table = cache_table()

    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ref ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Observe composite progress for one pane.

  Options:

    * `:now_ms` — monotonic clock
    * `:stall_after_ms` — wall time before running_but_not_progressing
    * `:process` — precomputed `PaneProcessLiveness` observation
    * `:worktree_path` — pane worktree root
    * `:session` / `:pane_id` — required for screen capture + cache key
    * `:screen_reader` — `(session, pane_id -> {:ok, text} | :error)` override
    * `:git_reader` — `(worktree -> map())` override returning worktree facts
    * `:cache` — `false` skips read/write
  """
  @spec observe(keyword()) :: observation()
  def observe(opts) when is_list(opts) do
    ensure_cache_table()
    session = Keyword.fetch!(opts, :session)
    pane_id = Keyword.fetch!(opts, :pane_id)
    now_ms = Keyword.get(opts, :now_ms) || System.monotonic_time(:millisecond)
    process = Keyword.get(opts, :process) || %{}
    worktree = Keyword.get(opts, :worktree_path)

    sample = %{
      session: session,
      pane_id: pane_id,
      sampled_at_ms: now_ms,
      process_state: Map.get(process, :state),
      cpu_jiffies: Map.get(process, :cpu_jiffies),
      cpu_jiffies_delta: Map.get(process, :cpu_jiffies_delta),
      worktree: sample_worktree(worktree, opts),
      screen: sample_screen(session, pane_id, opts)
    }

    classify_and_store(sample, opts)
  end

  @doc "JSON-friendly projection of an observation."
  @spec to_json(observation() | map() | nil) :: map()
  def to_json(nil), do: %{state: "unknown", reason: "no_sample"}

  def to_json(%{state: state} = obs) do
    %{
      state: atom_str(state),
      reason: atom_str(Map.get(obs, :reason)),
      sample_age_ms: Map.get(obs, :sample_age_ms),
      stalled_axis_count: Map.get(obs, :stalled_axis_count),
      advanced_axis_count: Map.get(obs, :advanced_axis_count),
      axes: axes_json(Map.get(obs, :axes) || %{})
    }
    |> reject_nil()
  end

  def to_json(_), do: %{state: "unknown", reason: "malformed"}

  ## Sampling

  defp sample_worktree(path, opts) when is_binary(path) and path != "" do
    reader = Keyword.get(opts, :git_reader) || (&default_git_reader/1)
    reader.(path)
  end

  defp sample_worktree(_, _), do: %{available?: false}

  defp default_git_reader(path) do
    git_dir = git_output(path, ["rev-parse", "--git-dir"])

    %{
      available?: true,
      git_dir: git_dir,
      head_sha: git_output(path, ["rev-parse", "HEAD"]),
      commit_count: parse_int(git_output(path, ["rev-list", "--count", "HEAD"])),
      status_fingerprint: status_fingerprint(path),
      dirty_count: dirty_count(path),
      rebase_or_merge?: rebase_or_merge?(git_dir),
      detached?: detached?(path)
    }
  end

  # Linked worktrees: `.git` is a file pointing at the common dir. Always resolve
  # via `rev-parse --git-dir` before looking for rebase-merge / MERGE_HEAD.
  defp rebase_or_merge?(git_dir) when is_binary(git_dir) and git_dir != "" do
    abs = Path.expand(git_dir)

    Enum.any?(
      [
        Path.join(abs, "rebase-merge"),
        Path.join(abs, "rebase-apply"),
        Path.join(abs, "MERGE_HEAD"),
        Path.join(abs, "CHERRY_PICK_HEAD"),
        Path.join(abs, "REVERT_HEAD")
      ],
      &File.exists?/1
    )
  end

  defp rebase_or_merge?(_), do: false

  defp detached?(path) do
    case git_output(path, ["symbolic-ref", "-q", "HEAD"]) do
      nil -> true
      "" -> true
      _ -> false
    end
  end

  defp status_fingerprint(path) do
    case git_output(path, ["status", "--porcelain=v1", "-z"]) do
      nil -> nil
      body -> :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    end
  end

  defp dirty_count(path) do
    case git_output(path, ["status", "--porcelain=v1"]) do
      nil -> nil
      "" -> 0
      body -> body |> String.split("\n", trim: true) |> length()
    end
  end

  defp git_output(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  rescue
    ErlangError -> nil
  end

  defp sample_screen(session, pane_id, opts) do
    reader = Keyword.get(opts, :screen_reader) || (&default_screen_reader/2)

    case reader.(session, pane_id) do
      {:ok, text} when is_binary(text) ->
        %{
          available?: true,
          hash: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower),
          context_tokens: parse_context_tokens(text),
          context_pct: parse_context_pct(text),
          spend_usd: parse_spend_usd(text)
        }

      _ ->
        %{available?: false}
    end
  end

  defp default_screen_reader(session, pane_id) do
    target = "#{session}:#{pane_id}"

    case TmuxRunner.run([
           "capture-pane",
           "-t",
           target,
           "-p",
           "-J",
           "-S",
           "-#{@screen_lines}"
         ]) do
      {out, 0} -> {:ok, out}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # "54.9K (11%)" / "context 120k" / "ctx 11%" — best-effort TUI scrape.
  defp parse_context_tokens(text) do
    cond do
      match =
          Regex.run(~r/(?i)(?:context|ctx|tokens?)[^\d]{0,12}(\d+(?:\.\d+)?)\s*([kKmM])\b/, text) ->
        scale_num(Enum.at(match, 1), Enum.at(match, 2))

      match = Regex.run(~r/\b(\d+(?:\.\d+)?)\s*([kKmM])\s*\(\s*\d{1,3}\s*%\s*\)/, text) ->
        scale_num(Enum.at(match, 1), Enum.at(match, 2))

      match = Regex.run(~r/(?i)(?:context|ctx|tokens?)[^\d]{0,12}(\d{3,})\b/, text) ->
        parse_int(Enum.at(match, 1))

      true ->
        nil
    end
  end

  defp parse_context_pct(text) do
    cond do
      match = Regex.run(~r/\(\s*(\d{1,3})\s*%\s*\)/, text) ->
        parse_int(Enum.at(match, 1))

      match = Regex.run(~r/(?i)(?:context|ctx)[^\d%]{0,12}(\d{1,3})\s*%/, text) ->
        parse_int(Enum.at(match, 1))

      true ->
        nil
    end
  end

  defp parse_spend_usd(text) do
    cond do
      match = Regex.run(~r/\$\s*(\d+(?:\.\d+)?)/, text) ->
        parse_float(Enum.at(match, 1))

      match = Regex.run(~r/(?i)(?:spend|cost|usd)[^\d]{0,8}(\d+(?:\.\d+)?)/, text) ->
        parse_float(Enum.at(match, 1))

      true ->
        nil
    end
  end

  defp scale_num(num_s, unit) do
    with n when is_number(n) <- parse_float(num_s) do
      case unit do
        u when u in ["k", "K"] -> round(n * 1_000)
        u when u in ["m", "M"] -> round(n * 1_000_000)
        _ -> round(n)
      end
    end
  end

  ## Classify

  defp classify_and_store(sample, opts) do
    use_cache? = Keyword.get(opts, :cache, true)
    stall_after = Keyword.get(opts, :stall_after_ms, @default_stall_after_ms)
    key = cache_key(sample.session, sample.pane_id)
    prev = if use_cache?, do: cache_lookup(key), else: :miss

    {axes, age} =
      case prev do
        {:ok, earlier} ->
          age = sample.sampled_at_ms - earlier.sampled_at_ms
          {diff_axes(earlier, sample), age}

        :miss ->
          {warming_axes(sample), nil}
      end

    # Progress counts exclude process_cpu — CPU alone never means progressing.
    advanced = count_progress_axis(axes, :advanced)
    stalled = count_progress_axis(axes, :stalled)
    in_flight = count_progress_axis(axes, :in_flight)
    process_active? = sample.process_state == :active
    process_quiet? = sample.process_state == :quiet

    {state, reason} =
      cond do
        # Strong progress wins regardless of CPU (mid-rebase / screen churn).
        advanced >= 1 or in_flight >= 1 ->
          {:progressing, progress_reason(axes)}

        # The expensive failure mode: process burns CPU while ≥2 axes are flat.
        # Needs two independent non-CPU axes disagreeing with process activity.
        process_active? and is_integer(age) and age >= stall_after and stalled >= 2 ->
          {:running_but_not_progressing, :cpu_active_axes_stalled}

        process_active? and is_nil(age) ->
          {:unknown, :warming}

        process_active? and is_integer(age) and age < stall_after ->
          {:unknown, :settling}

        process_quiet? and stalled >= 1 and advanced == 0 ->
          {:quiet, :process_and_axes_quiet}

        process_quiet? ->
          {:quiet, :process_quiet}

        true ->
          {:unknown, :insufficient_signal}
      end

    observation = %{
      state: state,
      reason: reason,
      axes: axes,
      sample_age_ms: age,
      stalled_axis_count: stalled,
      advanced_axis_count: advanced
    }

    if use_cache?, do: cache_store(key, sample)

    observation
  end

  defp warming_axes(sample) do
    %{
      process_cpu: axis(:unknown, sample.cpu_jiffies, nil),
      worktree: worktree_axis_warm(sample.worktree),
      screen: screen_axis_warm(sample.screen),
      context: metric_axis_warm(sample.screen, :context_tokens),
      spend: metric_axis_warm(sample.screen, :spend_usd)
    }
  end

  defp diff_axes(earlier, later) do
    %{
      process_cpu: process_axis(earlier, later),
      worktree: worktree_axis(earlier.worktree, later.worktree),
      screen: screen_axis(earlier.screen, later.screen),
      context:
        metric_axis(
          get_in_sample(earlier.screen, :context_tokens),
          get_in_sample(later.screen, :context_tokens)
        ),
      spend:
        metric_axis(
          get_in_sample(earlier.screen, :spend_usd),
          get_in_sample(later.screen, :spend_usd)
        )
    }
  end

  defp process_axis(earlier, later) do
    delta = later.cpu_jiffies_delta

    cond do
      later.process_state == :active and is_integer(delta) and delta > 0 ->
        axis(:advanced, later.cpu_jiffies, delta)

      later.process_state == :quiet ->
        axis(:stalled, later.cpu_jiffies, delta || 0)

      is_integer(later.cpu_jiffies) and is_integer(earlier.cpu_jiffies) and
          later.cpu_jiffies == earlier.cpu_jiffies ->
        axis(:stalled, later.cpu_jiffies, 0)

      true ->
        axis(:unknown, later.cpu_jiffies, delta)
    end
  end

  defp worktree_axis_warm(%{available?: true} = wt) do
    # Mid-rebase is in-flight progress even on the first sample.
    if wt[:rebase_or_merge?] do
      axis(:in_flight, wt_fingerprint(wt), nil)
    else
      axis(:unknown, wt_fingerprint(wt), nil)
    end
  end

  defp worktree_axis_warm(_), do: axis(:unknown, nil, nil)

  defp worktree_axis(%{available?: true} = earlier, %{available?: true} = later) do
    cond do
      later[:rebase_or_merge?] ->
        # Detached HEAD + staged files mid-rebase is NORMAL, not broken.
        axis(:in_flight, wt_fingerprint(later), nil)

      commits_advanced?(earlier, later) or status_changed?(earlier, later) or
          head_moved?(earlier, later) ->
        axis(:advanced, wt_fingerprint(later), nil)

      true ->
        axis(:stalled, wt_fingerprint(later), nil)
    end
  end

  defp worktree_axis(_, _), do: axis(:unknown, nil, nil)

  defp commits_advanced?(%{commit_count: a}, %{commit_count: b})
       when is_integer(a) and is_integer(b),
       do: b > a

  defp commits_advanced?(_, _), do: false

  defp status_changed?(%{status_fingerprint: a}, %{status_fingerprint: b})
       when is_binary(a) and is_binary(b),
       do: a != b

  defp status_changed?(_, _), do: false

  defp head_moved?(%{head_sha: a}, %{head_sha: b})
       when is_binary(a) and is_binary(b) and a != "" and b != "",
       do: a != b

  defp head_moved?(_, _), do: false

  defp wt_fingerprint(%{} = wt) do
    %{
      head_sha: wt[:head_sha],
      commit_count: wt[:commit_count],
      status_fingerprint: wt[:status_fingerprint],
      dirty_count: wt[:dirty_count],
      rebase_or_merge?: wt[:rebase_or_merge?] == true,
      detached?: wt[:detached?] == true
    }
  end

  defp screen_axis_warm(%{available?: true, hash: hash}), do: axis(:unknown, hash, nil)
  defp screen_axis_warm(_), do: axis(:unknown, nil, nil)

  defp screen_axis(%{available?: true, hash: a}, %{available?: true, hash: b})
       when is_binary(a) and is_binary(b) do
    if a != b, do: axis(:advanced, b, nil), else: axis(:stalled, b, nil)
  end

  defp screen_axis(_, _), do: axis(:unknown, nil, nil)

  defp metric_axis_warm(%{available?: true} = screen, key) do
    axis(:unknown, Map.get(screen, key), nil)
  end

  defp metric_axis_warm(_, _), do: axis(:unknown, nil, nil)

  defp metric_axis(earlier, later)
       when is_number(earlier) and is_number(later) and later > earlier,
       do: axis(:advanced, later, later - earlier)

  defp metric_axis(earlier, later)
       when is_number(earlier) and is_number(later) and later == earlier,
       do: axis(:stalled, later, 0)

  defp metric_axis(_earlier, later) when is_number(later), do: axis(:unknown, later, nil)
  defp metric_axis(_, _), do: axis(:unknown, nil, nil)

  defp get_in_sample(%{available?: true} = screen, key), do: Map.get(screen, key)
  defp get_in_sample(_, _), do: nil

  defp axis(verdict, value, delta) do
    %{verdict: verdict, value: value, delta: delta}
  end

  defp count_progress_axis(axes, verdict) do
    Enum.count(@progress_axes, fn key ->
      match?(%{verdict: ^verdict}, Map.get(axes, key))
    end)
  end

  defp progress_reason(axes) do
    cond do
      match?(%{verdict: :in_flight}, axes.worktree) -> :rebase_or_merge
      match?(%{verdict: :advanced}, axes.worktree) -> :worktree_advanced
      match?(%{verdict: :advanced}, axes.screen) -> :screen_advanced
      match?(%{verdict: :advanced}, axes.context) -> :context_advanced
      match?(%{verdict: :advanced}, axes.spend) -> :spend_advanced
      true -> :progress_signal
    end
  end

  ## Cache / JSON helpers

  defp cache_key(session, pane_id), do: {session, pane_id}

  defp cache_lookup(key) do
    case :ets.lookup(cache_table(), key) do
      [{^key, sample, stored_at}] ->
        if System.monotonic_time(:millisecond) - stored_at <= @default_cache_ttl_ms do
          {:ok, sample}
        else
          :miss
        end

      _ ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp cache_store(key, sample) do
    :ets.insert(cache_table(), {key, sample, System.monotonic_time(:millisecond)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp axes_json(axes) when is_map(axes) do
    Map.new(axes, fn {k, v} ->
      {atom_str(k), axis_json(v)}
    end)
  end

  defp axis_json(%{verdict: v} = axis) do
    %{
      verdict: atom_str(v),
      value: json_value(Map.get(axis, :value)),
      delta: Map.get(axis, :delta)
    }
    |> reject_nil()
  end

  defp axis_json(_), do: %{verdict: "unknown"}

  defp json_value(%{} = map), do: Map.new(map, fn {k, v} -> {atom_str(k), v} end)
  defp json_value(other), do: other

  defp atom_str(nil), do: nil
  defp atom_str(a) when is_atom(a), do: Atom.to_string(a)
  defp atom_str(a) when is_binary(a), do: a
  defp atom_str(a), do: to_string(a)

  defp reject_nil(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp parse_int(nil), do: nil

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(n) when is_integer(n), do: n
  defp parse_int(_), do: nil

  defp parse_float(nil), do: nil

  defp parse_float(s) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_float(n) when is_number(n), do: n / 1
  defp parse_float(_), do: nil
end
