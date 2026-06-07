defmodule DevIDE.Commands.SshAdapter do
  @moduledoc """
  Remote command runner. Wraps an argv invocation in `ssh <host> -- bash -lc
  'cd <path> && exec <argv...>'` and streams the remote output back via
  erlexec. Same subscriber protocol as `DevIDE.Commands.LocalAdapter`:

      {:cmd_data, ref, :stdout | :stderr, binary}
      {:cmd_exit, ref, exit_code :: integer()}
  """

  @behaviour DevIDE.Commands

  alias DevIDE.Commands.PortExec

  @impl true
  def spawn({:remote, host, root}, argv, subscriber)
      when is_binary(host) and is_binary(root) and is_list(argv) and is_pid(subscriber) do
    prefix = remote_exec_prefix()
    quoted_argv = argv |> Enum.map(&shell_quote/1) |> Enum.join(" ")

    inner =
      "cd " <>
        shell_quote(root) <>
        " && exec " <>
        if(prefix == "", do: quoted_argv, else: shell_quote(prefix) <> " " <> quoted_argv)

    # `bash -lc` runs a login shell so the user's PATH (asdf, mise, etc.)
    # loads; otherwise non-interactive ssh skips ~/.profile and `mix` isn't
    # on PATH. Set `DEV_IDE_REMOTE_EXEC_PREFIX` to wrap commands (e.g.
    # `docker compose exec -T onebackend-v3`) when the toolchain lives in
    # a container rather than on the ssh host.
    remote_cmd = "bash -lc " <> shell_quote(inner)

    ssh_bin = System.find_executable("ssh") || "/usr/bin/ssh"

    ssh_argv = [
      ssh_bin,
      "-o",
      "BatchMode=yes",
      "-o",
      "ServerAliveInterval=30",
      "-o",
      "ConnectTimeout=10",
      host,
      "--",
      remote_cmd
    ]

    PortExec.run(ssh_argv, [], subscriber)
  end

  def spawn(_, _, _), do: {:error, :bad_args}

  @impl true
  def kill(handle), do: PortExec.kill(handle)

  defp remote_exec_prefix do
    Application.get_env(:dev_ide, :remote_exec_prefix) ||
      System.get_env("DEV_IDE_REMOTE_EXEC_PREFIX") ||
      "docker compose exec -T onebackend-v3"
  end

  defp shell_quote(s) when is_binary(s) do
    "'" <> String.replace(s, "'", "'\\''") <> "'"
  end
end
