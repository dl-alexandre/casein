defmodule TmuxCtl.SharedWriteGuard do
  @moduledoc false

  @doc """
  Runs `fun` unless a configured shared-write guard returns `:noop`.

  DevIDE wires `config :tmux_ctl, :shared_write_guard` to
  `{DevIDE.Deployment.Drain, :guard_shared_write}` at boot. When unset, `fun`
  always runs (generic tmux_ctl consumers).
  """
  @spec guard((-> term())) :: term() | :noop
  def guard(fun) when is_function(fun, 0) do
    case Application.get_env(:tmux_ctl, :shared_write_guard) do
      {mod, fun_name} when is_atom(mod) and is_atom(fun_name) ->
        apply(mod, fun_name, [fun])

      guard when is_function(guard, 1) ->
        guard.(fun)

      _ ->
        fun.()
    end
  end
end
