defmodule GitCtl.CacheTest do
  use DevIDE.TestCase, async: false

  alias GitCtl.Cache

  setup do
    table = :"git_ctl_cache_test_#{System.unique_integer([:positive])}"
    :ets.new(table, [:named_table, :public, :set])

    prev_table = Application.get_env(:git_ctl, :cache_table)
    prev_ttl = Application.get_env(:git_ctl, :cache_ttl_ms)

    Application.put_env(:git_ctl, :cache_table, table)

    on_exit(fn ->
      if prev_table,
        do: Application.put_env(:git_ctl, :cache_table, prev_table),
        else: Application.delete_env(:git_ctl, :cache_table)

      if prev_ttl,
        do: Application.put_env(:git_ctl, :cache_ttl_ms, prev_ttl),
        else: Application.delete_env(:git_ctl, :cache_ttl_ms)

      if :ets.whereis(table) != :undefined, do: :ets.delete(table)
    end)

    %{table: table}
  end

  test "table/0 and ttl_ms/0 read application env" do
    Application.put_env(:git_ctl, :cache_ttl_ms, 42_000)
    assert Cache.table() == Application.get_env(:git_ctl, :cache_table)
    assert Cache.ttl_ms() == 42_000
  end

  test "lookup returns :miss for unknown cwd" do
    assert Cache.lookup("/no/such/cwd", 10_000) == :miss
  end

  test "lookup returns :miss for invalid ttl" do
    assert Cache.lookup("/tmp", 0) == :miss
    assert Cache.lookup("/tmp", -1) == :miss
    assert Cache.lookup(123, 10) == :miss
  end

  test "store and lookup round-trip within ttl" do
    cwd = "/tmp/git-ctl-cache-#{System.unique_integer([:positive])}"
    result = {:ok, %{branch: "main"}}

    assert :ok = Cache.store(cwd, result)
    assert {:ok, ^result} = Cache.lookup(cwd, 60_000)
  end

  test "lookup expires stale entries by monotonic clock", %{table: table} do
    cwd = "/tmp/git-ctl-stale-#{System.unique_integer([:positive])}"
    result = {:ok, %{branch: "stale"}}
    stale_at = System.monotonic_time(:millisecond) - 10_000

    :ets.insert(table, {cwd, result, stale_at})
    assert Cache.lookup(cwd, 1) == :miss
  end

  test "lookup rescues missing ETS table", %{table: table} do
    Application.put_env(:git_ctl, :cache_table, :devide_missing_git_ctl_cache_table)
    assert Cache.lookup("/tmp", 10_000) == :miss
    assert :ok = Cache.store("/tmp", :error)
    Application.put_env(:git_ctl, :cache_table, table)
  end
end
