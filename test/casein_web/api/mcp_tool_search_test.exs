defmodule CaseinWeb.API.MCPToolSearchTest do
  use ExUnit.Case, async: false

  alias CaseinWeb.API.MCPToolSearch

  @specs [
    %{name: "terminal_context", description: "recommended terminal workflow", inputSchema: %{}},
    %{name: "terminal_list_sessions", description: "list live sessions", inputSchema: %{}},
    %{name: "terminal_topology", description: "windows and panes geometry", inputSchema: %{}},
    %{
      name: "terminal_capture",
      description: "capture pane scrollback / log output",
      inputSchema: %{}
    },
    %{
      name: "terminal_send_agent_command",
      description: "send a command to the agent pane",
      inputSchema: %{}
    },
    %{
      name: "terminal_wait_agent_state",
      description: "wait for the agent state",
      inputSchema: %{}
    },
    %{
      name: "terminal_set_agent_label",
      description: "Set a label on an agent pane",
      inputSchema: %{}
    },
    %{
      name: "preview_screenshot",
      description: "Capture a screenshot image of the current page",
      inputSchema: %{}
    },
    %{
      name: "preview_close",
      description: "Close and kill a preview pane session",
      inputSchema: %{}
    }
  ]

  setup do
    prev = Application.get_env(:casein, :mcp_tool_search)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:casein, :mcp_tool_search),
        else: Application.put_env(:casein, :mcp_tool_search, prev)
    end)

    :ok
  end

  defp names(specs), do: Enum.map(specs, & &1.name)

  describe "list_tools/2" do
    test "returns the full list unchanged when disabled" do
      Application.put_env(:casein, :mcp_tool_search, false)
      assert MCPToolSearch.list_tools(@specs, :terminal) == @specs
    end

    test "reduces a surface with a core to core + meta when enabled" do
      Application.put_env(:casein, :mcp_tool_search, true)
      out = names(MCPToolSearch.list_tools(@specs, :terminal))

      assert "terminal_list_sessions" in out
      assert "terminal_send_agent_command" in out
      assert "search_tools" in out
      assert "invoke_tool" in out
      # long tail hidden
      refute "terminal_set_agent_label" in out
      assert length(out) == 8
    end

    test "returns the full list for a surface with no core, even when enabled" do
      Application.put_env(:casein, :mcp_tool_search, true)
      # :artifact has no core defined — must not be reduced (and must not become
      # just the two meta-tools).
      assert MCPToolSearch.list_tools(@specs, :artifact) == @specs
    end
  end

  describe "cross-server catalog + routing" do
    test "catalog spans every Casein server, each spec tagged with its server" do
      cat = MCPToolSearch.catalog()
      servers = cat |> Enum.map(& &1.server) |> Enum.uniq() |> Enum.sort()
      names = Enum.map(cat, &to_string(&1.name))

      assert servers == ["artifact", "code", "preview", "terminal"]
      assert "terminal_capture" in names
      assert "preview_screenshot" in names
      assert "artifact_create" in names
      assert "code_read" in names
    end

    test "search over the catalog finds tools on other servers (cross-server)" do
      %{matches: matches} =
        MCPToolSearch.search(MCPToolSearch.catalog(), "take a screenshot of the page")

      shot = Enum.find(matches, &(&1.name == "preview_screenshot"))
      assert shot
      assert shot.server == "preview"
    end

    test "owning_module routes a tool name to the server that defines it" do
      assert MCPToolSearch.owning_module("terminal_capture") == CaseinWeb.API.TerminalMCP
      assert MCPToolSearch.owning_module("preview_screenshot") == CaseinWeb.API.PreviewMCP
      assert MCPToolSearch.owning_module("artifact_create") == CaseinWeb.API.ArtifactMCP
      assert MCPToolSearch.owning_module("no_such_tool") == nil
    end
  end

  describe "search/3" do
    test "finds a tool by a direct term" do
      %{matches: matches} = MCPToolSearch.search(@specs, "label an agent pane")
      assert "terminal_set_agent_label" in names_of(matches)
    end

    test "finds a tool by an intent SYNONYM (picture -> screenshot)" do
      %{matches: matches} = MCPToolSearch.search(@specs, "take a picture of the page")
      assert "preview_screenshot" in names_of(matches)
    end

    test "finds a tool by an intent SYNONYM (kill -> close)" do
      %{matches: matches} = MCPToolSearch.search(@specs, "kill the preview")
      assert "preview_close" in names_of(matches)
    end

    test "returns nothing for a no-match query" do
      assert %{matches: []} = MCPToolSearch.search(@specs, "zzzz nonexistent qqqq")
    end

    test "never returns the meta-tools themselves" do
      %{matches: matches} = MCPToolSearch.search(@specs, "search invoke tool")
      refute "search_tools" in names_of(matches)
      refute "invoke_tool" in names_of(matches)
    end
  end

  describe "invoke_target/1" do
    test "extracts name + arguments" do
      assert {"terminal_capture", %{"session" => "s"}} =
               MCPToolSearch.invoke_target(%{
                 "name" => "terminal_capture",
                 "arguments" => %{"session" => "s"}
               })
    end

    test "returns nil name when absent" do
      assert {nil, %{}} = MCPToolSearch.invoke_target(%{})
    end
  end

  defp names_of(matches), do: Enum.map(matches, & &1.name)
end
