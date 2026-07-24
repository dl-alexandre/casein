defmodule Casein.Test.ToolActionFixtures.FastAction do
  @behaviour Casein.Agents.ToolAction

  use Jido.Action,
    name: "fast_action",
    description: "fast",
    schema: [value: [type: :integer, required: true]]

  @impl Casein.Agents.ToolAction
  def parameters, do: %{"type" => "object", "properties" => %{}}

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: %{mutation?: false, danger_level: :low}

  @impl Jido.Action
  def run(%{value: value}, _context), do: {:ok, %{value: value}}
end

defmodule Casein.Test.ToolActionFixtures.AliasedAction do
  @behaviour Casein.Agents.ToolAction

  use Jido.Action,
    name: "aliased_action",
    description: "aliased",
    schema: [target_id: [type: :string, required: true]]

  @impl Casein.Agents.ToolAction
  def parameters, do: %{"type" => "object", "properties" => %{}}

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: %{mutation?: false, danger_level: :low}

  @impl Casein.Agents.ToolAction
  def param_aliases, do: %{target_id: ~w(target_id id)}

  @impl Jido.Action
  def run(%{target_id: target_id}, _context), do: {:ok, %{target_id: target_id}}
end

defmodule Casein.Test.ToolActionFixtures.SlowAction do
  @behaviour Casein.Agents.ToolAction

  use Jido.Action,
    name: "slow_action",
    description: "slow",
    schema: []

  @impl Casein.Agents.ToolAction
  def parameters, do: %{"type" => "object", "properties" => %{}}

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: %{mutation?: false, danger_level: :low, timeout_ms: 50}

  @impl Jido.Action
  def run(_params, _context) do
    # Block until released (or safety timeout). Timeout tests kill this task
    # via Task.shutdown after timeout_ms; no caller needs to send :release today.
    receive do
      :release -> :ok
    after
      5_000 -> :ok
    end

    {:ok, %{}}
  end
end
