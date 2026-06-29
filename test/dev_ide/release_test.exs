defmodule DevIde.ReleaseTest do
  use DevIde.DataCase, async: false

  test "migrate/0 loads the app and completes without error" do
    assert [{:ok, _, _}] = DevIde.Release.migrate()
    assert Application.loaded_applications() |> Enum.any?(fn {app, _, _} -> app == :dev_ide end)
  end

  test "rollback/2 is a no-op when already at the target version" do
    version =
      case Ecto.Migrator.migrated_versions(Repo) do
        [] -> 0
        versions -> Enum.max(versions)
      end

    assert {:ok, _, _} = DevIde.Release.rollback(Repo, version)
    assert version in Ecto.Migrator.migrated_versions(Repo)
  end
end
