defmodule TmuxCtl.Runner do
  @moduledoc """
  Executes a tmux subprocess from a list of tmux *subcommand* arguments.

  The runner is responsible for prefixing `tmux`, optional host/container
  wrapping, and `System.cmd/3` options such as `:cd`.
  """

  @type argv :: [String.t()]
  @type exit_code :: non_neg_integer()

  @callback run(argv(), keyword()) :: {String.t(), exit_code()}

  @doc false
  @spec configured() :: module()
  def configured do
    Application.get_env(:tmux_ctl, :runner, TmuxCtl.Runner.Default)
  end

  @doc false
  @spec run(argv(), keyword()) :: {String.t(), exit_code()}
  def run(argv, opts \\ []) when is_list(argv) do
    configured().run(argv, opts)
  end

  @doc false
  @spec argv(argv(), keyword()) :: argv()
  def argv(argv, opts \\ []) when is_list(argv) do
    case configured() do
      runner when is_atom(runner) ->
        if function_exported?(runner, :argv, 2) do
          runner.argv(argv, opts)
        else
          ["tmux" | argv]
        end

      _ ->
        ["tmux" | argv]
    end
  end
end
