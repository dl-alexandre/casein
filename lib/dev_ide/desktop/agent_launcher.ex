defmodule DevIDE.Desktop.AgentLauncher do
  @moduledoc """
  Strict command construction for agent runtimes launched in a native Windows shell.

  Workspace-scoped MCP URLs and credentials are already inherited by the ConPTY
  process, so provider launch commands never contain bearer tokens or config paths.
  """

  @commands %{
    "agent" => "agent",
    "claude" => "claude",
    "clauded" => "claude",
    "codex" => "codex",
    "grok" => "grok",
    "opencode" => "opencode",
    "cursor" => "Start-Process cursor -ArgumentList '.'"
  }

  @spec supported?(term()) :: boolean()
  def supported?(id), do: is_binary(id) and Map.has_key?(@commands, id)

  @spec command(String.t()) :: {:ok, String.t()} | {:error, :unsupported_agent}
  def command(id) when is_binary(id) do
    case Map.fetch(@commands, id) do
      {:ok, command} -> {:ok, command <> "\r"}
      :error -> {:error, :unsupported_agent}
    end
  end

  def command(_id), do: {:error, :unsupported_agent}
end
