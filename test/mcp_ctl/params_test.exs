defmodule McpCtl.ParamsTest do
  use ExUnit.Case, async: true

  alias McpCtl.Params

  test "preview_open_props includes shared open-session fields" do
    props = Params.preview_open_props()

    assert props[:workspace_id]
    assert props[:workspace_path]
    assert props[:surface][:default] == "app"
  end

  test "terminal_workspace_props only includes workspace_id" do
    assert %{workspace_id: param} = Params.terminal_workspace_props()
    assert param[:description] =~ "Scopes session discovery"
  end
end
