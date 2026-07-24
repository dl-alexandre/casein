defmodule Casein.FilePanes.LinkResolver do
  @moduledoc """
  Validates terminal file-link candidates against a **local** workspace root.

  Sits between `Casein.Terminals.FileLinkScanner` (pure span detection, runs
  per frame in PaneWorker) and consumers:

    * `validate_frame/3` filters a frame's candidates down to links whose
      paths resolve to real regular files under the workspace root, rewriting
      each candidate's `:path` to the workspace-relative form. It is budgeted:
      at most 16 *uncached* validations run per call — the rest of the
      frame's candidates are dropped rather than paying more filesystem hits.
    * `resolve/2` re-validates a single path on click. Server handlers must
      call this instead of trusting the client payload.

  Both share an ETS cache holding positive AND negative results with a ~10s
  TTL, so a busy frame stream (`mix test` spraying the same stacktrace paths)
  costs one `File.regular?/1` per distinct path per TTL window, not per frame.

  Local workspaces only by design (v1): remote `FileAccess` validation would
  put SSH round-trips on the frame path. Callers with a remote loc skip
  scanning entirely.

  Unlike `Casein.Links.Resolver` (the workspace open API's resolver), this
  module never classifies targets or touches `FileAccess` — it is a cheap,
  cached existence + confinement check built for the render hot path.

  Candidates that miss root-relatively fall back to
  `Casein.FilePanes.SuffixIndex`: bare names (`foo.ex`), subdir-relative
  paths (`js/app.js` printed from a pane below the root), and absolute paths
  outside the root (linked-worktree stacktraces) resolve when exactly one
  workspace file's path ends with the candidate's trailing segments. While a
  root's index is still building, those candidates miss with their underlying
  error (`:not_found` / `:outside_root`) but are *not* cached, so they can
  still linkify on a later frame once the index lands.
  """

  use GenServer

  alias Casein.FilePanes.SuffixIndex
  alias Casein.Files.PathSafety

  @table :casein_file_link_cache
  @default_max_new_per_frame 16
  @cache_max_entries 5_000

  @type resolve_error :: :outside_root | :symlink_escape | :too_deep | :not_found | :invalid

  # Longest trailing-segment suffix tried against the SuffixIndex before
  # falling down to the bare basename.
  @max_suffix_segments 5

  # --- lifecycle ------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end

  # --- public API -------------------------------------------------------------

  @doc """
  Validate one frame's scanner candidates (`[%{path: ..., ...}]`) against
  `root`. Returns the surviving candidates with `:path` rewritten to the
  resolved workspace-relative path; order is preserved.

  Options: `:max_new` — cap on uncached validations (default #{@default_max_new_per_frame}).
  """
  @spec validate_frame(String.t(), [map()], keyword()) :: [map()]
  def validate_frame(root, candidates, opts \\ [])

  def validate_frame(root, candidates, opts) when is_binary(root) and is_list(candidates) do
    max_new = Keyword.get(opts, :max_new, @default_max_new_per_frame)
    root_key = Path.expand(root)

    {links, _new} =
      Enum.reduce(candidates, {[], 0}, fn candidate, {acc, new_count} ->
        case cached_resolve(root, root_key, candidate.path, new_count, max_new) do
          {{:ok, rel}, new_count} -> {[%{candidate | path: rel} | acc], new_count}
          {_error_or_skipped, new_count} -> {acc, new_count}
        end
      end)

    Enum.reverse(links)
  end

  def validate_frame(_root, _candidates, _opts), do: []

  @doc """
  Resolve one candidate path against `root` (through the cache).

  Absolute paths are normalized to root-relative; `./` prefixes are stripped.
  Returns `{:ok, workspace_relative_path}` only for an existing regular file
  inside the root; confinement failures surface their PathSafety reason.
  """
  @spec resolve(String.t(), String.t()) :: {:ok, String.t()} | {:error, resolve_error()}
  def resolve(root, path) when is_binary(root) and is_binary(path) do
    key = {Path.expand(root), path}

    case cache_get(key) do
      {:hit, result} ->
        result

      :miss ->
        finalize(key, do_resolve(root, path))
    end
  end

  def resolve(_root, _path), do: {:error, :invalid}

  @doc "Cache TTL in milliseconds (config: `:casein, :file_link_cache_ttl_ms`)."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: Application.get_env(:casein, :file_link_cache_ttl_ms, 10_000)

  @doc false
  # Test helper: drop all cached results.
  def clear_cache do
    :ets.delete_all_objects(@table)
    :ok
  catch
    :error, :badarg -> :ok
  end

  # --- internals --------------------------------------------------------------

  # Frame-path variant of resolve/2 that threads the new-validation budget:
  # cache hits are free; misses beyond `max_new` are skipped (dropped) without
  # touching the filesystem.
  defp cached_resolve(root, root_key, path, new_count, max_new) when is_binary(path) do
    key = {root_key, path}

    case cache_get(key) do
      {:hit, result} ->
        {result, new_count}

      :miss when new_count >= max_new ->
        {:skipped, new_count}

      :miss ->
        {finalize(key, do_resolve(root, path)), new_count + 1}
    end
  end

  defp cached_resolve(_root, _root_key, _path, new_count, _max_new), do: {:skipped, new_count}

  # A `{:pending, miss}` result means the suffix index for this root is still
  # building: report the underlying miss but skip the cache, so the candidate
  # can resolve on a later frame instead of a 10s-cached negative.
  defp finalize(_key, {:error, {:pending, miss_error}}), do: {:error, miss_error}

  defp finalize(key, result) do
    cache_put(key, result)
    result
  end

  defp do_resolve(root, path) do
    with {:ok, rel} <- normalize(root, path),
         {:ok, abs} <- safety_resolve(root, rel) do
      if File.regular?(abs), do: {:ok, rel}, else: suffix_fallback(root, path, :not_found)
    else
      # Absolute paths outside the root (linked-worktree stacktraces) and
      # relative escapes may still name a workspace file by trailing
      # segments; confinement is re-checked on the index hit. When nothing
      # matches, the original refusal is preserved — click handlers treat
      # :outside_root as a hard refusal, not a transient miss.
      {:error, :outside_root} -> suffix_fallback(root, path, :outside_root)
      {:error, _reason} = error -> error
    end
  end

  # Root-relative resolution missed. Try progressively shorter trailing-
  # segment suffixes against the workspace SuffixIndex — longest (most
  # specific) first, down to the bare basename. A unique hit resolves; an
  # ambiguous suffix stops the descent (shorter suffixes only match more);
  # no match at all yields `miss_error`.
  defp suffix_fallback(root, path, miss_error) do
    segments = path |> Path.split() |> Enum.reject(&(&1 in ["/", ".", ".."]))

    case length(segments) do
      0 -> {:error, miss_error}
      n -> try_suffixes(root, segments, min(n, @max_suffix_segments), miss_error)
    end
  end

  defp try_suffixes(_root, _segments, 0, miss_error), do: {:error, miss_error}

  defp try_suffixes(root, segments, k, miss_error) do
    candidate = segments |> Enum.take(-k) |> Path.join()

    case SuffixIndex.lookup(root, candidate) do
      {:ok, rel} -> verify_index_hit(root, rel)
      {:error, :pending} -> {:error, {:pending, miss_error}}
      {:error, :ambiguous} -> {:error, miss_error}
      {:error, :not_found} -> try_suffixes(root, segments, k - 1, miss_error)
    end
  end

  # Index hits re-run confinement + existence: the index is rebuilt lazily,
  # so an entry may be stale, and defense-in-depth keeps every resolved path
  # PathSafety-checked regardless of where it came from.
  defp verify_index_hit(root, rel) do
    with {:ok, abs} <- safety_resolve(root, rel) do
      if File.regular?(abs), do: {:ok, rel}, else: {:error, :not_found}
    end
  end

  defp safety_resolve(root, rel) do
    case PathSafety.resolve(root, rel) do
      {:ok, abs} -> {:ok, abs}
      {:error, :missing_path} -> {:error, :invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  # Absolute paths (stacktraces under an absolute cwd, compiler output) are
  # normalized to root-relative; anything that escapes is refused.
  defp normalize(root, "/" <> _rest = path) do
    root = Path.expand(root)
    abs = Path.expand(path)
    rel = Path.relative_to(abs, root)

    cond do
      abs == root -> {:error, :not_found}
      rel == abs or String.starts_with?(rel, "..") -> {:error, :outside_root}
      true -> {:ok, rel}
    end
  end

  defp normalize(root, "./" <> rest), do: normalize(root, rest)
  defp normalize(_root, ""), do: {:error, :invalid}
  defp normalize(_root, rel), do: {:ok, rel}

  # --- ETS cache --------------------------------------------------------------

  # The cache degrades gracefully: when the table is missing (resolver not
  # supervised in a minimal test tree), every lookup is a miss and puts are
  # dropped — validation still works, just uncached.
  defp cache_get(key) do
    case :ets.lookup(@table, key) do
      [{^key, result, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:hit, result}
        else
          :miss
        end

      [] ->
        :miss
    end
  catch
    :error, :badarg -> :miss
  end

  defp cache_put(key, result) do
    # Coarse size guard: distinct paths seen within one TTL window are
    # naturally bounded, but a pathological stream (generated file names)
    # must not grow the table without limit.
    if :ets.info(@table, :size) > @cache_max_entries do
      :ets.delete_all_objects(@table)
    end

    expires_at = System.monotonic_time(:millisecond) + ttl_ms()
    :ets.insert(@table, {key, result, expires_at})
    :ok
  catch
    :error, :badarg -> :ok
  end
end
