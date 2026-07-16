defmodule DevIDE.Test.ToolActionFixtures.FastAction do
  @behaviour DevIDE.Agents.ToolAction

  use Jido.Action,
    name: "fast_action",
    description: "fast",
    schema: [value: [type: :integer, required: true]]

  @impl DevIDE.Agents.ToolAction
  def parameters, do: %{"type" => "object", "properties" => %{}}

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: %{mutation?: false, danger_level: :low}

  @impl Jido.Action
  def run(%{value: value}, _context), do: {:ok, %{value: value}}
end

defmodule DevIDE.Test.ToolActionFixtures.AliasedAction do
  @behaviour DevIDE.Agents.ToolAction

  use Jido.Action,
    name: "aliased_action",
    description: "aliased",
    schema: [target_id: [type: :string, required: true]]

  @impl DevIDE.Agents.ToolAction
  def parameters, do: %{"type" => "object", "properties" => %{}}

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: %{mutation?: false, danger_level: :low}

  @impl DevIDE.Agents.ToolAction
  def param_aliases, do: %{target_id: ~w(target_id id)}

  @impl Jido.Action
  def run(%{target_id: target_id}, _context), do: {:ok, %{target_id: target_id}}
end

defmodule DevIDE.Test.ToolActionFixtures.SlowAction do
  @behaviour DevIDE.Agents.ToolAction

  use Jido.Action,
    name: "slow_action",
    description: "slow",
    schema: []

  @impl DevIDE.Agents.ToolAction
  def parameters, do: %{"type" => "object", "properties" => %{}}

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: %{mutation?: false, danger_level: :low, timeout_ms: 50}

  @impl Jido.Action
  def run(_params, _context) do
    Process.sleep(200)
    {:ok, %{}}
  end
end
