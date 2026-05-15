defmodule DevIDE.Workspaces.SshRunner do
  @moduledoc """
  Seam over the `ssh` invocation so `FileAccess` can be tested without a real
  remote host. The default implementation shells out via `System.cmd/3` and
  `Port`; tests inject a fake via `:dev_ide, :ssh_runner`.
  """

  @callback run(host :: String.t(), argv :: [String.t()]) ::
              {:ok, binary()} | {:error, term()}
  @callback run_with_stdin(host :: String.t(), argv :: [String.t()], stdin :: binary()) ::
              :ok | {:error, term()}

  @doc "The configured runner module."
  def impl, do: Application.get_env(:dev_ide, :ssh_runner, __MODULE__.System)

  def run(host, argv), do: impl().run(host, argv)
  def run_with_stdin(host, argv, stdin), do: impl().run_with_stdin(host, argv, stdin)

  defmodule System do
    @moduledoc "Default `SshRunner` — real ssh via System.cmd/Port."
    @behaviour DevIDE.Workspaces.SshRunner

    @impl true
    def run(host, argv) do
      args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, "--" | argv]

      case Elixir.System.cmd("ssh", args, stderr_to_stdout: false) do
        {out, 0} -> {:ok, out}
        {err, code} -> {:error, {:ssh_failed, code, err}}
      end
    catch
      kind, reason -> {:error, {kind, reason}}
    end

    @impl true
    def run_with_stdin(host, argv, stdin) do
      args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, "--" | argv]
      ssh_bin = Elixir.System.find_executable("ssh") || "/usr/bin/ssh"

      port =
        Port.open(
          {:spawn_executable, ssh_bin},
          [:binary, :exit_status, :use_stdio, args: args]
        )

      true = Port.command(port, stdin)
      send(port, {self(), :close})

      receive do
        {^port, :closed} -> :ok
      after
        0 -> :ok
      end

      receive do
        {^port, {:exit_status, 0}} -> :ok
        {^port, {:exit_status, code}} -> {:error, {:ssh_failed, code}}
      after
        30_000 -> {:error, :timeout}
      end
    end
  end
end
