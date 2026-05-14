defmodule DevIDE.Commands.DockerExecAdapter do
  @moduledoc """
  On-devbox command runner. When DevIDE runs on the devbox host itself, the
  toolchain lives inside each workspace's app container, not on the host — so
  commands run via `docker compose exec -T <service>` from the workspace
  directory (which holds the `docker-compose.yml`).

  Same subscriber protocol as `DevIDE.Commands.LocalAdapter`:

      {:cmd_data, ref, :stdout | :stderr, binary}
      {:cmd_exit, ref, exit_code :: integer()}

  This is the no-ssh counterpart of `DevIDE.Commands.SshAdapter`.
  """

  @behaviour DevIDE.Commands

  alias DevIDE.Commands.PortExec

  @impl true
  def spawn(root, argv, subscriber)
      when is_binary(root) and is_list(argv) and is_pid(subscriber) do
    service = DevIDE.Workspaces.devbox_exec_service()
    docker_bin = System.find_executable("docker") || "/usr/bin/docker"

    # `-T` disables pseudo-tty allocation — these are batch commands whose
    # output is streamed, not interactive sessions. `{:cd, root}` puts compose
    # in the workspace dir so it finds the project's compose file.
    docker_argv = [docker_bin, "compose", "exec", "-T", service | argv]

    PortExec.run(docker_argv, [{:cd, to_charlist(root)}], subscriber)
  end

  def spawn(_, _, _), do: {:error, :bad_args}

  @impl true
  def kill(handle), do: PortExec.kill(handle)
end
