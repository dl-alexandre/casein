defmodule Mix.Tasks.Casein.Test.ReapTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Casein.Test.Reap

  test "selects only per-pid test databases whose process is dead" do
    databases = [
      "casein_test_101",
      "casein_test0_202",
      "casein_test_pe2e_303",
      "casein_test",
      "casein_test_not_a_pid",
      "another_test_404"
    ]

    assert Reap.stale_database_names(databases, &(&1 != "202")) == [
             "casein_test0_202"
           ]
  end

  test "recognizes the current OS process as alive" do
    assert Reap.pid_alive?(System.pid())
  end

  test "recognizes an exited OS process as dead" do
    {pid, 0} = System.cmd("sh", ["-c", "printf %s $$"])

    refute Reap.pid_alive?(pid)
  end
end
