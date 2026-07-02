defmodule DevIDE.SearchTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Search
  alias DevIDE.Search.Result

  setup do
    root = Path.join(System.tmp_dir!(), "search-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev_adapter = Application.get_env(:dev_ide, :search_adapter)
    Application.put_env(:dev_ide, :search_adapter, DevIDE.Search.MemoryAdapter)
    Application.delete_env(:dev_ide, :search_memory_results)
    Application.delete_env(:dev_ide, :search_memory_response)
    Application.delete_env(:dev_ide, :search_memory_available)

    on_exit(fn ->
      File.rm_rf!(root)
      restore(:search_adapter, prev_adapter)
      Application.delete_env(:dev_ide, :search_memory_results)
      Application.delete_env(:dev_ide, :search_memory_response)
      Application.delete_env(:dev_ide, :search_memory_available)
    end)

    {:ok, root: root}
  end

  defp restore(k, nil), do: Application.delete_env(:dev_ide, k)
  defp restore(k, v), do: Application.put_env(:dev_ide, k, v)

  test "rejects too-short queries", %{root: root} do
    assert {:error, :too_short} = Search.search(root, "")
    assert {:error, :too_short} = Search.search(root, "a")
  end

  test "rejects too-long queries", %{root: root} do
    long = String.duplicate("x", Search.max_query() + 1)
    assert {:error, :too_long} = Search.search(root, long)
  end

  test "rejects missing root" do
    assert {:error, :no_root} = Search.search("/no/such/dir/12345", "needle")
  end

  test "returns adapter results", %{root: root} do
    Application.put_env(:dev_ide, :search_memory_results, %{
      "needle" => [
        %{path: "lib/a.ex", line: 4, column: 2, preview: "haystack needle"}
      ]
    })

    assert {:ok, [%Result{path: "lib/a.ex", line: 4, column: 2}]} = Search.search(root, "needle")
  end

  test "missing rg surfaced as :rg_missing", %{root: root} do
    Application.put_env(:dev_ide, :search_memory_response, {:error, :rg_missing})
    assert {:error, :rg_missing} = Search.search(root, "needle")
  end

  test "timeout surfaced as :timeout", %{root: root} do
    Application.put_env(:dev_ide, :search_memory_response, {:error, :timeout})
    assert {:error, :timeout} = Search.search(root, "needle")
  end

  test "available?/0 reports adapter availability" do
    Application.put_env(:dev_ide, :search_memory_available, false)
    refute Search.available?()
    Application.put_env(:dev_ide, :search_memory_available, true)
    assert Search.available?()
  end
end
