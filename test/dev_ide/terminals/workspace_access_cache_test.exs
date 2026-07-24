defmodule Casein.Terminals.WorkspaceAccessCacheTest do
  use Casein.TestCase, async: false

  alias Casein.Terminals.WorkspaceAccessCache, as: Cache

  @table :dev_ide_workspace_access_cache
  @ttl_ms 60_000

  setup do
    Cache.ensure_table!()
    Cache.reset!()
    on_exit(fn -> Cache.reset!() end)
    :ok
  end

  # Atomic call counter backed by :counters (no process => nothing to supervise).
  defp new_counter, do: :counters.new(1, [])
  defp bump(counter), do: :counters.add(counter, 1, 1)
  defp count(counter), do: :counters.get(counter, 1)

  describe "ensure_table!/0" do
    test "creates the named ETS table" do
      assert :ets.whereis(@table) != :undefined
    end

    test "is idempotent across repeated calls" do
      assert :ok = Cache.ensure_table!()
      first = :ets.whereis(@table)
      assert :ok = Cache.ensure_table!()
      second = :ets.whereis(@table)
      # Same table identifier, not recreated.
      assert first == second
    end
  end

  describe "fetch/3 cold (no cached entry)" do
    test "calls fetch_fun, stores the value, and returns it" do
      test_pid = self()

      fetch_fun = fn ->
        send(test_pid, :called)
        {:ok, :workspace_value}
      end

      assert {:ok, :workspace_value} = Cache.fetch("ws-1", "user@example.com", fetch_fun)
      assert_received :called

      # Entry stored under {workspace_id, email} with a future expiry.
      key = {"ws-1", "user@example.com"}
      now = System.system_time(:millisecond)
      assert [{^key, :workspace_value, expires_at}] = :ets.lookup(@table, key)
      assert is_integer(expires_at)
      assert expires_at > now
      # Expiry is approximately now + @ttl_ms.
      assert expires_at <= now + @ttl_ms
      assert expires_at > now + @ttl_ms - 5_000
    end

    test "normalizes a nil email to \"\" in the cache key" do
      fetch_fun = fn -> {:ok, :nil_email_value} end

      assert {:ok, :nil_email_value} = Cache.fetch("ws-nil", nil, fetch_fun)

      key = {"ws-nil", ""}
      assert [{^key, :nil_email_value, _expires}] = :ets.lookup(@table, key)
    end

    test "does not cache an error result and deletes any stale key" do
      test_pid = self()

      fetch_fun = fn ->
        send(test_pid, :err_called)
        {:error, :denied}
      end

      assert {:error, :denied} = Cache.fetch("ws-err", "user@example.com", fetch_fun)
      assert_received :err_called

      key = {"ws-err", "user@example.com"}
      assert :ets.lookup(@table, key) == []
    end
  end

  describe "fetch/3 warm (cached, unexpired entry)" do
    test "returns the cached value without invoking fetch_fun again" do
      counter = new_counter()

      fetch_fun = fn ->
        bump(counter)
        {:ok, :memoized}
      end

      assert {:ok, :memoized} = Cache.fetch("ws-warm", "user@example.com", fetch_fun)
      assert {:ok, :memoized} = Cache.fetch("ws-warm", "user@example.com", fetch_fun)
      assert {:ok, :memoized} = Cache.fetch("ws-warm", "user@example.com", fetch_fun)

      # fetch_fun invoked exactly once across three fetches.
      assert count(counter) == 1
    end
  end

  describe "fetch/3 key independence" do
    test "different workspace_ids cache independently" do
      assert {:ok, :a} = Cache.fetch("ws-a", "user@example.com", fn -> {:ok, :a} end)
      assert {:ok, :b} = Cache.fetch("ws-b", "user@example.com", fn -> {:ok, :b} end)

      assert {:ok, :a} = Cache.fetch("ws-a", "user@example.com", fn -> {:ok, :should_not_run} end)
      assert {:ok, :b} = Cache.fetch("ws-b", "user@example.com", fn -> {:ok, :should_not_run} end)
    end

    test "same workspace_id with different emails cache independently" do
      assert {:ok, :alice} =
               Cache.fetch("ws-shared", "alice@example.com", fn -> {:ok, :alice} end)

      assert {:ok, :bob} = Cache.fetch("ws-shared", "bob@example.com", fn -> {:ok, :bob} end)

      assert {:ok, :alice} =
               Cache.fetch("ws-shared", "alice@example.com", fn -> {:ok, :nope} end)

      assert {:ok, :bob} = Cache.fetch("ws-shared", "bob@example.com", fn -> {:ok, :nope} end)
    end
  end

  describe "fetch/3 expiry (TTL elapsed)" do
    test "re-invokes fetch_fun when the stored entry has expired" do
      counter = new_counter()

      fetch_fun = fn ->
        bump(counter)
        {:ok, :fresh}
      end

      # First fetch populates the cache.
      assert {:ok, :fresh} = Cache.fetch("ws-ttl", "user@example.com", fetch_fun)
      assert count(counter) == 1

      # Deterministically expire the entry by rewriting expires_at into the past.
      key = {"ws-ttl", "user@example.com"}
      now = System.system_time(:millisecond)
      :ets.insert(@table, {key, :fresh, now - 1})

      # Lookup miss on the expired guard => fetch_fun runs again and refreshes.
      assert {:ok, :fresh} = Cache.fetch("ws-ttl", "user@example.com", fetch_fun)
      assert count(counter) == 2

      # The refreshed entry now has a future expiry again.
      assert [{^key, :fresh, expires_at}] = :ets.lookup(@table, key)
      assert expires_at > System.system_time(:millisecond)
    end

    test "treats an entry whose expires_at equals now as expired (strict >)" do
      counter = new_counter()

      fetch_fun = fn ->
        bump(counter)
        {:ok, :boundary}
      end

      assert {:ok, :boundary} = Cache.fetch("ws-boundary", "user@example.com", fetch_fun)
      assert count(counter) == 1

      key = {"ws-boundary", "user@example.com"}
      now = System.system_time(:millisecond)
      # expires_at == now must NOT be served (guard is expires_at > now).
      :ets.insert(@table, {key, :boundary, now})

      assert {:ok, :boundary} = Cache.fetch("ws-boundary", "user@example.com", fetch_fun)
      assert count(counter) == 2
    end
  end

  describe "reset!/0" do
    test "clears cached entries so fetch_fun runs again" do
      counter = new_counter()

      fetch_fun = fn ->
        bump(counter)
        {:ok, :reset_value}
      end

      assert {:ok, :reset_value} = Cache.fetch("ws-reset", "user@example.com", fetch_fun)
      assert count(counter) == 1

      Cache.reset!()
      assert :ets.lookup(@table, {"ws-reset", "user@example.com"}) == []

      # Cache is cold again => fetch_fun re-invoked.
      assert {:ok, :reset_value} = Cache.fetch("ws-reset", "user@example.com", fetch_fun)
      assert count(counter) == 2
    end

    test "is safe to call when the table is empty" do
      assert Cache.reset!()
    end
  end
end
