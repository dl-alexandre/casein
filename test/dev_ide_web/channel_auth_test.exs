defmodule DevIdeWeb.ChannelAuthTest do
  use ExUnit.Case, async: false

  alias DevIdeWeb.ChannelAuth

  @user_id "dev"
  @workspace_id "ws-1"

  test "terminal workspace capability signs and verifies" do
    token =
      ChannelAuth.sign_terminal_capability(@user_id, @workspace_id,
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: "/tmp"
      )

    assert {:ok, claims} = ChannelAuth.verify_terminal_capability(token)
    assert claims[:kind] == :terminal_workspace
    assert claims[:user_id] == @user_id
    assert claims[:workspace_id] == @workspace_id
    assert claims[:workspace_name] == "alpha"
    assert claims[:workspace_user] == "alice"
    assert claims[:workspace_path] == "/tmp"
  end

  test "terminal capability verification rejects non-binary tokens" do
    assert {:error, :missing} = ChannelAuth.verify_terminal_capability(nil)
    assert {:error, :missing} = ChannelAuth.verify_terminal_capability(123)
  end

  test "terminal capability verification rejects wrong signing salt payload" do
    bad_token =
      Phoenix.Token.sign(DevIdeWeb.Endpoint, "terminal-workspace", %{
        kind: :terminal_workspace,
        user_id: @user_id,
        workspace_id: @workspace_id
      })

    assert {:error, _} = ChannelAuth.verify_terminal_capability(bad_token)
  end

  test "terminal capability verification rejects wrong claim kind" do
    bad_token =
      Phoenix.Token.sign(DevIdeWeb.Endpoint, "terminal workspace", %{
        kind: :other,
        user_id: @user_id,
        workspace_id: @workspace_id
      })

    assert {:error, :invalid_terminal_capability} =
             ChannelAuth.verify_terminal_capability(bad_token)
  end

  test "terminal capability verification rejects malformed claims" do
    bad_token =
      Phoenix.Token.sign(DevIdeWeb.Endpoint, "terminal workspace", %{
        kind: :terminal_workspace,
        user_id: @user_id
      })

    assert {:error, :invalid_terminal_capability} =
             ChannelAuth.verify_terminal_capability(bad_token)
  end
end
