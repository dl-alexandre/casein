defmodule Casein.Release do
  @moduledoc """
  Tasks called from a release binary at boot time.

  In a release there is no `mix`, so anything Mix tasks would normally
  do (like running migrations) goes here and is invoked via
  `bin/casein eval "Casein.Release.migrate()"`.

  This module is required by `audit_remote.md` CC-1 — the Dockerfile's
  migrate overlay calls into it.
  """

  use Boundary, deps: [Casein.Repo], exports: :all

  @app :casein

  @doc """
  Run all pending Ecto migrations against the configured repos.
  Intended to be called once at container start, before the server
  pipeline accepts traffic.
  """
  def migrate do
    load_app()
    migrator = migrator()

    for repo <- repos() do
      {:ok, _, _} =
        migrator.with_repo(repo, fn started_repo ->
          verify_database!(started_repo)
          migrator.run(started_repo, :up, all: true)
        end)
    end
  end

  @doc "Fail closed before migrations when a SQLite database is corrupt."
  def verify_database!(repo \\ Casein.Repo) do
    if function_exported?(repo, :__adapter__, 0) and repo.__adapter__() == Ecto.Adapters.SQLite3 do
      case Ecto.Adapters.SQL.query!(repo, "PRAGMA integrity_check", []).rows do
        [["ok"]] -> :ok
        rows -> raise "SQLite integrity check failed: #{inspect(rows)}"
      end
    else
      :ok
    end
  end

  @doc """
  Roll back `n` steps on the given repo. For incident response.
  """
  def rollback(repo, version) do
    load_app()
    migrator = migrator()
    {:ok, _, _} = migrator.with_repo(repo, &migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp migrator do
    Application.get_env(@app, :ecto_migrator, Ecto.Migrator)
  end

  defp load_app do
    Application.load(@app)
  end
end
