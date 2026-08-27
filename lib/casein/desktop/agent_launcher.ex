defmodule Casein.Desktop.AgentLauncher do
  @moduledoc """
  Strict command construction for agent runtimes launched in a native Windows shell.

  Workspace-scoped MCP URLs and credentials are already inherited by the ConPTY
  process, so provider launch commands never contain bearer tokens or config paths.
  """

  alias Casein.Agents.JidoRuntime

  @runtimes %{
    "agent" => %{executable: "agent", command: "agent", auth: :provider_managed},
    "claude" => %{executable: "claude", command: "claude", auth: :claude},
    "clauded" => %{executable: "claude", command: "claude", auth: :claude},
    "codex" => %{executable: "codex", command: "codex", auth: :codex},
    "grok" => %{executable: "grok", command: "grok", auth: :provider_managed},
    "opencode" => %{executable: "opencode", command: "opencode", auth: :provider_managed},
    "cursor" => %{
      executable: "cursor",
      command: "Start-Process cursor -ArgumentList '.'",
      auth: :provider_managed
    }
  }

  @spec supported?(term()) :: boolean()
  def supported?(id), do: is_binary(id) and Map.has_key?(@runtimes, id)

  @doc "Return the normalized headless/provider profile without launching a process."
  @spec runtime_profile(term()) :: {:ok, map()} | {:error, term()}
  def runtime_profile(id) do
    with {:ok, profile} <- JidoRuntime.launcher_profile(id) do
      {:ok, Map.put(profile, :launchable?, is_binary(profile.launcher))}
    end
  end

  @spec command(String.t()) :: {:ok, String.t()} | {:error, :unsupported_agent}
  def command(id) when is_binary(id) do
    case Map.fetch(@runtimes, id) do
      {:ok, %{command: command}} -> {:ok, command <> "\r"}
      :error -> {:error, :unsupported_agent}
    end
  end

  def command(_id), do: {:error, :unsupported_agent}

  @doc "Build a token-free provider command for an already prepared native worktree."
  @spec command(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def command(id, context) when is_binary(id) and is_map(context) do
    with {:ok, runtime} <- fetch_runtime(id),
         {:ok, checkout} <- required_context(context, :checkout),
         {:ok, staging} <- required_context(context, :staging) do
      args = provider_args(id, context, staging)
      executable = runtime.executable

      command =
        if id == "cursor" do
          "Start-Process -FilePath #{ps_quote(executable)} -ArgumentList '.' -WorkingDirectory #{ps_quote(checkout)}"
        else
          "Set-Location -LiteralPath #{ps_quote(checkout)}; & #{ps_quote(executable)}" <>
            Enum.map_join(args, "", &(" " <> ps_quote(&1)))
        end

      {:ok, command <> "\r"}
    end
  end

  def command(_id, _context), do: {:error, :unsupported_agent}

  @doc "Return token-free executable, version, and authentication launch diagnostics."
  @spec diagnose(String.t(), keyword()) :: {:ok, map()} | {:error, :unsupported_agent}
  def diagnose(id, opts \\ [])

  def diagnose(id, opts) when is_binary(id) do
    with {:ok, runtime} <- fetch_runtime(id) do
      resolver = Keyword.get(opts, :resolver, &System.find_executable/1)
      version_runner = Keyword.get(opts, :version_runner, &run_version/2)
      version_timeout = Keyword.get(opts, :version_timeout, 5_000)
      executable = resolver.(runtime.executable)

      {:ok,
       %{
         runtime: id,
         executable: executable,
         executable_status: if(is_binary(executable), do: :available, else: :missing),
         version:
           if(is_binary(executable),
             do: executable |> version_runner.(version_timeout) |> normalize_version(),
             else: {:error, :missing}
           ),
         auth: auth_status(runtime.auth, opts)
       }}
    end
  end

  def diagnose(_id, _opts), do: {:error, :unsupported_agent}

  defp fetch_runtime(id) do
    case Map.fetch(@runtimes, id) do
      {:ok, runtime} -> {:ok, runtime}
      :error -> {:error, :unsupported_agent}
    end
  end

  defp provider_args("claude", _context, staging),
    do: [
      "--mcp-config",
      Path.join(staging, ".mcp.json"),
      "--settings",
      Path.join(staging, "claude-hooks-settings.json")
    ]

  defp provider_args("codex", context, _staging) do
    slug = Map.fetch!(context, :workspace_slug)

    for {key, url} <- [
          {"terminal", Map.fetch!(context, :terminal_url)},
          {"preview", Map.fetch!(context, :preview_url)},
          {"artifact", Map.fetch!(context, :artifact_url)}
        ],
        arg <- [
          "mcp_servers.casein-#{key}-#{slug}.url=\"#{url}\"",
          "mcp_servers.casein-#{key}-#{slug}.enabled=true",
          "mcp_servers.casein-#{key}-#{slug}.bearer_token_env_var=\"CASEIN_API_TOKEN\""
        ] do
      ["-c", arg]
    end
    |> List.flatten()
  end

  defp provider_args(_id, _context, _staging), do: []

  defp required_context(context, key) do
    case Map.get(context, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_launch_context, key}}
    end
  end

  defp ps_quote(value), do: "'" <> String.replace(value, "'", "''") <> "'"

  # executable is resolved from the fixed @runtimes allowlist; System.cmd does not invoke a shell.
  # sobelow_skip ["CI.System"]
  defp run_version(executable, timeout) when is_integer(timeout) and timeout > 0 do
    task = Task.async(fn -> System.cmd(executable, ["--version"], stderr_to_stdout: true) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        {:ok, String.trim(output)}

      {:ok, {output, status}} ->
        {:error, {:exit_status, status, output |> String.trim() |> String.slice(0, 512)}}

      nil ->
        {:error, :version_timeout}
    end
  rescue
    error -> {:error, {:launch_failed, Exception.message(error)}}
  end

  defp normalize_version({:ok, output}) when is_binary(output),
    do: {:ok, String.slice(output, 0, 512)}

  defp normalize_version({:error, reason}), do: {:error, reason}
  defp normalize_version(_other), do: {:error, :invalid_version_result}

  defp auth_status(:provider_managed, _opts), do: :provider_managed

  defp auth_status(provider, opts) when provider in [:claude, :codex] do
    home = Keyword.get(opts, :home) || System.get_env("USERPROFILE") || System.get_env("HOME")

    marker =
      case provider do
        :claude -> [".claude", ".credentials.json"]
        :codex -> [".codex", "auth.json"]
      end

    if is_binary(home) and File.regular?(Path.join([home | marker])),
      do: :signed_in,
      else: :not_detected
  end
end
