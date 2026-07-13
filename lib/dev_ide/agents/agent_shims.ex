defmodule DevIDE.Agents.AgentShims do
  @moduledoc """
  Ensures DevIDE agent launcher shims exist under `~/.devide/agent-shims`.

  Inside DevIDE contexts (pane env, shell integration, agent env files) the
  shim dir is injected at the front of PATH so bare names (`claude`, `grok`,
  …) resolve to the DevIDE launcher and MCP injection runs. The dir is never
  on PATH in plain terminals, so DevIDE leaves the host's commands untouched.
  npm package updates and partial installs have left individual shims missing
  while siblings remained — this module self-heals on session env setup and
  can be called from deploy/doctor scripts.
  """

  require Logger

  @runtimes ~w(grok claude codex opencode agent)
  @default_bin_dir "~/.devide/agent-shims"
  @default_npm_prefix "~/.local/share/npm-global"

  @doc "Agent runtime names that get a DevIDE launcher shim (not `clauded`)."
  @spec runtimes() :: [String.t()]
  def runtimes, do: @runtimes

  @doc "Directory that holds DevIDE agent launcher shims."
  @spec bin_dir() :: String.t()
  def bin_dir do
    :dev_ide
    |> Application.get_env(:agent_bin_dir)
    |> non_empty_or(System.get_env("DEV_IDE_AGENT_BIN_DIR"))
    |> non_empty_or(@default_bin_dir)
    |> Path.expand()
  end

  @doc "npm global prefix used for real agent package binaries."
  @spec npm_prefix() :: String.t()
  def npm_prefix do
    :dev_ide
    |> Application.get_env(:agent_npm_prefix)
    |> non_empty_or(System.get_env("DEV_IDE_NPM_PREFIX"))
    |> non_empty_or(@default_npm_prefix)
    |> Path.expand()
  end

  @doc "Directory containing npm-installed agent package bins."
  @spec npm_bin_dir() :: String.t()
  def npm_bin_dir, do: Path.join(npm_prefix(), "bin")

  @doc "Absolute path to a runtime's launcher shim."
  @spec shim_path(String.t()) :: String.t()
  def shim_path(name) when is_binary(name), do: Path.join(bin_dir(), name)

  @doc "Runtimes whose shim is missing or not executable."
  @spec missing() :: [String.t()]
  def missing do
    Enum.reject(@runtimes, &shim_ok?/1)
  end

  @doc "True when every expected agent launcher shim is present and executable."
  @spec complete?() :: boolean()
  def complete?, do: missing() == []

  @doc """
  Ensure all agent launcher shims exist.

  When any are missing, runs `scripts/install-agent-shims.sh` from the best
  available checkout/deploy path. Returns `{:ok, :present}` when already
  complete, `{:ok, :installed}` after a successful reinstall, or
  `{:error, reason}` when repair is not possible.
  """
  @spec ensure() :: {:ok, :present | :installed} | {:error, term()}
  def ensure do
    case missing() do
      [] ->
        {:ok, :present}

      missing ->
        Logger.warning("agent shims missing: #{Enum.join(missing, ", ")} — reinstalling")

        case reinstall() do
          :ok ->
            case missing() do
              [] ->
                {:ok, :installed}

              still ->
                {:error, {:still_missing, still}}
            end

          {:error, _} = error ->
            error
        end
    end
  end

  @doc "Best-effort ensure; logs and returns `:ok` / `:error` without raising."
  @spec ensure_best_effort() :: :ok | :error
  def ensure_best_effort do
    case ensure() do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("agent shim ensure failed: #{inspect(reason)}")
        :error
    end
  end

  @doc false
  @spec shim_ok?(String.t()) :: boolean()
  def shim_ok?(name) when is_binary(name) do
    path = shim_path(name)

    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        # owner/group/other execute bit
        Bitwise.band(mode, 0o111) != 0

      _ ->
        false
    end
  end

  defp reinstall do
    case install_script() do
      {:ok, script} ->
        env = [
          {"HOME", System.get_env("HOME") || "/home/devbox"},
          {"PATH", System.get_env("PATH") || "/usr/bin:/bin"},
          {"DEV_IDE_NPM_PREFIX", npm_prefix()}
        ]

        case System.cmd("bash", [script],
               stderr_to_stdout: true,
               env: env,
               cd: Path.dirname(Path.dirname(script))
             ) do
          {_out, 0} ->
            :ok

          {out, code} ->
            {:error, {:install_failed, code, String.slice(out, 0, 800)}}
        end

      :error ->
        {:error, :install_script_not_found}
    end
  end

  defp install_script do
    install_script_candidates()
    |> Enum.find(&File.regular?/1)
    |> case do
      path when is_binary(path) -> {:ok, path}
      nil -> :error
    end
  end

  defp install_script_candidates do
    [
      Application.get_env(:dev_ide, :install_agent_shims_path),
      join_scripts_env("DEVIDE_SCRIPTS"),
      join_agent_scripts_path(),
      Path.expand("scripts/install-agent-shims.sh"),
      "/opt/devide/deploy-build/scripts/install-agent-shims.sh"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp join_scripts_env(name) do
    case System.get_env(name) do
      path when is_binary(path) and path != "" ->
        Path.join(path, "install-agent-shims.sh")

      _ ->
        nil
    end
  end

  defp join_agent_scripts_path do
    case Application.get_env(:dev_ide, :agent_scripts_path) do
      path when is_binary(path) and path != "" ->
        Path.join(path, "install-agent-shims.sh")

      _ ->
        nil
    end
  end

  defp non_empty_or(value, fallback) when value in [nil, ""], do: fallback
  defp non_empty_or(value, _fallback), do: value
end
