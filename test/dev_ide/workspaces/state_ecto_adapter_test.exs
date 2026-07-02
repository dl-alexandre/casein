defmodule DevIDE.Workspaces.State.EctoAdapterTest do
  use DevIde.DataCase, async: false

  alias DevIDE.Workspaces.State.EctoAdapter
  alias DevIDE.Workspaces.State.WorkspaceRecord

  setup do
    Repo.delete_all(EctoAdapter.Row)
    :ok
  end

  defp record(attrs) do
    struct!(
      %WorkspaceRecord{
        external_id: "ws-1",
        name: "alpha",
        status: "running",
        manager_payload: %{}
      },
      attrs
    )
  end

  describe "upsert/1" do
    test "inserts a new record" do
      assert {:ok, persisted} = EctoAdapter.upsert(record(%{}))
      assert persisted.external_id == "ws-1"
      assert persisted.name == "alpha"
      assert persisted.id
      assert persisted.inserted_at
    end

    test "updates an existing record in place, keeping id and inserted_at" do
      {:ok, first} = EctoAdapter.upsert(record(%{}))
      {:ok, second} = EctoAdapter.upsert(record(%{name: "beta", status: "stopped"}))

      assert second.id == first.id
      assert second.inserted_at == first.inserted_at
      assert second.name == "beta"
      assert second.status == "stopped"
      assert Repo.aggregate(EctoAdapter.Row, :count) == 1
    end

    test "overwrites fields the new record leaves nil" do
      {:ok, _} = EctoAdapter.upsert(record(%{host_path: "/data/alpha"}))
      {:ok, updated} = EctoAdapter.upsert(record(%{host_path: nil}))

      assert updated.host_path == nil
    end

    test "racing upserts of the same external_id never error or duplicate" do
      results =
        1..5
        |> Task.async_stream(
          fn i -> EctoAdapter.upsert(record(%{status: "probe-#{i}"})) end,
          max_concurrency: 5
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert Repo.aggregate(EctoAdapter.Row, :count) == 1
    end
  end

  describe "get/1 and list/0 and delete/1" do
    test "round-trips through get and list" do
      {:ok, _} = EctoAdapter.upsert(record(%{}))
      {:ok, _} = EctoAdapter.upsert(record(%{external_id: "ws-2", name: "zeta"}))

      assert {:ok, %WorkspaceRecord{name: "alpha"}} = EctoAdapter.get("ws-1")
      assert :error = EctoAdapter.get("missing")
      assert ["alpha", "zeta"] = EctoAdapter.list() |> Enum.map(& &1.name)
    end

    test "delete removes the record and is idempotent" do
      {:ok, _} = EctoAdapter.upsert(record(%{}))

      assert :ok = EctoAdapter.delete("ws-1")
      assert :error = EctoAdapter.get("ws-1")
      assert :ok = EctoAdapter.delete("ws-1")
    end
  end

  describe "get_many/1 and upsert_all/1" do
    test "upsert_all inserts many in one call and returns records" do
      assert {:ok, records} =
               EctoAdapter.upsert_all([
                 record(%{external_id: "ws-1", name: "alpha"}),
                 record(%{external_id: "ws-2", name: "zeta"})
               ])

      assert records |> Enum.map(& &1.external_id) |> Enum.sort() == ["ws-1", "ws-2"]
      assert Enum.all?(records, & &1.id)
      assert Repo.aggregate(EctoAdapter.Row, :count) == 2
    end

    test "upsert_all updates existing rows in place, keeping id and inserted_at" do
      {:ok, first} = EctoAdapter.upsert(record(%{external_id: "ws-1", name: "alpha"}))

      {:ok, [updated]} =
        EctoAdapter.upsert_all([record(%{external_id: "ws-1", name: "beta", status: "stopped"})])

      assert updated.id == first.id
      assert updated.inserted_at == first.inserted_at
      assert updated.name == "beta"
      assert updated.status == "stopped"
      assert Repo.aggregate(EctoAdapter.Row, :count) == 1
    end

    test "upsert_all([]) is a no-op" do
      assert {:ok, []} = EctoAdapter.upsert_all([])
      assert Repo.aggregate(EctoAdapter.Row, :count) == 0
    end

    test "get_many returns a map keyed by external_id for the ids that exist" do
      {:ok, _} = EctoAdapter.upsert(record(%{external_id: "ws-1", name: "alpha"}))
      {:ok, _} = EctoAdapter.upsert(record(%{external_id: "ws-2", name: "zeta"}))

      got = EctoAdapter.get_many(["ws-1", "ws-2", "missing"])

      assert got |> Map.keys() |> Enum.sort() == ["ws-1", "ws-2"]
      assert got["ws-1"].name == "alpha"
      assert %WorkspaceRecord{} = got["ws-2"]
    end
  end
end
