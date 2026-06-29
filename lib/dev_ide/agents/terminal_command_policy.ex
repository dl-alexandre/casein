defmodule DevIDE.Agents.TerminalCommandPolicy do
  @moduledoc """
  Allow/deny gate for terminal MCP command execution.

  The Terminal MCP bearer token is fully trusted on the host, and
  `terminal_send_command` / `terminal_send_agent_command` run arbitrary shell.
  This module is a policy layer in front of those two tools so operators
  can constrain what agents may run without rewriting the trust model.

  Scope: only the **command** tools are gated. `terminal_send_keys` /
  `terminal_send_agent_keys` carry raw key sequences (control keys like `C-c`,
  `Enter`, arrow keys, characters typed into a TUI) and gating them would break
  interactivity, so they always pass.

  ## Configuration

  The default is a conservative denylist for high-risk host-level commands.
  Configure via application env:

      config :dev_ide, :terminal_command_policy, {:allowlist, ["^mix ", "^git "]}
      config :dev_ide, :terminal_command_policy, {:denylist, ["rm -rf", "curl "]}

  Or, for releases, the `DEV_IDE_TERMINAL_COMMAND_POLICY` env var as JSON:

      {"mode":"allowlist","patterns":["^mix ","^git "]}

  Patterns are regular expressions matched against the full command string. An
  allowlist permits only matching commands; a denylist blocks matching commands.
  Set `:disabled` explicitly to preserve fully trusted local behaviour.
  """

  @command_tools ~w(terminal_send_command terminal_send_agent_command)
  @default_denylist [
    "(^|[;&|]\\s*)rm\\s+-[A-Za-z]*r[A-Za-z]*f[A-Za-z]*\\s+/",
    "(^|[;&|]\\s*)curl\\b.*\\|\\s*(sh|bash)\\b",
    "(^|[;&|]\\s*)wget\\b.*\\|\\s*(sh|bash)\\b",
    "(^|[;&|]\\s*)sudo\\b"
  ]
  @default_policy {:denylist, @default_denylist}

  @type mode :: :allowlist | :denylist
  @type policy :: :disabled | {mode(), [Regex.t() | String.t()]}

  @doc """
  Authorize a terminal tool call. Returns `:ok` when allowed (the default for
  every non-command tool and whenever no policy is configured), or
  `{:error, map}` with a structured `command_blocked` payload when denied.
  """
  @spec authorize(String.t(), map()) :: :ok | {:error, map()}
  def authorize(tool, params) when tool in @command_tools and is_map(params) do
    case policy() do
      :disabled -> :ok
      {mode, patterns} -> evaluate(mode, patterns, command(params), tool)
    end
  end

  def authorize(_tool, _params), do: :ok

  # No command text to judge — let the tool handler return its own missing-arg error.
  defp evaluate(_mode, _patterns, nil, _tool), do: :ok

  defp evaluate(:allowlist, patterns, command, tool) do
    if Enum.any?(patterns, &matches?(&1, command)),
      do: :ok,
      else: {:error, blocked(tool, command, :not_allowlisted)}
  end

  defp evaluate(:denylist, patterns, command, tool) do
    if Enum.any?(patterns, &matches?(&1, command)),
      do: {:error, blocked(tool, command, :denylisted)},
      else: :ok
  end

  defp matches?(%Regex{} = regex, command), do: Regex.match?(regex, command)

  defp matches?(pattern, command) when is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.match?(regex, command)
      _ -> false
    end
  end

  defp matches?(_pattern, _command), do: false

  defp command(params) do
    case Map.get(params, "command") || Map.get(params, :command) do
      command when is_binary(command) and command != "" -> command
      _ -> nil
    end
  end

  defp blocked(tool, command, reason) do
    %{
      error: :command_blocked,
      tool: tool,
      command: command,
      reason: reason,
      message:
        "Command blocked by terminal_command_policy (#{reason}). " <>
          "Adjust :terminal_command_policy / DEV_IDE_TERMINAL_COMMAND_POLICY to allow it."
    }
  end

  @doc "The resolved policy: application env first, then the release env var."
  @spec policy() :: policy()
  def policy do
    case Application.get_env(:dev_ide, :terminal_command_policy) do
      nil ->
        policy_from_env()

      :disabled ->
        :disabled

      {mode, patterns} when mode in [:allowlist, :denylist] and is_list(patterns) ->
        {mode, patterns}

      _ ->
        @default_policy
    end
  end

  defp policy_from_env do
    case System.get_env("DEV_IDE_TERMINAL_COMMAND_POLICY") do
      raw when is_binary(raw) and raw != "" -> parse_env(raw)
      _ -> @default_policy
    end
  end

  defp parse_env(raw) do
    with {:ok, %{"mode" => mode, "patterns" => patterns}} <- Jason.decode(raw),
         true <- mode in ["allowlist", "denylist"],
         true <- is_list(patterns) do
      {String.to_existing_atom(mode), Enum.filter(patterns, &is_binary/1)}
    else
      _ -> @default_policy
    end
  end
end
