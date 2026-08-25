defmodule Casein.Agents.Transcripts.Discovery do
  @moduledoc """
  Find the Claude Code transcript belonging to a pane, from the pane's own
  working directory.

  `Casein.Agents.Transcripts` reads only paths an agent *reported*, which means
  a pane without hooks — the worker panes that most need external observation —
  has no transcript at all. This module closes that gap without reopening the
  boundary the reported-path rule exists to protect.

  ## What it will and will not look at

  Claude names its session directory after the working directory, replacing `/`
  and `.` with `-`:

      /data/casein-agent-worktrees/wt-a  ->  -data-casein-agent-worktrees-wt-a

  Discovery lists **that one directory**, under roots the caller supplies (an
  owner's auth profile, then the host global login). It never walks the profile
  tree, never sees another owner's profile, and never returns a path outside the
  directory belonging to the cwd it was given.

  ## Ambiguity is refused, not guessed

  Two agents in one worktree produce two session files in one directory, and
  "newest mtime" would silently hand one pane the other's conversation — an
  agent shown as waiting because its neighbour is. When more than one session
  looks live within `:live_window_seconds`, discovery returns
  `{:error, :ambiguous}` and the caller shows nothing.

  Sessions older than that window are not live evidence about anything, so a
  directory full of finished conversations resolves cleanly to its one live
  session.
  """

  # Beyond this a session is history, not evidence about a running pane. Matches
  # `Casein.Terminals.AgentState`'s max report TTL so a transcript and a report
  # go stale together.
  @live_window_seconds 1_800

  @type error_reason ::
          :no_cwd
          | :no_transcript_dir
          | :no_live_transcript
          | :ambiguous
          | :path_missing
          | :invalid_session_id

  @doc "Seconds within which a session file counts as live evidence."
  @spec live_window_seconds() :: pos_integer()
  def live_window_seconds, do: @live_window_seconds

  @doc """
  The Claude project directory name for a working directory.

  Pure and total: callers use it to build a candidate path, never to decide the
  path exists.
  """
  @spec project_slug(String.t()) :: String.t()
  def project_slug(cwd) when is_binary(cwd) do
    cwd
    |> Path.expand()
    |> String.replace(~r{[/.]}, "-")
  end

  @doc """
  Resolve the live transcript for `cwd` under `roots`.

  `roots` are `.../projects` directories in precedence order — owner profile
  first, host global login last. Options:

    * `:now` — reference time (defaults to `DateTime.utc_now/0`)
    * `:live_window_seconds` — how recently a session must have been written to
      count as live
  """
  @spec resolve(String.t() | nil, [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, error_reason()}
  def resolve(cwd, roots, opts \\ [])

  def resolve(cwd, roots, opts) when is_binary(cwd) and cwd != "" and is_list(roots) do
    slug = project_slug(cwd)
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    window = Keyword.get(opts, :live_window_seconds, @live_window_seconds)

    dirs =
      roots
      |> Enum.map(&Path.join(&1, slug))
      |> Enum.filter(&File.dir?/1)

    # "No directory for this cwd" and "a directory whose sessions are all
    # finished" are different facts, and collapsing them would hide a
    # misderived slug behind a plausible-looking empty result.
    if dirs == [] do
      {:error, :no_transcript_dir}
    else
      dirs
      |> Enum.find_value(fn dir ->
        case live_sessions(dir, now, window) do
          [] -> nil
          sessions -> sessions
        end
      end)
      |> case do
        nil -> {:error, :no_live_transcript}
        [path] -> {:ok, path}
        [_ | _] -> {:error, :ambiguous}
      end
    end
  end

  def resolve(cwd, _roots, _opts) when is_binary(cwd), do: {:error, :no_cwd}
  def resolve(nil, _roots, _opts), do: {:error, :no_cwd}

  @doc """
  Resolve the transcript file named for `session_id` under `cwd`.

  Claude writes `{session_id}.jsonl` in the project directory derived from the
  launch cwd. Unlike `resolve/3` this is unambiguous even when two sessions
  look live: the id is the file name.
  """
  @spec resolve_session(String.t() | nil, String.t() | nil, [String.t()]) ::
          {:ok, String.t()} | {:error, error_reason()}
  def resolve_session(cwd, session_id, roots)

  def resolve_session(cwd, session_id, roots)
      when is_binary(cwd) and cwd != "" and is_binary(session_id) and is_list(roots) do
    case session_filename(session_id) do
      {:ok, filename} ->
        slug = project_slug(cwd)

        dirs =
          roots
          |> Enum.map(&Path.join(&1, slug))
          |> Enum.filter(&File.dir?/1)

        if dirs == [] do
          {:error, :no_transcript_dir}
        else
          dirs
          |> Enum.map(&Path.join(&1, filename))
          |> Enum.find(&File.regular?/1)
          |> case do
            nil -> {:error, :path_missing}
            path -> {:ok, path}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def resolve_session(_cwd, session_id, _roots)
      when not is_binary(session_id) or session_id == "",
      do: {:error, :invalid_session_id}

  def resolve_session(_cwd, _session_id, _roots), do: {:error, :no_cwd}

  defp session_filename(session_id) do
    trimmed = String.trim(session_id)

    cond do
      trimmed == "" ->
        {:error, :invalid_session_id}

      String.contains?(trimmed, ["/", "\\", ".."]) ->
        {:error, :invalid_session_id}

      not Regex.match?(~r/^[A-Za-z0-9._-]+$/, trimmed) ->
        {:error, :invalid_session_id}

      String.ends_with?(trimmed, ".jsonl") ->
        {:ok, trimmed}

      true ->
        {:ok, trimmed <> ".jsonl"}
    end
  end

  # One `ls` of a single directory whose name is derived from the caller's own
  # cwd. Non-`.jsonl` entries and subdirectories are ignored rather than
  # descended.
  # sobelow_skip ["Traversal.FileModule"]
  defp live_sessions(dir, now, window) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&live?(&1, now, window))

      {:error, _reason} ->
        []
    end
  end

  defp live?(path, now, window) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, mtime: mtime}} ->
        DateTime.diff(now, DateTime.from_unix!(mtime), :second) <= window

      _other ->
        false
    end
  end
end
