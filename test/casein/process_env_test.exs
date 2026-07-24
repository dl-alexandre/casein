defmodule Casein.ProcessEnvTest do
  # async: true is the whole point — these tests set overrides in their own
  # processes and must not see each other's.
  use ExUnit.Case, async: true

  alias Casein.ProcessEnv

  # A per-test unique key so nothing collides with real config or a sibling
  # async test mutating Application env.
  defp unique_key, do: :"pe_test_#{System.unique_integer([:positive])}"

  describe "get/3 fallback" do
    test "returns the default when no override and no Application env" do
      assert ProcessEnv.get(:casein, unique_key(), :fallback) == :fallback
    end

    test "reads Application env when no process override is set" do
      key = unique_key()
      Application.put_env(:casein, key, :from_app)
      on_exit(fn -> Application.delete_env(:casein, key) end)

      assert ProcessEnv.get(:casein, key, :fallback) == :from_app
    end
  end

  describe "process-scoped override" do
    test "shadows Application env for the current process" do
      key = unique_key()
      Application.put_env(:casein, key, :from_app)
      on_exit(fn -> Application.delete_env(:casein, key) end)

      ProcessEnv.put(key, :from_process)
      assert ProcessEnv.get(:casein, key, :fallback) == :from_process
    end

    test "delete/1 restores fallback resolution" do
      key = unique_key()
      ProcessEnv.put(key, :x)
      assert ProcessEnv.get(:casein, key, :fallback) == :x

      ProcessEnv.delete(key)
      assert ProcessEnv.get(:casein, key, :fallback) == :fallback
    end
  end

  describe "$callers propagation and isolation" do
    test "a spawned Task inherits the override via $callers" do
      key = unique_key()
      ProcessEnv.put(key, :mine)

      task = Task.async(fn -> ProcessEnv.get(:casein, key, :fallback) end)
      assert Task.await(task) == :mine
    end

    test "an unrelated process (no caller chain) does not see the override" do
      key = unique_key()
      ProcessEnv.put(key, :mine)

      parent = self()
      # bare spawn/1 does not carry a $callers chain back to us
      spawn(fn -> send(parent, {:seen, ProcessEnv.get(:casein, key, :fallback)}) end)

      assert_receive {:seen, :fallback}
    end

    test "concurrent processes keep independent overrides" do
      key = unique_key()

      results =
        [:a, :b, :c]
        |> Enum.map(fn v ->
          Task.async(fn ->
            ProcessEnv.put(key, v)
            ProcessEnv.get(:casein, key, :fallback)
          end)
        end)
        |> Task.await_many()

      assert results == [:a, :b, :c]
    end
  end
end
