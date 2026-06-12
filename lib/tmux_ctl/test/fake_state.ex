defmodule TmuxCtl.Test.FakeState do
  @moduledoc false

  @app :tmux_ctl

  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil), do: Application.get_env(@app, key, default)

  @spec put(atom(), term()) :: :ok
  def put(key, value), do: Application.put_env(@app, key, value)

  @spec delete(atom()) :: :ok
  def delete(key), do: Application.delete_env(@app, key)

  @spec update(atom(), term(), (term() -> term())) :: :ok
  def update(key, default, fun) when is_function(fun, 1) do
    put(key, fun.(get(key, default)))
  end

  @spec restore(atom(), term() | nil) :: :ok
  def restore(key, nil), do: delete(key)
  def restore(key, value), do: put(key, value)
end
