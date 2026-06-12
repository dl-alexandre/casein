defmodule TmuxCtl.Runner.Default do
  @moduledoc false
  @behaviour TmuxCtl.Runner

  @impl TmuxCtl.Runner
  def run(argv, opts \\ []) when is_list(argv) do
    cmd_opts =
      opts
      |> Keyword.take([:cd])
      |> Keyword.put_new(:stderr_to_stdout, true)

    System.cmd("tmux", argv, cmd_opts)
  end
end
