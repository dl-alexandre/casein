defmodule DevIDE.Agents.Transcripts do
  @moduledoc """
  Read and normalize agent CLI session transcripts.

  v1 supports Claude Code JSONL (via `DevIDE.Agents.Transcripts.Claude`). Callers
  must pass an explicit `transcript_path` reported by the agent pane — DevIDE never
  lists profile directories to discover sessions.
  """

  alias DevIDE.Agents.Transcripts.Claude

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
    with :ok <- validate_path(path) do
      Claude.read(path, opts)
    end
  end

  @doc "Whether `path` is an allowed Claude JSONL transcript location."
  @spec allowed_path?(String.t()) :: boolean()
  def allowed_path?(path) when is_binary(path), do: match?(:ok, validate_path(path))
  def allowed_path?(_), do: false

  @doc """
  Return a short human hint about what the agent is doing, derived from the
  transcript tail (e.g. "editing show.ex" or "Read path=...").
  """
  @spec activity_hint(String.t(), keyword()) :: String.t() | nil
  def activity_hint(path, opts \\ []) when is_binary(path) do
    with :ok <- validate_path(path), do: Claude.activity_hint(path, opts)
  end

  @doc "Return the final assistant message on the active transcript branch."
  @spec final_assistant_message(String.t()) :: String.t() | nil
  def final_assistant_message(path) when is_binary(path) do
    with :ok <- validate_path(path), do: Claude.final_assistant_message(path)
  end

  defp validate_path(path) do
    expanded = Path.expand(path)

    cond do
      not String.ends_with?(expanded, ".jsonl") ->
        {:error, :invalid_transcript_path}

      not File.regular?(expanded) ->
        {:error, :invalid_transcript_path}

      not under_allowed_root?(expanded) ->
        {:error, :invalid_transcript_path}

      true ->
        :ok
    end
  end

  defp under_allowed_root?(path) do
    Enum.any?(allowed_roots(), fn root ->
      root != path and String.starts_with?(path, root <> "/")
    end)
  end

  defp allowed_roots do
    home = System.get_env("HOME") || "/home/devbox"

    [
      Path.join(auth_root(), "profiles"),
      Path.expand(Path.join(home, ".claude"))
    ]
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp auth_root do
    Application.get_env(:dev_ide, :agent_auth_profile_root) ||
      System.get_env("DEVIDE_AGENT_AUTH_ROOT") ||
      Path.join([System.get_env("HOME") || "/home/devbox", ".devide", "agent-auth"])
  end
end
