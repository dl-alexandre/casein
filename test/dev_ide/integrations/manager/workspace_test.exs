defmodule DevIDE.Integrations.Manager.WorkspaceTest do
  use ExUnit.Case, async: true

  alias DevIDE.Integrations.Manager.Workspace

  @sample %{
    "id" => "11111111-1111-1111-1111-111111111111",
    "name" => "alice-feature",
    "user" => "alice",
    "branch" => "feature/x",
    "type" => "v3",
    "status" => "running",
    "path" => "/workspaces/alice-feature",
    "slot" => 3,
    "domainBase" => "alice-feature.devbox.example.com",
    "ports" => %{"app" => 10_100, "opencode" => 11_003},
    "createdAt" => "2026-05-08T00:00:00Z",
    "lastStarted" => "2026-05-08T01:00:00Z",
    "androidApkAvailable" => false
  }

  test "from_payload normalizes the manager response" do
    ws = Workspace.from_payload(@sample)

    assert ws.id == @sample["id"]
    assert ws.name == "alice-feature"
    assert ws.type == :v3
    assert ws.status == :running
    assert ws.path == "/workspaces/alice-feature"
    assert ws.domain_base == "alice-feature.devbox.example.com"
    assert ws.ports["opencode"] == 11_003
  end

  test "preserves the raw payload for debugging" do
    ws = Workspace.from_payload(@sample)
    assert ws.raw == @sample
    assert ws.raw["androidApkAvailable"] == false
  end

  test "unknown status and type fall back to :unknown" do
    ws = Workspace.from_payload(%{"id" => "x", "name" => "y", "status" => "weird", "type" => "?"})
    assert ws.status == :unknown
    assert ws.type == :unknown
  end
end
