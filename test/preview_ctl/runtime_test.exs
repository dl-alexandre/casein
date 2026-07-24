defmodule PreviewCtl.RuntimeTest do
  use Casein.TestCase, async: false

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
      metadata: %{
        "allowed_origins" => ["https://alice.devbox.example.com"],
        "storage_profile" => "workspace",
        "storage_profile_key" => "workspace",
        "storage_state_path" => "/tmp/devide-storage.json"
      }
    }

    preview = %{id: 42, url: "https://alice.devbox.example.com"}

    assert {:ok, ^session} = Runtime.start(session.id, session, preview, adapter: :memory)
    assert %{adapter_module: FakeAdapter, adapter_state: adapter_state} = Registry.get(session.id)
    assert adapter_state.storage_profile == "workspace"
    assert adapter_state.storage_state_path == "/tmp/devide-storage.json"
  end

  test "matches_reuse_opts? compares actor, assignment, isolation, headers, and storage profile" do
    session = %{
      actor_id: "agent-1",
      assignment_id: "run-1",
      metadata: %{
        "isolation_key" => "lane-a",
        "default_headers" => %{"X-Test" => "1"},
        "storage_profile" => "profile",
        "storage_profile_name" => "admin"
      }
    }

    assert Runtime.matches_reuse_opts?(session,
             actor_id: "agent-1",
             assignment_id: "run-1",
             isolation_key: "lane-a",
             default_headers: %{"X-Test" => "1"},
             storage_profile: :profile,
             storage_profile_name: "admin"
           )

    refute Runtime.matches_reuse_opts?(session, actor_id: "agent-2")
    refute Runtime.matches_reuse_opts?(session, storage_profile: :workspace)
  end
end
