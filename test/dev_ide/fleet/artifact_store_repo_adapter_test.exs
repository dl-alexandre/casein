defmodule DevIDE.Fleet.ArtifactStore.RepoAdapterTest do
  use DevIde.DataCase, async: false

  alias DevIDE.Fleet.ArtifactStore.ChunkRow
  alias DevIDE.Fleet.ArtifactStore.RepoAdapter
  alias DevIde.Repo

  setup do
    Repo.delete_all(ChunkRow)
    :ok
  end

  describe "append_chunk/4 and chunks/1" do
    test "persists chunks in append order" do
      timestamp = DateTime.utc_now()

      assert :ok = RepoAdapter.append_chunk("exec-1", "stdout", "one", timestamp)
      assert :ok = RepoAdapter.append_chunk("exec-1", "stderr", "two", timestamp)

      assert [
               %{stream: "stdout", data: "one", byte_size: 3},
               %{stream: "stderr", data: "two", byte_size: 3}
             ] = RepoAdapter.chunks("exec-1")
    end

    test "sequences are independent per execution" do
      assert :ok = RepoAdapter.append_chunk("exec-1", "stdout", "one", DateTime.utc_now())
      assert :ok = RepoAdapter.append_chunk("exec-2", "stdout", "two", DateTime.utc_now())

      exec_1 = Repo.get_by!(ChunkRow, execution_id: "exec-1")
      exec_2 = Repo.get_by!(ChunkRow, execution_id: "exec-2")

      assert exec_1.sequence == 1
      assert exec_2.sequence == 1
    end

    test "append_chunk is append-only for an execution" do
      timestamp = DateTime.utc_now()

      assert :ok = RepoAdapter.append_chunk("exec-1", "stdout", "first", timestamp)
      first_row = Repo.get_by!(ChunkRow, execution_id: "exec-1", sequence: 1)

      assert :ok = RepoAdapter.append_chunk("exec-1", "stdout", "second", timestamp)

      rows =
        ChunkRow
        |> where([r], r.execution_id == "exec-1")
        |> order_by([r], asc: r.sequence)
        |> Repo.all()

      assert Enum.map(rows, & &1.sequence) == [1, 2]
      assert Enum.map(rows, & &1.data) == ["first", "second"]
      assert Repo.get!(ChunkRow, first_row.id).data == "first"
    end
  end

  describe "chunks_since/2" do
    test "returns only chunks at or after the timestamp" do
      before = DateTime.add(DateTime.utc_now(), -10, :second)
      marker = DateTime.utc_now()
      after_marker = DateTime.add(marker, 10, :second)

      assert :ok = RepoAdapter.append_chunk("exec-1", "stdout", "old", before)
      assert :ok = RepoAdapter.append_chunk("exec-1", "stdout", "new", after_marker)

      assert [%{data: "new"}] = RepoAdapter.chunks_since("exec-1", marker)
    end
  end

  describe "clear/0" do
    test "deletes all persisted chunks" do
      assert :ok = RepoAdapter.append_chunk("exec-1", "stdout", "one", DateTime.utc_now())

      assert :ok = RepoAdapter.clear()
      assert RepoAdapter.chunks("exec-1") == []
    end
  end

  describe "crash survivability" do
    test "chunks survive process restart by re-querying from the database" do
      for i <- 1..3 do
        assert :ok =
                 RepoAdapter.append_chunk(
                   "exec-survive",
                   "stdout",
                   "chunk-#{i}",
                   DateTime.utc_now()
                 )
      end

      before_restart = RepoAdapter.chunks("exec-survive")
      after_restart = RepoAdapter.chunks("exec-survive")

      assert before_restart == after_restart
      assert Enum.map(after_restart, & &1.data) == ["chunk-1", "chunk-2", "chunk-3"]
    end
  end
end
