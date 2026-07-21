defmodule DevIdeWeb.WorkspaceLive.Show.ConnectEventsTest do
  use DevIDE.DataCase, async: true

  alias DevIDE.Agents.OrchestratorTokens
  alias DevIdeWeb.WorkspaceLive.Show.ConnectEvents

  defp socket(assigns) do
    %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}}, assigns)}
  end

  defp unique_user do
    id = "u-connect-#{System.unique_integer([:positive])}"
    %{id: id, email: "t@example.com", role: :admin}
  end

  test "connect:close clears drawer token/error assigns" do
    s =
      socket(%{
        connect_drawer_open: true,
        connect_new_token: "tok",
        connect_mcp_json: "{}",
        connect_error: "boom",
        connect_info: "minted"
      })

    assert {:noreply, s2} = ConnectEvents.handle_event("connect:close", %{}, s)
    assert s2.assigns.connect_drawer_open == false
    assert s2.assigns.connect_new_token == nil
    assert s2.assigns.connect_mcp_json == nil
    assert s2.assigns.connect_error == nil
    assert s2.assigns.connect_info == nil
  end

  test "connect:toggle closes an open drawer without loading tokens" do
    s =
      socket(%{
        connect_drawer_open: true,
        connect_error: "stale",
        connect_tokens: :sentinel
      })

    assert {:noreply, s2} = ConnectEvents.handle_event("connect:toggle", %{}, s)
    assert s2.assigns.connect_drawer_open == false
    assert s2.assigns.connect_error == nil
    # load_tokens is skipped on close — tokens assign is untouched.
    assert s2.assigns.connect_tokens == :sentinel
  end

  test "connect:mint happy path returns raw once, durable mcp json, and hashed list entry" do
    user = unique_user()

    s =
      socket(%{
        current_user: user,
        connect_drawer_open: true,
        connect_new_token: nil,
        connect_mcp_json: nil,
        connect_error: "stale",
        connect_info: nil,
        connect_tokens: []
      })

    assert {:noreply, s2} =
             ConnectEvents.handle_event("connect:mint", %{"label" => "  My laptop  "}, s)

    raw = s2.assigns.connect_new_token
    assert is_binary(raw) and raw != ""
    assert s2.assigns.connect_error == nil
    assert is_binary(s2.assigns.connect_info) and s2.assigns.connect_info != ""

    mcp = Jason.decode!(s2.assigns.connect_mcp_json)
    assert %{"mcpServers" => servers} = mcp

    for name <- ["devide-terminal", "devide-preview", "devide-artifact"] do
      assert %{"headers" => %{"Authorization" => auth}} = servers[name]
      assert auth == "Bearer " <> raw
    end

    assert [record] = s2.assigns.connect_tokens
    assert record.label == "My laptop"
    assert record.token_hash == OrchestratorTokens.token_hash(raw)
    assert record.token_hash != raw
  end

  test "connect:revoke own token clears list and revealed raw" do
    user = unique_user()

    s =
      socket(%{
        current_user: user,
        connect_drawer_open: true,
        connect_new_token: nil,
        connect_mcp_json: nil,
        connect_error: nil,
        connect_info: nil,
        connect_tokens: []
      })

    assert {:noreply, s2} =
             ConnectEvents.handle_event("connect:mint", %{"label" => "to-revoke"}, s)

    assert [record] = s2.assigns.connect_tokens
    assert is_binary(s2.assigns.connect_new_token)

    assert {:noreply, s3} =
             ConnectEvents.handle_event("connect:revoke", %{"id" => record.id}, s2)

    assert s3.assigns.connect_info == "Token revoked."
    assert s3.assigns.connect_tokens == []
    assert s3.assigns.connect_new_token == nil
    assert s3.assigns.connect_mcp_json == nil
  end

  test "connect:revoke rejects cross-subject ids without revoking peer token" do
    user_a = unique_user()
    user_b = unique_user()

    assert {:ok, _raw, record_a} =
             OrchestratorTokens.create_for_subject(user_a, label: "peer-token")

    s =
      socket(%{
        current_user: user_b,
        connect_drawer_open: true,
        connect_error: nil,
        connect_info: nil,
        connect_tokens: []
      })

    assert {:noreply, s2} =
             ConnectEvents.handle_event("connect:revoke", %{"id" => record_a.id}, s)

    assert s2.assigns.connect_error == "Token not found."

    subject_a = OrchestratorTokens.subject_id(user_a)
    assert [%{id: id}] = OrchestratorTokens.list_for_subject(subject_a)
    assert id == record_a.id
  end

  test "connect:toggle open and connect:load populate connect_tokens from Repo" do
    user = unique_user()

    s =
      socket(%{
        current_user: user,
        connect_drawer_open: false,
        connect_error: "stale",
        connect_tokens: :not_loaded
      })

    assert {:noreply, s2} = ConnectEvents.handle_event("connect:toggle", %{}, s)
    assert s2.assigns.connect_drawer_open == true
    assert s2.assigns.connect_tokens == []
    assert s2.assigns.connect_error == nil

    assert {:ok, _raw, record} =
             OrchestratorTokens.create_for_subject(user, label: "loaded")

    assert {:noreply, s3} = ConnectEvents.handle_event("connect:load", %{}, s2)
    assert [loaded] = s3.assigns.connect_tokens
    assert loaded.id == record.id
    assert loaded.label == "loaded"
  end
end
