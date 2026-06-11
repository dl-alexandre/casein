defmodule DevIDE.Commands.HistoryMemoryAdapterTest do
  use ExUnit.Case, async: false

  alias DevIDE.Commands.History
  alias DevIDE.Commands.History.MemoryAdapter
  alias DevIDE.Commands.History.Record

  setup do
    MemoryAdapter.clear()
    on_exit(fn -> MemoryAdapter.clear() end)
    :ok
  end

  test "create caps stored records at 500" do
    for i <- 1..505 do
      {:ok, _} =
        MemoryAdapter.create(%Record{
          id: "run-#{i}",
          workspace_id: "ws-1",
          command_id: "format",
          argv: ["mix", "format"],
          status: :completed,
          started_at: DateTime.add(DateTime.utc_now(), i, :second)
        })
    end

    assert length(MemoryAdapter.list(limit: 600)) == 500
    refute match?({:ok, _}, MemoryAdapter.get("run-1"))
    assert match?({:ok, _}, MemoryAdapter.get("run-505"))
  end
end
