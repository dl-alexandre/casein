defmodule DevIDE.DeviceLinks.ReaperTest do
  use DevIde.DataCase, async: false

  alias DevIDE.DeviceLinks
  alias DevIDE.DeviceLinks.Reaper
  alias DevIDE.DeviceLinks.Token
  alias DevIDE.Workspace
  alias DevIde.Repo

  defmodule OwnedSource do
    def get(id, _auth),
      do: {:ok, %Workspace{id: id, name: "Workspace #{id}", user: "owner", status: :running}}
  end

  setup do
    prev_source = Application.get_env(:dev_ide, :workspace_source)
    Application.put_env(:dev_ide, :workspace_source, OwnedSource)
    _ = Reaper
    on_exit(fn -> restore(:workspace_source, prev_source) end)
    :ok
  end

  test "sweep_now deletes expired and revoked rows past retention grace" do
    now = DateTime.utc_now()
    old = DateTime.add(now, -40 * 24 * 60 * 60, :second)

    {:ok, %{link: live}} =
      DeviceLinks.create_from_pairing_claims(owner_claims(), %{})

    expired =
      insert_token(%{
        subject_id: "owner",
        token_hash: "expired-hash",
        expires_at: old
      })

    revoked =
      insert_token(%{
        subject_id: "owner",
        token_hash: "revoked-hash",
        revoked_at: old,
        expires_at: DateTime.add(now, 60, :day)
      })

    assert Reaper.sweep_now() == 2

    assert Repo.get(Token, live.id)
    refute Repo.get(Token, expired.id)
    refute Repo.get(Token, revoked.id)
  end

  defp insert_token(attrs) do
    defaults = %{
      origin_id: "dev_ide",
      origin_name: "DevIDE",
      subject_id: "owner",
      subject_role: "owner",
      token_hash: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      resource_kind: "workspace",
      resource_id: "ws-1",
      capabilities: ["dev_ide.session"]
    }

    %Token{}
    |> Token.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
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
