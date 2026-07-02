defmodule DevIDE.Workspaces.StateTest do
  use ExUnit.Case, async: false

  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.{MemoryAdapter, WorkspaceRecord}
  alias DevIDE.Workspaces.DbIsolation
  alias DevIDE.Workspace

  setup do
    MemoryAdapter.clear()
    prev_overrides = Application.get_env(:dev_ide, :workspace_modes)
    prev_default = Application.get_env(:dev_ide, :default_workspace_mode)
    Application.delete_env(:dev_ide, :workspace_modes)

    on_exit(fn ->
      MemoryAdapter.clear()
      restore(:workspace_modes, prev_overrides)
      restore(:default_workspace_mode, prev_default)
    end)

    :ok
  end

  defp restore(k, nil), do: Application.delete_env(:dev_ide, k)
  defp restore(k, v), do: Application.put_env(:dev_ide, k, v)

  defp ws(attrs) do
    base = %Workspace{
      id: "abc",
      name: "alpha",
      user: "alice",
      branch: "main",
      status: :running,
      path: "/workspaces/alpha",
      metadata: %{"id" => "abc", "name" => "alpha", "status" => "running"}
    }

    attrs =
      if Map.has_key?(attrs, :raw),
        do: Map.put(attrs, :metadata, Map.fetch!(attrs, :raw)) |> Map.delete(:raw),
        else: attrs

    Map.merge(base, attrs)
  end

  test "sync creates a record on first sync" do
    {:ok, %WorkspaceRecord{} = r} = State.sync(ws(%{}))
    assert r.external_id == "abc"
    assert r.name == "alpha"
    assert r.status == "running"
    assert r.host_path == "/workspaces/alpha"
    assert %DateTime{} = r.last_seen_at
  end

  test "sync updates an existing record by external_id" do
    {:ok, _} = State.sync(ws(%{}))

    {:ok, updated} =
      State.sync(ws(%{status: :stopped, metadata: %{"status" => "stopped"}}))

    assert updated.external_id == "abc"
    assert updated.status == "stopped"
  end

  describe "sync_many/1" do
    test "batch-creates records for all workspaces" do
      {:ok, records} =
        State.sync_many([
          ws(%{id: "w1", name: "one"}),
          ws(%{id: "w2", name: "two"})
        ])

      assert Enum.map(records, & &1.external_id) == ["w1", "w2"]
      assert {:ok, %WorkspaceRecord{name: "one"}} = MemoryAdapter.get("w1")
      assert {:ok, %WorkspaceRecord{name: "two"}} = MemoryAdapter.get("w2")
    end

    test "preserves IDE-owned fields (mode) when updating existing records" do
      {:ok, _} = State.sync(ws(%{id: "w1", name: "one"}))
      {:ok, _} = State.set_mode("w1", :review)

      {:ok, _} = State.sync_many([ws(%{id: "w1", name: "renamed", status: :stopped})])

      {:ok, r} = MemoryAdapter.get("w1")
      assert r.name == "renamed"
      assert r.status == "stopped"
      # a mode set out-of-band must survive a later source-driven sync
      assert r.mode == "review"
    end

    test "skips non-Workspace entries" do
      {:ok, records} = State.sync_many([ws(%{id: "w1"}), :not_a_workspace, nil])
      assert Enum.map(records, & &1.external_id) == ["w1"]
    end
  end

  test "manager_payload round-trips and sanitizes credential keys" do
    raw = %{
      "id" => "abc",
      "name" => "alpha",
      "DATABASE_URL" => "postgres://u:secret@x/y",
      "password" => "p",
      "ports" => %{"app" => 4000},
      "env" => ["FOO=bar", "POSTGRES_PASSWORD=hunter2", "DATABASE_URL=postgres://u:p@x/y"]
    }

    {:ok, r} = State.sync(ws(%{raw: raw}))

    refute Map.has_key?(r.manager_payload, "DATABASE_URL")
    refute Map.has_key?(r.manager_payload, "password")
    assert r.manager_payload["ports"]["app"] == 4000

    env = r.manager_payload["env"]
    assert "FOO=bar" in env
    assert Enum.any?(env, &String.contains?(&1, "[REDACTED]"))
    refute Enum.any?(env, &String.contains?(&1, "hunter2"))
    refute Enum.any?(env, &String.contains?(&1, "secret"))
  end

  test "persist_isolation stores redacted summary only" do
    {:ok, _} = State.sync(ws(%{}))

    iso = %DbIsolation{
      isolation: :shared_stage,
      source: :env_file,
      summary: "stage.rds.amazonaws.com:5432/app",
      detected_at: DateTime.utc_now()
    }

    {:ok, r} = State.persist_isolation("abc", iso)
    assert r.db_isolation == "shared_stage"
    assert r.db_isolation_source == "env_file"
    assert r.db_isolation_summary == "stage.rds.amazonaws.com:5432/app"
    refute r.db_isolation_summary =~ "secret"
  end

  test "mode_for: config override beats persisted" do
    Application.put_env(:dev_ide, :workspace_modes, %{"abc" => :review})
    {:ok, _} = State.set_mode("abc", :manual)
    assert {:review, :config_override} = State.mode_for("abc")
  end

  test "mode_for: persisted wins when no config override" do
    {:ok, _} = State.set_mode("abc", :manual)
    assert {:manual, :persisted} = State.mode_for("abc")
  end

  test "mode_for: default when neither config nor persisted" do
    Application.delete_env(:dev_ide, :workspace_modes)
    {mode, source} = State.mode_for("none")
    assert mode == :manual
    assert source == :default
  end

  test "set_mode rejects invalid mode" do
    assert {:error, :invalid_mode} = State.set_mode("abc", :nope)
  end

  test "grant_agent_write_unlock persists until/by and broadcasts to subscribers" do
    {:ok, _} = State.sync(ws(%{}))
    :ok = State.subscribe_agent_write_unlock_changes("abc")

    until = DateTime.add(DateTime.utc_now(), 3600, :second)
    {:ok, r} = State.grant_agent_write_unlock("abc", until, "alice")

    assert r.agent_write_unlocked_until == until
    assert r.agent_write_unlocked_by == "alice"
    assert %DateTime{} = r.agent_write_unlock_granted_at

    assert_receive {:agent_write_unlock_changed, "abc", ^until, "alice"}
  end

  test "grant_agent_write_unlock creates a record when none exists yet" do
    until = DateTime.add(DateTime.utc_now(), 3600, :second)
    {:ok, r} = State.grant_agent_write_unlock("brand-new", until, "bob")

    assert r.external_id == "brand-new"
    assert r.agent_write_unlocked_by == "bob"
  end

  test "revoke_agent_write_unlock clears until/by and broadcasts" do
    until = DateTime.add(DateTime.utc_now(), 3600, :second)
    {:ok, _} = State.grant_agent_write_unlock("abc", until, "alice")
    :ok = State.subscribe_agent_write_unlock_changes("abc")

    {:ok, r} = State.revoke_agent_write_unlock("abc")

    assert r.agent_write_unlocked_until == nil
    assert r.agent_write_unlocked_by == nil
    assert_receive {:agent_write_unlock_changed, "abc", nil, nil}
  end

  test "agent_write_unlock_for reports :inactive, :active, and :expired" do
    assert State.agent_write_unlock_for("no-such-workspace") == :inactive

    {:ok, _} = State.sync(ws(%{}))
    assert State.agent_write_unlock_for("abc") == :inactive

    future = DateTime.add(DateTime.utc_now(), 3600, :second)
    {:ok, _} = State.grant_agent_write_unlock("abc", future, "alice")
    assert {:active, ^future, "alice"} = State.agent_write_unlock_for("abc")

    past = DateTime.add(DateTime.utc_now(), -60, :second)
    {:ok, _} = State.grant_agent_write_unlock("abc", past, "alice")
    assert State.agent_write_unlock_for("abc") == :expired
  end

  test "no record field stores raw DATABASE_URL/password text" do
    raw = %{
      "DATABASE_URL" => "postgres://u:hunter2@stage.rds.amazonaws.com/app",
      "password" => "hunter2",
      "id" => "abc",
      "name" => "alpha"
    }

    {:ok, r} = State.sync(ws(%{raw: raw}))

    text =
      r
      |> Map.from_struct()
      |> Map.values()
      |> inspect()

    refute text =~ "hunter2"
    refute text =~ "DATABASE_URL"
  end
end
