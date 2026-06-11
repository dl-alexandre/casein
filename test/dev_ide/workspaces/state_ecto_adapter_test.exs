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
end
