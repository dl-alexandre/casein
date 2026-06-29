defmodule DevIdeWeb.API.MCPWorkspaceScopeTest do
  use ExUnit.Case, async: true

  alias DevIDE.Workspaces.Aliases
  alias DevIdeWeb.API.MCPWorkspaceScope, as: Scope

  @scoped "ws-scoped"
  @other "ws-other"

  test "default_workspace_id/1 returns non-empty configured ids" do
    assert Scope.default_workspace_id(default_workspace_id: @scoped) == @scoped
    assert Scope.default_workspace_id([]) == nil
    assert Scope.default_workspace_id(default_workspace_id: "") == nil
    assert Scope.default_workspace_id(default_workspace_id: nil) == nil
  end

  test "workspace_id/1 reads string or atom keys" do
    assert Scope.workspace_id(%{"workspace_id" => @scoped}) == @scoped
    assert Scope.workspace_id(%{workspace_id: @scoped}) == @scoped
    assert Scope.workspace_id(%{}) == nil
    assert Scope.workspace_id("not-a-map") == nil
  end

  test "inject_default_workspace/2 adds workspace_id when omitted" do
    params = %{"name" => "terminal_list_sessions"}

    assert Scope.inject_default_workspace(params, nil) == params

    assert %{"arguments" => %{"workspace_id" => @scoped}} =
             Scope.inject_default_workspace(params, @scoped)

    assert Scope.inject_default_workspace(
             %{"name" => "tool", "arguments" => %{"workspace_id" => @scoped}},
             @scoped
           ) == %{"name" => "tool", "arguments" => %{"workspace_id" => @scoped}}

    assert Scope.inject_default_workspace(%{"name" => "tool", "arguments" => "bad"}, @scoped) ==
             %{"name" => "tool", "arguments" => "bad"}
  end

  test "scoped_call_params/2 injects omitted workspace ids" do
    params = %{"name" => "terminal_list_sessions"}

    assert {:ok, %{"arguments" => %{"workspace_id" => @scoped}}} =
             Scope.scoped_call_params(params, @scoped)
  end

  test "scoped_call_params/2 accepts matching explicit workspace ids" do
    params = %{"name" => "tool", "arguments" => %{"workspace_id" => @scoped}}

    assert {:ok, ^params} = Scope.scoped_call_params(params, @scoped)
  end

  test "scoped_call_params/2 tolerates linked workspace aliases" do
    path = "/tmp/mcp_scope_aliases_#{System.unique_integer([:positive])}"
    folder_id = Aliases.folder_id_for_path(path)

    params = %{"name" => "tool", "arguments" => %{"workspace_id" => folder_id}}

    assert {:ok, ^params} = Scope.scoped_call_params(params, folder_id)
  end

  test "scoped_call_params/2 rejects cross-workspace overrides" do
    params = %{"name" => "tool", "arguments" => %{"workspace_id" => @other}}

    assert {:error, error} = Scope.scoped_call_params(params, @scoped)
    assert error.error == :workspace_scope_mismatch
    assert error.scoped_workspace_id == @scoped
    assert error.requested_workspace_id == @other
    assert error.message =~ @scoped
    assert error.message =~ @other
  end

  test "workspaces_compatible?/2 matches identical or linked ids" do
    path = "/tmp/mcp_compat_#{System.unique_integer([:positive])}"
    folder_id = Aliases.folder_id_for_path(path)

    assert Scope.workspaces_compatible?(@scoped, @scoped)
    assert Scope.workspaces_compatible?(folder_id, folder_id)
    assert Scope.workspaces_compatible?(folder_id, Aliases.folder_id_for_path(path))
    refute Scope.workspaces_compatible?(@scoped, @other)
    refute Scope.workspaces_compatible?(nil, @scoped)
  end

  test "tool_specs/2 removes workspace_id from required fields when scoped" do
    tools = [
      %{
        name: "terminal_list_sessions",
        inputSchema: %{required: ["workspace_id", "session"], properties: %{}}
      },
      %{name: "other", inputSchema: %{}}
    ]

    assert [%{inputSchema: %{required: ["session"]}}, %{name: "other"}] =
             Scope.tool_specs(tools, @scoped)

    assert Scope.tool_specs(tools, nil) == tools
  end

  test "scoped_instructions/2 appends scoped-endpoint guidance" do
    base = "Use the terminal tools."

    assert Scope.scoped_instructions(base, nil) == base

    assert Scope.scoped_instructions(base, @scoped) =~ base
    assert Scope.scoped_instructions(base, @scoped) =~ inspect(@scoped)
  end

  test "workspace_scope_mismatch/2 builds a structured error map" do
    error = Scope.workspace_scope_mismatch(@scoped, @other)

    assert error.error == :workspace_scope_mismatch
    assert is_binary(error.message)
  end
end
