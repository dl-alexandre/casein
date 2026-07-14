defmodule DevIDE.Agents.OrchestratorTokensTest do
  use DevIde.DataCase, async: false

  alias DevIDE.Agents.OrchestratorToken
  alias DevIDE.Agents.OrchestratorTokens
  alias DevIde.Repo

  defp user(id \\ "alice"),
    do: %{id: id, username: id, email: "#{id}@example.com", role: :user}

  test "mints a hashed token, returns raw once, and verifies claims" do
    assert {:ok, raw, record} = OrchestratorTokens.create_for_subject(user(), label: "laptop")

    # hash-at-rest: raw is never stored
    refute raw == record.token_hash
    assert record.token_hash == OrchestratorTokens.token_hash(raw)
    assert record.subject_id == "alice"
    assert record.subject_email == "alice@example.com"
    assert record.subject_role == "user"
    assert record.label == "laptop"
    assert %DateTime{} = record.expires_at
    assert DateTime.compare(record.expires_at, DateTime.utc_now()) == :gt

    assert {:ok, claims} = OrchestratorTokens.verify(raw)
    assert claims.subject_id == "alice"
    assert claims.subject_email == "alice@example.com"

    # verify touches last_seen_at
    assert %OrchestratorToken{last_seen_at: %DateTime{}} = Repo.get!(OrchestratorToken, record.id)
  end

  test "verify rejects unknown, empty, revoked, and expired tokens" do
    assert {:error, :missing} = OrchestratorTokens.verify("")
    assert {:error, :invalid_token} = OrchestratorTokens.verify("nope-not-a-real-token")

    {:ok, raw, record} = OrchestratorTokens.create_for_subject(user())
    {:ok, _} = OrchestratorTokens.revoke(record.id, user())
    assert {:error, :revoked} = OrchestratorTokens.verify(raw)

    {:ok, raw2, record2} = OrchestratorTokens.create_for_subject(user())

    record2
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
    |> Repo.update!()

    assert {:error, :expired} = OrchestratorTokens.verify(raw2)
  end

  test "list and revoke are scoped to the subject" do
    {:ok, _raw_a, rec_a} = OrchestratorTokens.create_for_subject(user("alice"), label: "a")
    {:ok, _raw_b, _rec_b} = OrchestratorTokens.create_for_subject(user("bob"), label: "b")

    assert [%OrchestratorToken{label: "a"}] = OrchestratorTokens.list_for_subject("alice")

    # bob cannot revoke alice's token
    assert {:error, :not_found} = OrchestratorTokens.revoke(rec_a.id, user("bob"))
    assert [%OrchestratorToken{}] = OrchestratorTokens.list_for_subject("alice")

    # alice can, and it drops from her active list
    assert {:ok, _} = OrchestratorTokens.revoke(rec_a.id, user("alice"))
    assert [] = OrchestratorTokens.list_for_subject("alice")
  end
end
