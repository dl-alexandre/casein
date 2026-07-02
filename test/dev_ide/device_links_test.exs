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

  test "creates a hashed persistent token with expires_at and verifies socket claims" do
    assert {:ok, %{token: raw_token, link: link}} =
             DeviceLinks.create_from_pairing_claims(owner_claims(), %{
               "device_name" => "Pixel Tablet",
               "platform" => "android"
             })

    refute raw_token == link.token_hash
    assert %DateTime{} = link.expires_at
    assert DateTime.compare(link.expires_at, DateTime.utc_now()) == :gt
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

  test "list_for_subject returns active links ordered by recency" do
    assert {:ok, %{link: first}} = DeviceLinks.create_from_pairing_claims(owner_claims(), %{})
    assert {:ok, %{link: second}} = DeviceLinks.create_from_pairing_claims(owner_claims(), %{})

    Repo.update!(Ecto.Changeset.change(first, last_seen_at: ~U[2026-01-01 00:00:00.000000Z]))
    Repo.update!(Ecto.Changeset.change(second, last_seen_at: ~U[2026-06-01 00:00:00.000000Z]))

    assert [newest, older] = DeviceLinks.list_for_subject("owner")
    assert newest.id == second.id
    assert older.id == first.id
  end

  test "revoke_all_for_subject revokes every active link" do
    assert {:ok, _} = DeviceLinks.create_from_pairing_claims(owner_claims(), %{})
    assert {:ok, _} = DeviceLinks.create_from_pairing_claims(owner_claims(), %{})

    assert DeviceLinks.revoke_all_for_subject("owner") == 2
    assert DeviceLinks.list_for_subject("owner") == []
  end

  test "ttl_seconds honors application config" do
    prev = Application.get_env(:dev_ide, :device_link_ttl_seconds)
    Application.put_env(:dev_ide, :device_link_ttl_seconds, 120)

    on_exit(fn -> restore(:device_link_ttl_seconds, prev) end)

    before = DateTime.utc_now()

    assert {:ok, %{link: link}} = DeviceLinks.create_from_pairing_claims(owner_claims(), %{})
    assert DateTime.diff(link.expires_at, before, :second) in 115..125
  end

  test "rotate_token mints a new credential and revokes the old atomically" do
    {:ok, %{token: old_token, link: old_link}} =
      DeviceLinks.create_from_pairing_claims(owner_claims(), %{"platform" => "ios"})

    assert {:ok, %{token: new_token, link: new_link}} = DeviceLinks.rotate_token(old_token)

    refute new_token == old_token
    refute new_link.id == old_link.id
    # Provenance carries over; old token is revoked, new one verifies.
    assert new_link.platform == "ios"
    assert new_link.resource_id == "ws-1"
    assert {:ok, %{workspace_id: "ws-1"}} = DeviceLinks.verify_token(new_token)
    assert {:error, :revoked} = DeviceLinks.verify_token(old_token)
    assert %Token{revoked_at: %DateTime{}} = Repo.get!(Token, old_link.id)
  end

  test "rotate_token refuses a revoked token" do
    {:ok, %{token: raw_token}} = DeviceLinks.create_from_pairing_claims(owner_claims())
    {:ok, _} = DeviceLinks.revoke_token(raw_token)

    assert {:error, :revoked} = DeviceLinks.rotate_token(raw_token)
  end

  test "rotate_token rejects an unknown token" do
    assert {:error, :invalid_token} = DeviceLinks.rotate_token("nope")
    assert {:error, :missing} = DeviceLinks.rotate_token("   ")
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
