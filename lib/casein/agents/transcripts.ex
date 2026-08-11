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
