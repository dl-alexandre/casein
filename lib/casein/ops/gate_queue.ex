defmodule Casein.Ops.GateQueue do
  @moduledoc """
  Host observation of the **PR-gate single-flight queue**.

  Work serialises behind util-linux `flock` on `/tmp/casein-pr-gate.lock`
  (`scripts/lib/casein-devbox-mix-lock.sh`, used by pr-gate and preview-e2e).
  Operators running a multi-worker fleet need to know who holds the box and
  how deep the wait is — without grepping `/proc` by hand.

  ## Kind discipline

  Same contract as `Casein.Terminals.AgentLiveness`:

    * `{:error, reason}` — the lock / proc tree could not be scanned. Says
      nothing about the queue; callers must render **unknown**, never free.
    * `{:ok, %{lock_state: :free}}` — scan ran; nobody holds the lock.
    * `{:ok, %{lock_state: :held, holder: map, waiter_count: n}}` — scan ran.

  This is a pure projection over `/proc` (and the lock path). No GenServer,
  no durable table, no GitHub API dependency — holder identity comes from the
  Actions runner env on the lock-holding process when present.
  """

  @default_lock_path "/tmp/casein-pr-gate.lock"
  @default_cache_ttl_ms 5_000
  @cache_table :casein_gate_queue_cache

  @type holder :: %{
          pid: pos_integer(),
          cmd: String.t() | nil,
          started_at: DateTime.t() | nil,
          held_for_seconds: non_neg_integer() | nil,
          pr: pos_integer() | nil,
          branch: String.t() | nil,
          run_id: String.t() | nil,
          sha: String.t() | nil,
          workflow: String.t() | nil
        }

  @type snapshot :: %{
          observed_at: DateTime.t(),
          lock_path: String.t(),
          lock_state: :free | :held,
          holder: holder() | nil,
          waiters: [holder()],
          waiter_count: non_neg_integer(),
          depth: non_neg_integer(),
          source: :proc
        }

  @type error_reason :: :enoent | :eacces | :no_proc | :bad_lock_path

  @doc "Default flock path used by pr-gate.yml."
  @spec default_lock_path() :: String.t()
  def default_lock_path, do: @default_lock_path

  @doc """
  Last successful observe without walking `/proc`.

  LiveView `handle_info` / render paths must use this. A miss returns
  `unknown/0` and kicks a background refresh — never sequential-scans
  `/proc` on the caller (#923). Measured uncached observe: 222–256ms.
  """
  @spec cached(keyword()) :: snapshot() | map()
  def cached(opts \\ []) do
    lock_path = Keyword.get(opts, :lock_path, @default_lock_path)
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    cached_at(lock_path, now, opts)
  end

  defp cached_at(lock_path, now, opts) when is_binary(lock_path) and lock_path != "" do
    case cache_lookup(lock_path) do
      {:ok, snap} -> refresh_held_for(snap, now)
      :miss -> cached_miss(lock_path, opts)
    end
  end

  defp cached_at(_lock_path, _now, _opts), do: unknown()

  defp cached_miss(lock_path, opts) do
    maybe_refresh({:gate, lock_path}, fn -> observe(Keyword.put(opts, :cache, false)) end)
    unknown()
  end

  @doc """
  Observe who holds (and who waits on) the host gate lock.

  Options:

    * `:lock_path` — override lock file (tests)
    * `:proc_root` — override `/proc` root (tests)
    * `:now` — reference time
    * `:cache` — `false` to force a fresh scan (default true)
    * `:cache_ttl_ms` — cache window (default #{@default_cache_ttl_ms})
  """
  @spec observe(keyword()) :: {:ok, snapshot()} | {:error, error_reason()}
  def observe(opts \\ []) do
    lock_path = Keyword.get(opts, :lock_path, @default_lock_path)
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    if not is_binary(lock_path) or lock_path == "" do
      {:error, :bad_lock_path}
    else
      if Keyword.get(opts, :cache, true) do
        case cache_lookup(lock_path) do
          {:ok, cached} -> {:ok, refresh_held_for(cached, now)}
          :miss -> observe_uncached(lock_path, now, opts)
        end
      else
        observe_uncached(lock_path, now, opts)
      end
    end
  end

  @doc "Empty / unknown-safe placeholder for mount before first observe."
  @spec unknown() :: %{lock_state: :unknown, depth: nil, waiter_count: nil, holder: nil}
  def unknown do
    %{
      lock_state: :unknown,
      depth: nil,
      waiter_count: nil,
      holder: nil,
      waiters: [],
      observed_at: nil,
      lock_path: @default_lock_path,
      source: :proc
    }
  end

  @doc "True when a holder is serialising the box."
  @spec busy?(snapshot() | map()) :: boolean()
  def busy?(%{lock_state: :held}), do: true
  def busy?(_), do: false

  @doc "Operator-facing one-line summary (never claims free on unknown)."
  @spec summary(snapshot() | map()) :: String.t()
  def summary(%{lock_state: :free}), do: "gate free"

  def summary(%{lock_state: :held, holder: holder, waiter_count: waiters}) do
    who = holder_label(holder)
    held = held_suffix(holder)
    queue = if is_integer(waiters) and waiters > 0, do: " · #{waiters} waiting", else: ""
    "gate held by #{who}#{held}#{queue}"
  end

  def summary(%{lock_state: :unknown}), do: "gate unknown"
  def summary(_), do: "gate unknown"

  @doc """
  Queue position for a caller identity inside an observed snapshot.

  Position is 1-based depth order: holder is position 1, first waiter is 2, …
  Depth is `1 + waiter_count` when held (same as `snapshot.depth`).

  Identity keys (first match wins): `:pr`, `:run_id`, `:branch`, `:pid`,
  or a map/holder-shaped value. Unknown lock observation returns
  `%{status: :unknown}` — never `:not_in_queue` (that would claim free).

  Returns:

    * `%{status: :unknown}` — lock/proc not observed
    * `%{status: :free, depth: 0}` — scan ran; nobody holds the lock
    * `%{status: :holding, position: 1, depth: n, holder: map}` — caller is holder
    * `%{status: :waiting, position: p, depth: n, ahead: p-1, holder: map, self: map}`
    * `%{status: :not_in_queue, depth: n, holder: map}` — held, caller not in queue
  """
  @spec position(snapshot() | map(), keyword() | map() | pos_integer() | String.t() | nil) ::
          map()
  def position(snap, identity \\ nil)

  def position(%{lock_state: :unknown}, _identity), do: %{status: :unknown}

  def position(%{lock_state: :free} = snap, _identity) do
    %{status: :free, depth: Map.get(snap, :depth) || 0}
  end

  def position(%{lock_state: :held} = snap, identity) do
    holder = Map.get(snap, :holder)
    waiters = Map.get(snap, :waiters) || []
    depth = Map.get(snap, :depth) || 1 + length(waiters)
    id = normalize_identity(identity)

    case id do
      nil ->
        %{
          status: :held,
          depth: depth,
          waiter_count: Map.get(snap, :waiter_count) || length(waiters),
          holder: holder,
          waiters: waiters_with_positions(holder, waiters)
        }

      id when is_map(id) ->
        if identity_match?(holder, id) do
          %{status: :holding, position: 1, depth: depth, holder: holder}
        else
          case find_waiter_index(waiters, id) do
            nil ->
              %{status: :not_in_queue, depth: depth, holder: holder}

            idx when is_integer(idx) ->
              # holder is position 1; first waiter is 2
              pos = idx + 2
              self = Enum.at(waiters, idx)

              %{
                status: :waiting,
                position: pos,
                depth: depth,
                ahead: pos - 1,
                holder: holder,
                self: self
              }
          end
        end
    end
  end

  def position(_snap, _identity), do: %{status: :unknown}

  @doc "Annotate holder + waiters with 1-based queue positions for chrome."
  @spec with_positions(snapshot() | map()) :: map()
  def with_positions(%{lock_state: :held, holder: holder} = snap) when is_map(holder) do
    waiters = Map.get(snap, :waiters) || []
    holder = Map.put(holder, :position, 1)

    waiters =
      waiters
      |> Enum.with_index(2)
      |> Enum.map(fn {w, pos} -> Map.put(w || %{}, :position, pos) end)

    %{snap | holder: holder, waiters: waiters}
  end

  def with_positions(snap) when is_map(snap), do: snap
  def with_positions(_), do: unknown()

  ## Internals

  defp normalize_identity(nil), do: nil
  defp normalize_identity(pid) when is_integer(pid) and pid > 0, do: %{pid: pid}

  defp normalize_identity(pr) when is_binary(pr) do
    case Integer.parse(String.trim_leading(String.trim(pr), "#")) do
      {n, ""} when n > 0 -> %{pr: n}
      _ -> %{branch: pr}
    end
  end

  defp normalize_identity(opts) when is_list(opts) do
    opts
    |> Keyword.take([:pr, :run_id, :branch, :pid, :sha, :workflow])
    |> Map.new()
    |> reject_blank_identity()
  end

  defp normalize_identity(map) when is_map(map) do
    %{
      pr: Map.get(map, :pr) || Map.get(map, "pr"),
      run_id: Map.get(map, :run_id) || Map.get(map, "run_id"),
      branch: Map.get(map, :branch) || Map.get(map, "branch"),
      pid: Map.get(map, :pid) || Map.get(map, "pid"),
      sha: Map.get(map, :sha) || Map.get(map, "sha")
    }
    |> reject_blank_identity()
  end

  defp normalize_identity(_), do: nil

  defp reject_blank_identity(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
    |> case do
      empty when map_size(empty) == 0 -> nil
      kept -> kept
    end
  end

  defp identity_match?(nil, _id), do: false

  defp identity_match?(holder, id) when is_map(holder) and is_map(id) do
    cond do
      match_int?(holder, id, :pr) -> true
      match_bin?(holder, id, :run_id) -> true
      match_int?(holder, id, :pid) -> true
      match_bin?(holder, id, :branch) -> true
      true -> false
    end
  end

  defp match_int?(holder, id, key) do
    hv = Map.get(holder, key)
    iv = Map.get(id, key)
    is_integer(hv) and is_integer(iv) and hv == iv
  end

  defp match_bin?(holder, id, key) do
    hv = Map.get(holder, key)
    iv = Map.get(id, key)
    is_binary(hv) and hv != "" and is_binary(iv) and iv != "" and hv == iv
  end

  defp find_waiter_index(waiters, id) do
    Enum.find_index(waiters, &identity_match?(&1, id))
  end

  defp waiters_with_positions(holder, waiters) do
    _ = holder

    waiters
    |> Enum.with_index(2)
    |> Enum.map(fn {w, pos} ->
      if is_map(w), do: Map.put(w, :position, pos), else: %{position: pos}
    end)
  end

  defp observe_uncached(lock_path, now, opts) do
    proc_root = Keyword.get(opts, :proc_root, "/proc")

    case File.stat(lock_path) do
      {:error, :enoent} ->
        snap = free_snapshot(lock_path, now)
        cache_put(lock_path, snap, opts)
        {:ok, snap}

      {:error, :eacces} ->
        {:error, :eacces}

      {:error, _} ->
        {:error, :enoent}

      {:ok, %File.Stat{} = stat} ->
        {maj, min} = dev_major_minor(stat)
        ino = stat.inode

        with {:ok, lock_pids} <- flock_holder_pids(proc_root, maj, min, ino),
             {:ok, openers} <- pids_with_open_path(proc_root, lock_path) do
          # Candidate set: processes with the lock fd open, else the FLOCK table
          # pid (may be a short-lived subshell that already exited).
          candidate_pids =
            cond do
              openers != [] -> openers
              lock_pids != [] -> lock_pids
              true -> []
            end

          described =
            candidate_pids
            |> Enum.map(&describe_pid(proc_root, &1, now))
            |> Enum.reject(&is_nil/1)

          holder = pick_holder(described)

          # If FLOCK says held but we could not describe a live pid, still
          # report held with a minimal holder so UI does not claim free.
          holder =
            cond do
              holder != nil ->
                holder

              lock_pids != [] ->
                %{
                  pid: hd(Enum.sort(lock_pids)),
                  cmd: nil,
                  started_at: nil,
                  held_for_seconds: nil,
                  wchan: nil,
                  pr: nil,
                  branch: nil,
                  run_id: nil,
                  sha: nil,
                  workflow: nil
                }

              true ->
                nil
            end

          lock_state = if holder, do: :held, else: :free

          # Children of the holder inherit the flock fd — they are the same run,
          # not a queue. True waiters are blocked in flock (wchan) and/or carry
          # a different GITHUB_RUN_ID than the holder.
          waiters =
            case holder do
              nil ->
                []

              h ->
                described
                |> Enum.reject(&same_run?(&1, h))
                |> Enum.filter(&waiter?/1)
            end

          depth =
            case lock_state do
              :held -> 1 + length(waiters)
              _ -> 0
            end

          snap = %{
            observed_at: now,
            lock_path: lock_path,
            lock_state: lock_state,
            holder: holder,
            waiters: waiters,
            waiter_count: length(waiters),
            depth: depth,
            source: :proc
          }

          cache_put(lock_path, snap, opts)
          {:ok, snap}
        end
    end
  end

  defp free_snapshot(lock_path, now) do
    %{
      observed_at: now,
      lock_path: lock_path,
      lock_state: :free,
      holder: nil,
      waiters: [],
      waiter_count: 0,
      depth: 0,
      source: :proc
    }
  end

  # /proc/locks lines look like:
  #   1: FLOCK  ADVISORY  WRITE 3249091 103:02:33960 0 EOF
  # Device numbers are HEX (maj:min), inode is decimal.
  # locks_path is Path.join(proc_root, "locks") — fixed segment, not user input.
  # sobelow_skip ["Traversal.FileModule"]
  defp flock_holder_pids(proc_root, maj, min, ino) do
    locks_path = Path.join(proc_root, "locks")
    targets = lock_dev_tokens(maj, min, ino)

    case File.read(locks_path) do
      {:ok, body} ->
        pids =
          body
          |> String.split("\n", trim: true)
          |> Enum.filter(&String.contains?(&1, "FLOCK"))
          |> Enum.filter(&String.contains?(&1, "WRITE"))
          |> Enum.filter(fn line -> Enum.any?(targets, &String.contains?(line, &1)) end)
          |> Enum.flat_map(&parse_lock_pid/1)
          |> Enum.uniq()

        {:ok, pids}

      {:error, :enoent} ->
        {:error, :no_proc}

      {:error, :eacces} ->
        {:error, :eacces}

      {:error, _} ->
        {:error, :no_proc}
    end
  end

  defp lock_dev_tokens(maj, min, ino) do
    # /proc/locks prints maj:min in hex, often zero-padded to 2 digits on minor.
    hex_maj = Integer.to_string(maj, 16)
    hex_min = Integer.to_string(min, 16)
    hex_min_pad = String.pad_leading(hex_min, 2, "0")
    dec = "#{maj}:#{min}:#{ino}"
    dec_pad = "#{maj}:#{String.pad_leading(Integer.to_string(min), 2, "0")}:#{ino}"

    Enum.uniq([
      "#{hex_maj}:#{hex_min_pad}:#{ino}",
      "#{hex_maj}:#{hex_min}:#{ino}",
      String.downcase("#{hex_maj}:#{hex_min_pad}:#{ino}"),
      dec,
      dec_pad
    ])
  end

  # Elixir File.Stat on Linux often stores the raw st_dev in `major_device`
  # with `minor_device` 0. Decode with the Linux dev_t layout so we match
  # /proc/locks (which prints maj:min in hex, e.g. 103:02 for 0x10302).
  defp dev_major_minor(%File.Stat{major_device: raw, minor_device: min})
       when is_integer(raw) and is_integer(min) and min > 0 do
    {raw, min}
  end

  defp dev_major_minor(%File.Stat{major_device: dev, minor_device: 0}) when is_integer(dev) do
    # Linux dev_t (glibc): major in bits 8–19 (+ high), minor in 0–7 (+ mid).
    # Common small devices pack entirely in the low 32 bits (e.g. 0x10302 → 259:2).
    major = Bitwise.band(Bitwise.bsr(dev, 8), 0xFFF)
    minor = Bitwise.band(dev, 0xFF)
    major_hi = Bitwise.band(Bitwise.bsr(dev, 32), 0xFFFFF_000)
    minor_hi = Bitwise.band(Bitwise.bsr(dev, 12), 0xFFFF_FF00)

    {Bitwise.bor(major, major_hi), Bitwise.bor(minor, minor_hi)}
  end

  defp dev_major_minor(%File.Stat{major_device: maj, minor_device: min})
       when is_integer(maj) and is_integer(min),
       do: {maj, min}

  defp dev_major_minor(_), do: {0, 0}

  defp parse_lock_pid(line) do
    # fields: id: type scope mode pid dev:ino start end
    # pid is the first purely-decimal token after WRITE/READ.
    parts = String.split(line)

    case Enum.find_index(parts, &(&1 in ["WRITE", "READ"])) do
      nil ->
        []

      idx ->
        case Enum.at(parts, idx + 1) do
          nil ->
            []

          token ->
            case Integer.parse(token) do
              {pid, ""} when pid > 0 -> [pid]
              _ -> []
            end
        end
    end
  end

  defp pids_with_open_path(proc_root, lock_path) do
    case File.ls(proc_root) do
      {:ok, entries} ->
        pids =
          entries
          |> Enum.filter(&match?({_, ""}, Integer.parse(&1)))
          |> Enum.flat_map(fn pid_str ->
            fd_dir = Path.join([proc_root, pid_str, "fd"])

            case File.ls(fd_dir) do
              {:ok, fds} ->
                if Enum.any?(fds, fn fd ->
                     case File.read_link(Path.join(fd_dir, fd)) do
                       {:ok, ^lock_path} -> true
                       {:ok, target} -> Path.expand(target) == Path.expand(lock_path)
                       _ -> false
                     end
                   end) do
                  case Integer.parse(pid_str) do
                    {pid, ""} -> [pid]
                    _ -> []
                  end
                else
                  []
                end

              _ ->
                []
            end
          end)
          |> Enum.uniq()

        {:ok, pids}

      {:error, :enoent} ->
        {:error, :no_proc}

      {:error, :eacces} ->
        {:error, :eacces}

      {:error, _} ->
        {:error, :no_proc}
    end
  end

  # Prefer a process that is *not* blocked in flock (the actual holder), then
  # the Actions-runner shell (GITHUB_RUN_ID / PR) over a bare mix beam that
  # merely inherited the fd.
  defp pick_holder([]), do: nil

  defp pick_holder(described) do
    active = Enum.reject(described, &blocked_in_flock?/1)
    pool = if active == [], do: described, else: active

    Enum.find(pool, &is_binary(&1.run_id)) ||
      Enum.find(pool, &is_integer(&1.pr)) ||
      Enum.find(pool, &is_binary(&1.branch)) ||
      Enum.min_by(pool, & &1.pid, fn -> nil end)
  end

  defp blocked_in_flock?(%{wchan: wchan}) when is_binary(wchan) do
    String.contains?(wchan, "flock") or String.contains?(wchan, "locks_")
  end

  defp blocked_in_flock?(_), do: false

  defp same_run?(%{pid: pid}, %{pid: pid}), do: true

  defp same_run?(%{run_id: id}, %{run_id: id}) when is_binary(id) and id != "", do: true

  defp same_run?(%{pr: pr, branch: b}, %{pr: pr, branch: b})
       when is_integer(pr) and is_binary(b),
       do: true

  defp same_run?(_, _), do: false

  # A waiter is blocked in flock(2) (wchan contains flock/locks_*), or has a
  # distinct run_id/pr while still holding the lock fd open (queued runner
  # that has not yet acquired WRITE). Without wchan evidence and without a
  # distinct identity we treat the process as part of the holder's run.
  defp waiter?(%{wchan: wchan} = h) when is_binary(wchan) do
    String.contains?(wchan, "flock") or String.contains?(wchan, "locks_") or
      distinct_identity_waiter?(h)
  end

  defp waiter?(h), do: distinct_identity_waiter?(h)

  defp distinct_identity_waiter?(%{run_id: id}) when is_binary(id) and id != "", do: true
  defp distinct_identity_waiter?(%{pr: pr}) when is_integer(pr), do: true
  defp distinct_identity_waiter?(_), do: false

  defp describe_pid(proc_root, pid, now) when is_integer(pid) do
    env = read_environ(proc_root, pid)
    cmd = read_cmdline(proc_root, pid)
    started_at = read_started_at(proc_root, pid)

    held_for =
      case started_at do
        %DateTime{} = t -> max(0, DateTime.diff(now, t, :second))
        _ -> nil
      end

    %{
      pid: pid,
      cmd: cmd,
      started_at: started_at,
      held_for_seconds: held_for,
      wchan: read_wchan(proc_root, pid),
      pr: parse_pr(env),
      branch: env_get(env, "GITHUB_HEAD_REF") || env_get(env, "GITHUB_REF_NAME"),
      run_id: env_get(env, "GITHUB_RUN_ID"),
      sha: short_sha(env_get(env, "GITHUB_SHA")),
      workflow: env_get(env, "GITHUB_WORKFLOW")
    }
  end

  # path is Path.join(proc_root, Integer.to_string(pid), "wchan") — pid is integer.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_wchan(proc_root, pid) do
    path = Path.join([proc_root, Integer.to_string(pid), "wchan"])

    case File.read(path) do
      {:ok, body} ->
        case String.trim(body) do
          "" -> nil
          "0" -> nil
          name -> name
        end

      _ ->
        nil
    end
  end

  # path is Path.join(proc_root, Integer.to_string(pid), "environ") — pid is integer.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_environ(proc_root, pid) do
    path = Path.join([proc_root, Integer.to_string(pid), "environ"])

    case File.read(path) do
      {:ok, body} ->
        body
        |> :binary.split(<<0>>, [:global, :trim_all])
        |> Enum.reduce(%{}, fn entry, acc ->
          case String.split(entry, "=", parts: 2) do
            [k, v] -> Map.put(acc, k, v)
            _ -> acc
          end
        end)

      _ ->
        %{}
    end
  end

  # path is Path.join(proc_root, Integer.to_string(pid), "cmdline") — pid is integer.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_cmdline(proc_root, pid) do
    path = Path.join([proc_root, Integer.to_string(pid), "cmdline"])

    case File.read(path) do
      {:ok, body} when body != "" ->
        body
        |> :binary.split(<<0>>, [:global, :trim_all])
        |> Enum.join(" ")
        |> String.slice(0, 160)

      _ ->
        nil
    end
  end

  # stat_path is Path.join(proc_root, Integer.to_string(pid), "stat") — pid is integer.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_started_at(proc_root, pid) do
    stat_path = Path.join([proc_root, Integer.to_string(pid), "stat"])
    # starttime is field 22 (1-indexed) after comm in parens — parse carefully.
    with {:ok, body} <- File.read(stat_path),
         {:ok, start_ticks} <- parse_stat_starttime(body),
         {:ok, btime} <- boot_time_seconds(proc_root),
         {:ok, hz} <- clock_ticks() do
      unix = btime + div(start_ticks, hz)

      DateTime.from_unix(unix)
      |> case do
        {:ok, dt} -> dt
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp parse_stat_starttime(body) when is_binary(body) do
    # Format: pid (comm with spaces) state ppid ... starttime ...
    case Regex.run(~r/^\d+ \((.*)\) (.*)$/s, body) do
      [_, _comm, rest] ->
        fields = String.split(rest)

        # After comm: state is [0], starttime is index 19 (field 22 overall - 3)
        case Enum.at(fields, 19) do
          nil ->
            :error

          token ->
            case Integer.parse(token) do
              {n, ""} when n >= 0 -> {:ok, n}
              _ -> :error
            end
        end

      _ ->
        :error
    end
  end

  # Path.join(proc_root, "stat") — fixed segment under /proc, not user input.
  # sobelow_skip ["Traversal.FileModule"]
  defp boot_time_seconds(proc_root) do
    case File.read(Path.join(proc_root, "stat")) do
      {:ok, body} ->
        body
        |> String.split("\n")
        |> Enum.find_value(fn
          "btime " <> rest ->
            case Integer.parse(String.trim(rest)) do
              {n, _} -> {:ok, n}
              _ -> nil
            end

          _ ->
            nil
        end)
        |> case do
          {:ok, _} = ok -> ok
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp clock_ticks do
    case System.cmd("getconf", ["CLK_TCK"], stderr_to_stdout: true) do
      {out, 0} ->
        case Integer.parse(String.trim(out)) do
          {n, ""} when n > 0 -> {:ok, n}
          _ -> {:ok, 100}
        end

      _ ->
        {:ok, 100}
    end
  end

  defp parse_pr(env) when is_map(env) do
    cond do
      match = Regex.run(~r{refs/pull/(\d+)/}, env_get(env, "GITHUB_REF") || "") ->
        String.to_integer(Enum.at(match, 1))

      match = Regex.run(~r{^(\d+)$}, env_get(env, "GITHUB_PR_NUMBER") || "") ->
        String.to_integer(Enum.at(match, 1))

      true ->
        nil
    end
  end

  defp env_get(env, key), do: blank_to_nil(Map.get(env, key))

  defp short_sha(nil), do: nil

  defp short_sha(sha) when is_binary(sha) do
    sha = String.trim(sha)
    if byte_size(sha) >= 7, do: String.slice(sha, 0, 7), else: sha
  end

  defp blank_to_nil(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      t -> t
    end
  end

  defp blank_to_nil(_), do: nil

  defp holder_label(%{pr: pr}) when is_integer(pr), do: "PR ##{pr}"
  defp holder_label(%{branch: b}) when is_binary(b) and b != "", do: b
  defp holder_label(%{pid: pid}), do: "pid #{pid}"
  defp holder_label(_), do: "unknown"

  defp held_suffix(%{held_for_seconds: s}) when is_integer(s) and s >= 60, do: " · #{div(s, 60)}m"
  defp held_suffix(%{held_for_seconds: s}) when is_integer(s) and s > 0, do: " · #{s}s"
  defp held_suffix(_), do: ""

  defp refresh_held_for(%{lock_state: :held, holder: holder} = snap, now)
       when is_map(holder) do
    holder = refresh_holder(holder, now)
    waiters = Enum.map(snap.waiters || [], &refresh_holder(&1, now))
    %{snap | observed_at: now, holder: holder, waiters: waiters}
  end

  defp refresh_held_for(snap, now), do: %{snap | observed_at: now}

  defp refresh_holder(%{started_at: %DateTime{} = t} = h, now) do
    %{h | held_for_seconds: max(0, DateTime.diff(now, t, :second))}
  end

  defp refresh_holder(h, _), do: h

  defp maybe_refresh(key, fun) when is_function(fun, 0) do
    ensure_cache_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@cache_table, {:refreshing, key}) do
      [{_, until}] when is_integer(until) and until > now ->
        :ok

      _ ->
        :ets.insert(@cache_table, {{:refreshing, key}, now + 1_000})
        _ = Task.start(fun)
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp cache_lookup(lock_path) do
    ensure_cache_table()

    case :ets.lookup(@cache_table, lock_path) do
      [{^lock_path, snap, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at, do: {:ok, snap}, else: :miss

      _ ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp cache_put(lock_path, snap, opts) do
    ensure_cache_table()
    ttl = Keyword.get(opts, :cache_ttl_ms, @default_cache_ttl_ms)
    expires = System.monotonic_time(:millisecond) + ttl
    true = :ets.insert(@cache_table, {lock_path, snap, expires})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp ensure_cache_table do
    case :ets.whereis(@cache_table) do
      :undefined ->
        try do
          :ets.new(@cache_table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end
end
