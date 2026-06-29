defmodule DevIDE.Test.FakeReleaseMigrator do
  @moduledoc false

  def with_repo(repo, fun) do
    {:ok, repo, fun.(repo)}
  end

  def run(repo, direction, opts) do
    send(self(), {:release_migrator, repo, direction, opts})
    {:ran, repo, direction, opts}
  end
end
