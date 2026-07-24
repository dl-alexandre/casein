defmodule Casein.HostMode do
  @moduledoc """
  Pure environment introspection for on-host (devbox-colocated) execution.

  Extracted from `Casein.WorkspaceSource.Manager` so preview can call a leaf
  that has no edges into the runtime SCC. Manager continues to expose the same
  public functions by delegating here.
  """

  # Filesystem root used when Casein runs colocated on the integration host
  # (mirrors what the manager mounts).
  @on_host_workspaces_root "/data/workspaces"

  @doc """
  True when Casein runs colocated on the integration host. Set via
  `:casein, :on_devbox` or env `DEV_IDE_ON_DEVBOX`.
  """
  @spec on_host?() :: boolean()
  def on_host? do
    case Application.get_env(:casein, :on_devbox) do
      nil -> System.get_env("DEV_IDE_ON_DEVBOX") in ~w(1 true yes)
      val -> !!val
    end
  end

  @doc """
  Compose service to exec into for command/terminal execution in on-host
  mode. Set via `:casein, :devbox_exec_service` or env
  `DEV_IDE_DEVBOX_EXEC_SERVICE`; defaults to `"onebackend-v3"`.
  """
  @spec exec_service() :: String.t()
  def exec_service do
    Application.get_env(:casein, :devbox_exec_service) ||
      System.get_env("DEV_IDE_DEVBOX_EXEC_SERVICE") ||
      "onebackend-v3"
  end

  @doc """
  Working directory inside the exec service container.
  """
  @spec exec_workdir() :: String.t()
  def exec_workdir do
    Application.get_env(:casein, :devbox_exec_workdir) ||
      System.get_env("DEV_IDE_DEVBOX_EXEC_WORKDIR") ||
      "/app"
  end

  @doc "Wrap a local-spawn argv for on-host container execution, or identity."
  @spec prepare_local_argv([String.t()]) :: [String.t()]
  def prepare_local_argv(argv) when is_list(argv), do: prepare_local_argv(argv, [])

  @doc """
  Wrap a local-spawn argv with opts. Recognised opts match
  `Casein.WorkspaceSource.prepare_local_argv/2` (`:tty`, `:cwd`, `:workdir`,
  `:normal_cwd`).
  """
  @spec prepare_local_argv([String.t()], keyword()) :: [String.t()]
  def prepare_local_argv(argv, opts) when is_list(argv) and is_list(opts) do
    if on_host?(), do: compose_exec_argv(argv, opts), else: argv
  end

  defp compose_exec_argv(argv, opts) do
    docker_bin = System.find_executable("docker") || "/usr/bin/docker"
    tty_flag = if Keyword.get(opts, :tty, false), do: [], else: ["-T"]
    argv = maybe_bootstrap_normal_cwd(argv, Keyword.get(opts, :normal_cwd))

    [docker_bin, "compose"] ++
      project_dir_args(opts) ++
      ["exec"] ++ tty_flag ++ workdir_args(opts) ++ [exec_service() | argv]
  end

  defp project_dir_args(opts) do
    case Keyword.get(opts, :cwd) do
      dir when is_binary(dir) and dir != "" -> ["--project-directory", dir]
      _ -> []
    end
  end

  defp workdir_args(opts) do
    case Keyword.get(opts, :workdir) do
      dir when is_binary(dir) and dir != "" -> ["--workdir", dir]
      _ -> ["--workdir", exec_workdir()]
    end
  end

  defp maybe_bootstrap_normal_cwd(argv, normal_cwd)
       when is_binary(normal_cwd) and normal_cwd != "" do
    normalized = Path.expand(normal_cwd)

    if under_root?(normalized, @on_host_workspaces_root) and normalized != exec_workdir() do
      parent = Path.dirname(normalized)

      script =
        [
          "mkdir -p #{shell_quote(parent)}",
          "if [ ! -e #{shell_quote(normalized)} ]; then ln -s #{shell_quote(exec_workdir())} #{shell_quote(normalized)}; fi",
          "cd #{shell_quote(normalized)}",
          "exec #{shell_join(argv)}"
        ]
        |> Enum.join(" && ")

      ["sh", "-lc", script]
    else
      argv
    end
  end

  defp maybe_bootstrap_normal_cwd(argv, _normal_cwd), do: argv

  defp under_root?(path, root) do
    rel = Path.relative_to(path, root)
    rel != path and not String.starts_with?(rel, "..")
  end

  defp shell_join(argv), do: Enum.map_join(argv, " ", &shell_quote/1)

  defp shell_quote(value) do
    "'" <> (value |> to_string() |> String.replace("'", "'\\''")) <> "'"
  end
end
