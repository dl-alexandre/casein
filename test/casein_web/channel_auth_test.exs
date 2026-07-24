defmodule CaseinWeb.ChannelAuthTest do
  use Casein.TestCase, async: false

  alias CaseinWeb.ChannelAuth

  @user_id "dev"
  @workspace_id "ws-1"

  test "mobile pairing token signs short-lived workspace-scoped claims" do
    token =
      ChannelAuth.sign_pairing_token(
        %{id: @user_id, email: "dev@local", role: :user},
        @workspace_id
      )

    assert {:ok, claims} = ChannelAuth.verify_pairing_token(token)
    assert claims.id == @user_id
    assert claims.username == @user_id
    assert claims.email == "dev@local"
    # Flat peer model: pairing tokens never carry an elevated admin role.
    assert claims.role == :user
    assert claims.workspace_id == @workspace_id
  end

  test "mobile pairing token verification rejects wrong signing salt payload" do
    bad_token =
      Phoenix.Token.sign(CaseinWeb.Endpoint, "user socket", %{
        kind: :mobile_pairing,
        id: @user_id,
        workspace_id: @workspace_id
      })

    assert {:error, _} = ChannelAuth.verify_pairing_token(bad_token)
  end

  test "mobile pairing token verification rejects malformed claims" do
    bad_token =
      Phoenix.Token.sign(CaseinWeb.Endpoint, "mobile pairing", %{
        kind: :mobile_pairing,
        id: @user_id
      })

    assert {:error, :invalid_pairing_token} = ChannelAuth.verify_pairing_token(bad_token)
  end

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
      Phoenix.Token.sign(CaseinWeb.Endpoint, "terminal-workspace", %{
        kind: :terminal_workspace,
        user_id: @user_id,
        workspace_id: @workspace_id
      })

    assert {:error, _} = ChannelAuth.verify_terminal_capability(bad_token)
  end

  test "terminal capability verification rejects wrong claim kind" do
    bad_token =
      Phoenix.Token.sign(CaseinWeb.Endpoint, "terminal workspace", %{
        kind: :other,
        user_id: @user_id,
        workspace_id: @workspace_id
      })

    assert {:error, :invalid_terminal_capability} =
             ChannelAuth.verify_terminal_capability(bad_token)
  end

  test "terminal capability verification rejects malformed claims" do
    bad_token =
      Phoenix.Token.sign(CaseinWeb.Endpoint, "terminal workspace", %{
        kind: :terminal_workspace,
        user_id: @user_id
      })

    assert {:error, :invalid_terminal_capability} =
             ChannelAuth.verify_terminal_capability(bad_token)
  end
end
