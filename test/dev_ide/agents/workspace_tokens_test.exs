defmodule Casein.Agents.WorkspaceTokensTest do
  use ExUnit.Case, async: false

  alias Casein.Agents.WorkspaceTokens

  setup do
    prev_registry = Application.get_env(:casein, :workspace_api_tokens)
    prev_store = Application.get_env(:casein, :workspace_tokens_store)
    prev_api_token = Application.get_env(:casein, :api_token)
    prev_env_registry = System.get_env("DEV_IDE_WORKSPACE_API_TOKENS")
    prev_env_token = System.get_env("DEV_IDE_API_TOKEN")
    System.delete_env("DEV_IDE_WORKSPACE_API_TOKENS")
    System.delete_env("DEV_IDE_API_TOKEN")

    store =
      System.tmp_dir!()
      |> Path.join("workspace-tokens-#{System.unique_integer([:positive])}.json")

    Application.put_env(:casein, :workspace_tokens_store, store)
    Application.put_env(:casein, :workspace_api_tokens, %{})

    on_exit(fn ->
      restore_app_env(:workspace_api_tokens, prev_registry)
      restore_app_env(:workspace_tokens_store, prev_store)
      restore_app_env(:api_token, prev_api_token)
      restore_sys_env("DEV_IDE_WORKSPACE_API_TOKENS", prev_env_registry)
      restore_sys_env("DEV_IDE_API_TOKEN", prev_env_token)
      File.rm(store)
    end)

    %{store: store}
  end

  test "token_for finds direct and list-scoped registry entries" do
    Application.put_env(:casein, :workspace_api_tokens, %{
      "tok-direct" => "ws-1",
      "tok-list" => ["ws-2", "ws-3"]
    })

    assert WorkspaceTokens.token_for("ws-1") == "tok-direct"
    assert WorkspaceTokens.token_for("ws-3") == "tok-list"
    assert WorkspaceTokens.token_for("ws-unknown") == nil
  end

  test "token_for reads DEV_IDE_WORKSPACE_API_TOKENS from the environment" do
    System.put_env("DEV_IDE_WORKSPACE_API_TOKENS", ~s({"env-tok":"ws-env"}))
    assert WorkspaceTokens.token_for("ws-env") == "env-tok"
  end

  test "ensure_for returns the registered token without minting" do
    Application.put_env(:casein, :workspace_api_tokens, %{"tok-a" => "ws-a"})
    assert {:ok, "tok-a"} = WorkspaceTokens.ensure_for("ws-a")
  end

  test "ensure_for mints, registers, and persists a token for a fresh workspace", %{
    store: store
  } do
    assert {:ok, token} = WorkspaceTokens.ensure_for("ws-fresh")
    assert token =~ ~r/^[0-9a-f]{64}$/

    # registered: both auth plugs read the application env per request
    assert Application.get_env(:casein, :workspace_api_tokens)[token] == "ws-fresh"

    # persisted: survives a restart via the runtime.exs boot merge
    assert Jason.decode!(File.read!(store))[token] == "ws-fresh"

    # stable: a second call returns the same token instead of re-minting
    assert {:ok, ^token} = WorkspaceTokens.ensure_for("ws-fresh")
  end

  test "ensure_for rejects a missing workspace id" do
    assert {:error, :workspace_id_missing} = WorkspaceTokens.ensure_for(nil)
    assert {:error, :workspace_id_missing} = WorkspaceTokens.ensure_for("")
  end

  test "for_agent resolves the scoped token for a workspace with an id" do
    Application.put_env(:casein, :workspace_api_tokens, %{"tok-b" => "ws-b"})
    assert {:ok, "tok-b"} = WorkspaceTokens.for_agent(%{id: "ws-b", name: "b"})
    assert {:ok, "tok-b"} = WorkspaceTokens.for_agent(%{"id" => "ws-b"})
  end

  test "for_agent falls back to the global token only for id-less workspaces" do
    Application.put_env(:casein, :api_token, "global-token")

    {result, log} =
      ExUnit.CaptureLog.with_log(fn -> WorkspaceTokens.for_agent(%{name: "no-id"}) end)

    assert {:ok, "global-token"} = result
    assert log =~ "global token"
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:casein, key)
  defp restore_app_env(key, value), do: Application.put_env(:casein, key, value)

  defp restore_sys_env(name, nil), do: System.delete_env(name)
  defp restore_sys_env(name, value), do: System.put_env(name, value)
end
