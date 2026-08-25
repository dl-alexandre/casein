defmodule Casein.Agents.Transcripts do
  @moduledoc """
  Read and normalize agent CLI session transcripts.

  Supports Claude Code JSONL and Grok's persisted ACP `updates.jsonl` stream.

  ## Two ways in, one gate

  `read/2`, `activity_hint/2` and `evidence/2` take an explicit
  `transcript_path` reported by the agent pane. Casein does not sweep profile
  directories looking for sessions.

  `discover/2` is the narrow exception, for panes whose agent reports nothing:
  given a pane's working directory it lists the *single* directory Claude
  derives from that cwd, under the owner's auth profile and then the host global
  login. It cannot reach another owner's profile or any path outside that one
  directory, it refuses to guess when two sessions look live, and its result
  still clears `allowed_path?/1` before anything reads it.
  """

  alias Casein.Agents.Transcripts.{Claude, Discovery, Evidence, Grok}

  @default_tail 30

  @type tool_call :: %{name: String.t(), input_summary: String.t()}

  @type entry :: %{
          optional(:role) => String.t(),
          optional(:text) => String.t(),
          optional(:tool_calls) => [tool_call()],
          optional(:timestamp) => String.t(),
          required(:cursor) => String.t()
        }

  @doc """
  Read a transcript file and return normalized entries on the active branch.

  Options:
    * `:since` — cursor uuid; return only entries after this point on the branch
    * `:tail` — max entries to return (default #{@default_tail})
    * `:full_text` — when true, do not truncate long text bodies
  """
  @spec read(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(path, opts \\ []) when is_binary(path) do
    with {:ok, adapter, expanded} <- transcript_adapter(path) do
      adapter.read(expanded, opts)
    end
  end

  @doc "Whether `path` is an allowed agent JSONL transcript location."
  @spec allowed_path?(String.t()) :: boolean()
  def allowed_path?(path) when is_binary(path),
    do: match?({:ok, _adapter, _expanded}, transcript_adapter(path))

  def allowed_path?(_), do: false

  @doc """
  Return a short human hint about what the agent is doing, derived from the
  transcript tail (e.g. "editing show.ex" or "Read path=...").
  """
  @spec activity_hint(String.t(), keyword()) :: String.t() | nil
  def activity_hint(path, opts \\ []) when is_binary(path) do
    case transcript_adapter(path) do
      {:ok, adapter, expanded} -> adapter.activity_hint(expanded, opts)
      {:error, _reason} -> nil
    end
  end

  @doc "Return the final assistant message on the active transcript branch."
  @spec final_assistant_message(String.t()) :: String.t() | nil
  def final_assistant_message(path) when is_binary(path) do
    case transcript_adapter(path) do
      {:ok, adapter, expanded} -> adapter.final_assistant_message(expanded)
      {:error, _reason} -> nil
    end
  end

  @doc """
  Conversation-shape evidence for a transcript — see
  `Casein.Agents.Transcripts.Evidence`.

  Only Claude Code transcripts carry turn shapes we can read; Grok's ACP stream
  returns `{:error, :unsupported_transcript_kind}` rather than a guess.
  """
  @spec evidence(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def evidence(path, opts \\ []) when is_binary(path) do
    case transcript_adapter(path) do
      {:ok, Claude, expanded} -> Evidence.observe(expanded, opts)
      {:ok, _other, _expanded} -> {:error, :unsupported_transcript_kind}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Find the live Claude transcript for a pane's working directory.

  Unlike `read/2`, this does not need the agent to have reported anything — it
  is the path for hook-less panes. Discovery is scoped to the directory Claude
  derives from `cwd`, under `owner`'s auth profile and then the host global
  login. See `Casein.Agents.Transcripts.Discovery` for the ambiguity rule.

  Options: `:claude_home` (an already-resolved provider home, as
  `Casein.Agents.AuthProfile.active_profile_dir/2` returns) or `:owner` (a
  profile slug), plus anything `Discovery.resolve/3` accepts.
  """
  @spec discover(String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, Discovery.error_reason()}
  def discover(cwd, opts \\ []) do
    roots = project_roots(Keyword.get(opts, :claude_home), Keyword.get(opts, :owner))

    with {:ok, path} <- Discovery.resolve(cwd, roots, opts) do
      # Discovery builds paths from a slug, so the result must still clear the
      # same gate a reported path does before anything reads it.
      if allowed_path?(path), do: {:ok, path}, else: {:error, :no_live_transcript}
    end
  end

  @hookless_runtimes ~w(opencode cursor)

  @type resolve_reason ::
          Discovery.error_reason()
          | :no_hook
          | :unsupported_runtime

  @doc """
  Resolve a pane's transcript on every call.

  A hook-reported path is used only while it still exists. After a TUI view
  switch the cache is often gone while `agent_session_id` and the worktree
  remain — this rebuilds the path from those, then falls back to cwd discovery.
  """
  @spec resolve_for_pane(map() | nil, keyword()) ::
          {:ok, String.t()} | {:error, resolve_reason()}
  def resolve_for_pane(pane, opts \\ [])

  def resolve_for_pane(pane, opts) when is_map(pane) do
    report = Keyword.get(opts, :report)
    locations = pane_locations(pane)

    cond do
      usable_reported_path?(report) ->
        {:ok, report.transcript_path}

      true ->
        case resolve_from_identity(report, locations, opts) do
          {:ok, path} -> {:ok, path}
          {:error, reason} -> {:error, classify_failure(reason, report, pane)}
        end
    end
  end

  def resolve_for_pane(_pane, opts) do
    case Keyword.get(opts, :report) do
      %{transcript_path: path} = report when is_binary(path) and path != "" ->
        if allowed_path?(path) do
          {:ok, path}
        else
          {:error, classify_failure(:path_missing, report, %{})}
        end

      report ->
        {:error, classify_failure(:no_cwd, report, %{})}
    end
  end

  defp usable_reported_path?(%{transcript_path: path}) when is_binary(path) and path != "",
    do: allowed_path?(path)

  defp usable_reported_path?(_report), do: false

  defp resolve_from_identity(%{agent_session_id: session_id}, locations, opts)
       when is_binary(session_id) and session_id != "" do
    case discover_session(session_id, locations, opts) do
      {:ok, path} -> {:ok, path}
      {:error, _reason} -> {:error, :path_missing}
    end
  end

  defp resolve_from_identity(_report, locations, opts), do: discover_first(locations, opts)

  defp discover_session(session_id, locations, opts) do
    roots = project_roots(Keyword.get(opts, :claude_home), Keyword.get(opts, :owner))

    Enum.reduce_while(locations, {:error, :no_cwd}, fn cwd, acc ->
      case Discovery.resolve_session(cwd, session_id, roots) do
        {:ok, path} ->
          if allowed_path?(path), do: {:halt, {:ok, path}}, else: {:halt, {:error, :path_missing}}

        {:error, :no_cwd} ->
          {:cont, acc}

        {:error, reason} ->
          {:cont, {:error, reason}}
      end
    end)
  end

  defp discover_first(locations, opts) do
    Enum.reduce_while(locations, {:error, :no_cwd}, fn cwd, acc ->
      case discover(cwd, opts) do
        {:ok, path} -> {:halt, {:ok, path}}
        {:error, :no_cwd} -> {:cont, acc}
        {:error, reason} -> {:cont, {:error, reason}}
      end
    end)
  end

  defp classify_failure(:path_missing, _report, _pane), do: :path_missing
  defp classify_failure(:invalid_session_id, _report, _pane), do: :path_missing

  defp classify_failure(reason, report, pane) do
    cond do
      hookless_runtime?(pane) -> :unsupported_runtime
      not has_hook_pointer?(report) -> :no_hook
      true -> reason
    end
  end

  defp has_hook_pointer?(%{transcript_path: path}) when is_binary(path) and path != "", do: true
  defp has_hook_pointer?(%{agent_session_id: id}) when is_binary(id) and id != "", do: true
  defp has_hook_pointer?(_report), do: false

  defp hookless_runtime?(pane) when is_map(pane) do
    case pane_string(pane, :current_command) do
      nil -> false
      command -> String.downcase(command) in @hookless_runtimes
    end
  end

  defp hookless_runtime?(_pane), do: false

  defp pane_locations(pane) do
    [pane_string(pane, :current_path), pane_string(pane, :worktree_path)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp pane_string(pane, key) do
    case Map.get(pane, key) || Map.get(pane, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  # Owner profile first: on a multi-owner box the host global login is the
  # fallback for owners who have not signed in, and must never shadow another
  # owner's profile.
  defp project_roots(claude_home, owner) do
    [claude_home, owner_profile_dir(owner)]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Path.join(&1, "projects"))
    |> Kernel.++([Path.join(Path.expand(Path.join(Casein.Paths.home!(), ".claude")), "projects")])
    |> Enum.uniq()
  end

  defp owner_profile_dir(owner) when is_binary(owner) and owner != "" do
    Casein.Agents.AuthProfile.named_profile_dir(owner, :claude)
  end

  defp owner_profile_dir(_owner), do: nil

  defp transcript_adapter(path) do
    expanded = Path.expand(path)

    cond do
      not String.ends_with?(expanded, ".jsonl") ->
        {:error, :invalid_transcript_path}

      not File.regular?(expanded) ->
        {:error, :invalid_transcript_path}

      Grok.allowed_path?(expanded) ->
        {:ok, Grok, expanded}

      under_claude_root?(expanded) ->
        {:ok, Claude, expanded}

      true ->
        {:error, :invalid_transcript_path}
    end
  end

  defp under_claude_root?(path) do
    Enum.any?(claude_roots(), fn root ->
      root != path and String.starts_with?(path, root <> "/")
    end)
  end

  defp claude_roots do
    home = Casein.Paths.home!()

    [
      Path.join(auth_root(), "profiles"),
      Path.expand(Path.join(home, ".claude"))
    ]
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp auth_root do
    Application.get_env(:casein, :agent_auth_profile_root) ||
      System.get_env("CASEIN_AGENT_AUTH_ROOT") ||
      Path.join([Casein.Paths.home!(), ".casein", "agent-auth"])
  end
end
