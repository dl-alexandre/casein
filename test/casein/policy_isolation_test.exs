defmodule Casein.PolicyIsolationTest do
  use Casein.TestCase, async: false
  alias Casein.Policy
  alias Casein.Policy.Decision

  setup do
    prev = Application.get_env(:casein, :workspace_modes)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:casein, :workspace_modes, prev),
        else: Application.delete_env(:casein, :workspace_modes)
    end)

    Application.delete_env(:casein, :workspace_modes)
    :ok
  end

  test "shared_stage isolation forces :shared_stage_guarded reason regardless of mode" do
    Application.put_env(:casein, :workspace_modes, %{"w" => :review})

    assert %Decision{verdict: :deny, reason: :shared_stage_guarded} =
             Policy.can_enable_agent_write?(%{workspace_id: "w", db_isolation: :shared_stage})
  end

  test "unsafe isolation forces :unsafe_db reason" do
    Application.put_env(:casein, :workspace_modes, %{"w" => :review})

    assert %Decision{verdict: :deny, reason: :unsafe_db} =
             Policy.can_enable_agent_write?(%{workspace_id: "w", db_isolation: :unsafe})
  end

  test "ephemeral isolation allows agent write without manual mode or unlock" do
    Application.put_env(:casein, :workspace_modes, %{"w" => :review})

    assert %Decision{verdict: :allow} =
             Policy.can_enable_agent_write?(%{workspace_id: "w", db_isolation: :ephemeral})
  end

  test "block_reason mirrors the deny reason" do
    Application.put_env(:casein, :workspace_modes, %{"w" => :shared_stage_guarded})
    assert Policy.block_reason(%{workspace_id: "w"}) == :shared_stage_guarded

    Application.put_env(:casein, :workspace_modes, %{"w" => :review})
    assert Policy.block_reason(%{workspace_id: "w", db_isolation: :unsafe}) == :unsafe_db
    assert is_nil(Policy.block_reason(%{workspace_id: "w", db_isolation: :ephemeral}))
  end
end
