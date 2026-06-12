defmodule PreviewCtl.RuntimeTest do
  use ExUnit.Case, async: false

  alias PreviewCtl.{Registry, Runtime, Test.FakeAdapter}

  setup do
    _ = Registry.clear()
    :ok
  end

  test "start registers adapter runtime" do
    session = %{
      id: System.unique_integer([:positive]),
      workspace_id: "ws-1",
      current_url: "https://alice.devbox.example.com",
      metadata: %{"allowed_origins" => ["https://alice.devbox.example.com"]}
    }

    preview = %{id: 42, url: "https://alice.devbox.example.com"}

    assert {:ok, ^session} = Runtime.start(session.id, session, preview, adapter: :memory)
    assert %{adapter_module: FakeAdapter} = Registry.get(session.id)
  end

  test "matches_reuse_opts? compares actor, assignment, isolation, and headers" do
    session = %{
      actor_id: "agent-1",
      assignment_id: "run-1",
      metadata: %{"isolation_key" => "lane-a", "default_headers" => %{"X-Test" => "1"}}
    }

    assert Runtime.matches_reuse_opts?(session,
             actor_id: "agent-1",
             assignment_id: "run-1",
             isolation_key: "lane-a",
             default_headers: %{"X-Test" => "1"}
           )

    refute Runtime.matches_reuse_opts?(session, actor_id: "agent-2")
  end
end
