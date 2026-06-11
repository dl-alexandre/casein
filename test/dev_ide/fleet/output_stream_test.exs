defmodule DevIDE.Fleet.OutputStreamTest do
  use ExUnit.Case, async: true

  alias DevIDE.Fleet.OutputStream

  setup do
    OutputStream.clear()
    :ok
  end

  test "append returns chunks in chronological order" do
    execution_id = Ecto.UUID.generate()

    for i <- 1..3 do
      :ok = OutputStream.append_chunk(execution_id, "stdout", "line #{i}\n")
    end

    assert [%{chunk: "line 1\n"}, %{chunk: "line 2\n"}, %{chunk: "line 3\n"}] =
             OutputStream.chunks(execution_id)
  end

  test "filters chunks by stream" do
    execution_id = Ecto.UUID.generate()

    :ok = OutputStream.append_chunk(execution_id, "stdout", "out\n")
    :ok = OutputStream.append_chunk(execution_id, "stderr", "err\n")

    assert [%{stream: "stderr", chunk: "err\n"}] =
             OutputStream.chunks(execution_id, "stderr")
  end

  test "chunks_since filters by timestamp" do
    execution_id = Ecto.UUID.generate()
    early = DateTime.utc_now()
    Process.sleep(5)
    later = DateTime.utc_now()

    :ok = OutputStream.append_chunk(execution_id, "stdout", "early\n", early)
    :ok = OutputStream.append_chunk(execution_id, "stdout", "later\n", later)

    assert [%{chunk: "later\n"}] = OutputStream.chunks_since(execution_id, later)
  end

  test "last_chunks returns the newest N in chronological order" do
    execution_id = Ecto.UUID.generate()

    for i <- 1..5 do
      :ok = OutputStream.append_chunk(execution_id, "stdout", "line #{i}\n")
    end

    assert [%{chunk: "line 3\n"}, %{chunk: "line 4\n"}, %{chunk: "line 5\n"}] =
             OutputStream.last_chunks(execution_id, 3)
  end

  test "register_execution clears prior chunks" do
    execution_id = Ecto.UUID.generate()

    :ok = OutputStream.append_chunk(execution_id, "stdout", "old\n")
    :ok = OutputStream.register_execution(execution_id)

    assert OutputStream.chunks(execution_id) == []
  end

  test "prune keeps the newest 100 chunks" do
    execution_id = Ecto.UUID.generate()

    for i <- 1..150 do
      :ok = OutputStream.append_chunk(execution_id, "stdout", "line #{i}")
    end

    :ok = OutputStream.prune_execution(execution_id)

    chunks = OutputStream.chunks(execution_id)
    assert length(chunks) == 100
    assert Enum.at(chunks, 0).chunk == "line 51"
    assert Enum.at(chunks, -1).chunk == "line 150"
  end

  test "caps active execution at configured max chunks" do
    execution_id = Ecto.UUID.generate()
    previous = Application.get_env(:dev_ide, :output_stream_max_chunks)
    Application.put_env(:dev_ide, :output_stream_max_chunks, 50)

    on_exit(fn ->
      if previous do
        Application.put_env(:dev_ide, :output_stream_max_chunks, previous)
      else
        Application.delete_env(:dev_ide, :output_stream_max_chunks)
      end
    end)

    for i <- 1..60 do
      :ok = OutputStream.append_chunk(execution_id, "stdout", "line #{i}")
    end

    chunks = OutputStream.chunks(execution_id)
    assert length(chunks) == 50
    assert Enum.at(chunks, 0).chunk == "line 11"
    assert Enum.at(chunks, -1).chunk == "line 60"
  end

  test "preserves seq on append" do
    execution_id = Ecto.UUID.generate()

    :ok =
      OutputStream.append_chunk(execution_id, "stdout", "ok\n", DateTime.utc_now(), seq: 42)

    assert [%{seq: 42}] = OutputStream.chunks(execution_id)
  end

  test "concurrent appends stay unique and ordered" do
    execution_id = Ecto.UUID.generate()

    1..100
    |> Task.async_stream(
      fn i -> OutputStream.append_chunk(execution_id, "stdout", "line #{i}\n") end,
      timeout: :infinity,
      max_concurrency: 25
    )
    |> Enum.each(fn {:ok, :ok} -> :ok end)

    chunks = OutputStream.chunks(execution_id)
    assert length(chunks) == 100
    assert Enum.map(chunks, & &1.chunk) |> Enum.uniq() |> length() == 100
  end
end
