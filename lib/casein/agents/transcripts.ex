defmodule Casein.Agents.Transcripts do
  @moduledoc """
  Read and normalize agent CLI session transcripts.

  Supports Claude Code JSONL and Grok's persisted ACP `updates.jsonl` stream.
  Callers must pass an explicit `transcript_path` reported by the agent pane —
  Casein never lists profile directories to discover sessions.
  """

  alias Casein.Agents.Transcripts.{Claude, Grok}

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
    home = System.get_env("HOME") || "/home/devbox"

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
      Path.join([System.get_env("HOME") || "/home/devbox", ".casein", "agent-auth"])
  end
end
