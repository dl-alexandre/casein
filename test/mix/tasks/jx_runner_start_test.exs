defmodule Mix.Tasks.Jx.Runner.StartTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Jx.Runner.Start

  setup do
    Mix.Task.reenable("jx.runner.start")
    :ok
  end

  test "requires an endpoint before starting runner dependencies" do
    assert_raise ArgumentError, "runner endpoint required via --endpoint http://host:4000", fn ->
      Start.run(["--token", "runner-token"])
    end
  end

  test "rejects human-readable runner ids before registration" do
    assert_raise ArgumentError, "runner id must be a UUID, got: \"dogfood-runner\"", fn ->
      Start.run([
        "--endpoint",
        "http://localhost:4000",
        "--token",
        "runner-token",
        "--runner-id",
        "dogfood-runner"
      ])
    end
  end
end
