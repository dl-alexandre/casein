defmodule DevIDE.Repo.Adapter do
  @moduledoc false

  @sqlite Ecto.Adapters.SQLite3
  @postgres Ecto.Adapters.Postgres
  @configured Application.compile_env(:dev_ide, :repo_adapter, @postgres)
  @sqlite? @configured == @sqlite
  @postgres? @configured == @postgres

  @spec configured() :: module()
  def configured, do: @configured

  @spec sqlite?() :: boolean()
  def sqlite?, do: @sqlite?

  @spec sqlite?(module()) :: boolean()
  def sqlite?(repo) when is_atom(repo) do
    function_exported?(repo, :__adapter__, 0) and repo.__adapter__() == @sqlite
  end

  @spec postgres?() :: boolean()
  def postgres?, do: @postgres?

  @spec list_storage_type(module(), atom()) :: atom() | {:array, atom()}
  def list_storage_type(repo, inner_type) when is_atom(inner_type) do
    if sqlite?(repo), do: :text, else: {:array, inner_type}
  end

  @spec list_default(module()) :: String.t() | list()
  def list_default(repo), do: if(sqlite?(repo), do: "[]", else: [])
end
