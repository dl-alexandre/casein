defmodule DevIDE.Commands.PortExec do
  @moduledoc """
  Shared erlexec plumbing for `DevIDE.Commands` adapters that spawn an OS
  process and stream its output to a subscriber:

      {:cmd_data, ref, :stdout | :stderr, binary}
      {:cmd_exit, ref, exit_code :: integer()}

  Adapters like `SshAdapter` differ only in how they build the argv — the
  spawn/monitor/exit-decode mechanics are identical and live in `ExecCtl.Port`.
  """

  @spec run([String.t(), ...], keyword(), pid()) ::
          {:ok, reference(), map()} | {:error, term()}
  defdelegate run(argv, extra_opts, subscriber), to: ExecCtl.Port

  @spec kill(map() | term()) :: :ok
  defdelegate kill(handle), to: ExecCtl.Port
end
