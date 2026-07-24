defmodule McpCtl.ParamsTest do
  use Casein.TestCase, async: true

  alias McpCtl.Params

  test "preview_open_props includes shared open-session fields" do
    props = Params.preview_open_props()

    assert props[:workspace_id]
    assert props[:workspace_path]
    assert props[:tmux_session]
    assert props[:surface][:default] == "app"
    assert props[:share_session][:type] == "boolean"
    assert props[:attach_to_pane_id][:type] == "string"
    assert props[:storage_profile][:enum] == ["ephemeral", "workspace", "profile"]
    assert props[:storage_profile_name]
  end

  test "terminal_workspace_props only includes workspace_id" do
    assert %{workspace_id: param} = Params.terminal_workspace_props()
    assert param[:description] =~ "Scopes session discovery"
  end
end
