defmodule DevIDE.Commands.SshAdapter do
  @moduledoc """
  Remote command runner. Wraps an argv invocation in `ssh <host> -- bash -lc
  'cd <path> && exec <argv...>'` and streams the remote output back via
  erlexec. Same subscriber protocol as `DevIDE.Commands.LocalAdapter`:

      {:cmd_data, ref, :stdout | :stderr, binary}
      {:cmd_exit, ref, exit_code :: integer()}
  """

  @behaviour DevIDE.Commands

  @impl true
  def spawn({:remote, host, root}, argv, subscriber)
      when is_binary(host) and is_binary(root) and is_list(argv) and is_pid(subscriber) do
    prefix = remote_exec_prefix()
    quoted_argv = argv |> Enum.map(&shell_quote/1) |> Enum.join(" ")

    inner =
      "cd " <>
        shell_quote(root) <>
        " && exec " <> if(prefix == "", do: quoted_argv, else: prefix <> " " <> quoted_argv)

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

    do_spawn(ssh_argv, subscriber)
  end

  def spawn(_, _, _), do: {:error, :bad_args}

  @impl true
  def kill(%{ospid: ospid}) do
    _ = :exec.kill(ospid, 15)
    :ok
  end

  def kill(_), do: :ok

  defp do_spawn([bin | args], subscriber) do
    ref = make_ref()
    argv = [to_charlist(bin) | Enum.map(args, &to_charlist/1)]

    owner = self()

    proxy =
      spawn_link(fn ->
        opts = [
          :monitor,
          {:stdout, fn _, _, data -> send(subscriber, {:cmd_data, ref, :stdout, data}) end},
          {:stderr, fn _, _, data -> send(subscriber, {:cmd_data, ref, :stderr, data}) end}
        ]

        case :exec.run(argv, opts) do
          {:ok, exec_pid, ospid} ->
            send(owner, {:command_started, ref, {:ok, exec_pid, ospid}})
            wait_loop(ospid, subscriber, ref)

          {:error, reason} ->
            send(owner, {:command_started, ref, {:error, reason}})
        end
      end)

    receive do
      {:command_started, ^ref, {:ok, exec_pid, ospid}} ->
        {:ok, ref, %{exec_pid: exec_pid, ospid: ospid, proxy_pid: proxy}}

      {:command_started, ^ref, {:error, reason}} ->
        {:error, reason}
    after
      30_000 -> {:error, :spawn_timeout}
    end
  end

  defp wait_loop(ospid, subscriber, ref) do
    receive do
      {:DOWN, _, :process, _, {:exit_status, status}} ->
        code = exit_code_of(status)
        send(subscriber, {:cmd_exit, ref, code})

      {:DOWN, _, :process, _, :normal} ->
        send(subscriber, {:cmd_exit, ref, 0})

      {:DOWN, _, :process, _, reason} ->
        send(subscriber, {:cmd_exit, ref, {:error, reason}})
    after
      :timer.hours(24) -> :ok
    end

    _ = ospid
  end

  defp exit_code_of(status) when is_integer(status) do
    # erlexec encodes wait(2) status; high byte is exit code on normal exit.
    cond do
      Bitwise.band(status, 0xFF) == 0 -> Bitwise.bsr(status, 8)
      true -> 128 + Bitwise.band(status, 0x7F)
    end
  end

  defp exit_code_of(_), do: 1

  defp remote_exec_prefix do
    Application.get_env(:dev_ide, :remote_exec_prefix) ||
      System.get_env("DEV_IDE_REMOTE_EXEC_PREFIX") ||
      "docker compose exec -T onebackend-v3"
  end

  defp shell_quote(s) when is_binary(s) do
    "'" <> String.replace(s, "'", "'\\''") <> "'"
  end
end
