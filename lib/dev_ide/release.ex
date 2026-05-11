defmodule DevIde.Release do
  @moduledoc """
  Tasks called from a release binary at boot time.

  In a release there is no `mix`, so anything Mix tasks would normally
  do (like running migrations) goes here and is invoked via
  `bin/dev_ide eval "DevIde.Release.migrate()"`.

  This module is required by `audit_remote.md` CC-1 — the Dockerfile's
  migrate overlay calls into it.
  """

  @app :dev_ide

  @doc """
  Run all pending Ecto migrations against the configured repos.
  Intended to be called once at container start, before the server
  pipeline accepts traffic.
  """
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  Roll back `n` steps on the given repo. For incident response.
  """
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
