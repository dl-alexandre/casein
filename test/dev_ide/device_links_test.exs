defmodule DevIDE.DeviceLinksTest do
  use DevIde.DataCase, async: false

  alias DevIDE.DeviceLinks
  alias DevIDE.DeviceLinks.Token
  alias DevIDE.Workspace
  alias DevIde.Repo

  defmodule OwnedSource do
    def get("missing", _auth), do: {:error, :not_found}

    def get(id, _auth),
      do: {:ok, %Workspace{id: id, name: "Workspace #{id}", user: "owner", status: :running}}
  end

  setup do
    prev_source = Application.get_env(:dev_ide, :workspace_source)
    Application.put_env(:dev_ide, :workspace_source, OwnedSource)

    on_exit(fn -> restore(:workspace_source, prev_source) end)

    :ok
  end

  test "creates a hashed persistent token and verifies socket claims" do
    assert {:ok, %{token: raw_token, link: link}} =
             DeviceLinks.create_from_pairing_claims(owner_claims(), %{
               "device_name" => "Pixel Tablet",
               "platform" => "android"
             })

    refute raw_token == link.token_hash
    assert link.resource_kind == "workspace"
    assert link.resource_id == "ws-1"
    assert link.resource_label == "Workspace ws-1"
    assert link.device_name == "Pixel Tablet"
    assert link.platform == "android"

    assert {:ok, claims} = DeviceLinks.verify_token(raw_token)
    assert claims.id == "owner"
    assert claims.email == "owner@example.com"
    assert claims.role == :owner
    assert claims.workspace_id == "ws-1"
    assert claims.resource_kind == "workspace"
    assert claims.device_link_id == link.id
    assert "dev_ide.session" in claims.capabilities

    assert %Token{last_seen_at: %DateTime{}} = Repo.get!(Token, link.id)
  end

  test "does not issue a persistent token for a non-owner" do
    claims = %{
      owner_claims()
      | id: "intruder",
        username: "intruder",
        email: "intruder@example.com"
    }

    assert {:error, :unauthorized} = DeviceLinks.create_from_pairing_claims(claims, %{})
  end

  test "revoked token no longer verifies" do
    assert {:ok, %{token: raw_token}} =
             DeviceLinks.create_from_pairing_claims(owner_claims(), %{})

    assert {:ok, _claims} = DeviceLinks.verify_token(raw_token)

    assert {:ok, _link} = DeviceLinks.revoke_token(raw_token)
    assert {:error, :revoked} = DeviceLinks.verify_token(raw_token)
  end

  test "missing workspace is surfaced" do
    claims = %{owner_claims() | workspace_id: "missing"}

    assert {:error, :not_found} = DeviceLinks.create_from_pairing_claims(claims, %{})
  end

  defp owner_claims do
    %{
      id: "owner",
      username: "owner",
      email: "owner@example.com",
      role: :owner,
      workspace_id: "ws-1"
    }
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)
end
