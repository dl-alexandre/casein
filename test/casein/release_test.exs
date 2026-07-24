defmodule Casein.ReleaseTest do
  use Casein.TestCase, async: false

  alias Casein.Test.FakeReleaseMigrator

  @fake_repo Casein.Test.FakeReleaseRepo

  setup do
    prev_repos = Application.get_env(:casein, :ecto_repos)
    prev_migrator = Application.get_env(:casein, :ecto_migrator)

    Application.put_env(:casein, :ecto_repos, [@fake_repo])
    Application.put_env(:casein, :ecto_migrator, FakeReleaseMigrator)

    on_exit(fn ->
      restore(:ecto_repos, prev_repos)
      restore(:ecto_migrator, prev_migrator)
    end)
  end

  test "migrate/0 loads the app and completes without error" do
    assert [{:ok, @fake_repo, {:ran, @fake_repo, :up, [all: true]}}] = Casein.Release.migrate()
    assert Application.loaded_applications() |> Enum.any?(fn {app, _, _} -> app == :casein end)
    assert_received {:release_migrator, @fake_repo, :up, [all: true]}
  end

  test "rollback/2 delegates a down migration to the configured migrator" do
    assert {:ok, @fake_repo, {:ran, @fake_repo, :down, [to: 123]}} =
             Casein.Release.rollback(@fake_repo, 123)

    assert_received {:release_migrator, @fake_repo, :down, [to: 123]}
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)
end
