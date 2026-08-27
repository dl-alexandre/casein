defmodule Casein.Agents.JidoWorkcell.GitLedgerTest do
  use ExUnit.Case, async: false

  alias Casein.Agents.JidoWorkcell.Git.Ledger
  alias Casein.Agents.JidoWorkcell.Receipt

  @head_sha String.duplicate("a", 40)
  @other_head_sha String.duplicate("c", 40)

  test "replays the handoff key but rejects a new SHA or fingerprint" do
    handoff_id = "handoff-ledger-#{System.unique_integer([:positive])}"
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    receipt = %{
      git: %{head_sha: @head_sha},
      idempotency: %{handoff_key: Receipt.idempotency_key(handoff_id, @head_sha)}
    }

    assert {:ok, ^receipt} =
             Ledger.run(handoff_id, :fingerprint, nil, fn ->
               Agent.update(counter, &(&1 + 1))
               {:ok, receipt}
             end)

    assert {:ok, ^receipt} =
             Ledger.run(handoff_id, :fingerprint, nil, fn ->
               Agent.update(counter, &(&1 + 1))
               {:ok, receipt}
             end)

    assert Agent.get(counter, & &1) == 1

    assert {:error, :reused_handoff_new_sha} =
             Ledger.run(handoff_id, :fingerprint, @other_head_sha, fn -> {:ok, receipt} end)

    assert {:error, :idempotency_mismatch} =
             Ledger.run(handoff_id, :different_fingerprint, nil, fn -> {:ok, receipt} end)
  end

  test "a failed or blocked attempt does not consume the handoff id" do
    handoff_id = "handoff-ledger-retry-#{System.unique_integer([:positive])}"
    fingerprint = {:fingerprint, System.unique_integer([:positive])}

    receipt = %{
      git: %{head_sha: @head_sha},
      idempotency: %{handoff_key: Receipt.idempotency_key(handoff_id, @head_sha)}
    }

    assert {:error, :blocked} =
             Ledger.run(handoff_id, fingerprint, nil, fn -> {:error, :blocked} end)

    assert {:ok, ^receipt} = Ledger.run(handoff_id, fingerprint, nil, fn -> {:ok, receipt} end)
  end

  test "a malformed receipt is never stored as a replay" do
    handoff_id = "handoff-ledger-invalid-#{System.unique_integer([:positive])}"
    fingerprint = {:fingerprint, System.unique_integer([:positive])}
    invalid = %{git: %{head_sha: @head_sha}, idempotency: %{handoff_key: "wrong"}}

    valid = %{
      git: %{head_sha: @head_sha},
      idempotency: %{handoff_key: Receipt.idempotency_key(handoff_id, @head_sha)}
    }

    assert {:error, :idempotency_mismatch} =
             Ledger.run(handoff_id, fingerprint, nil, fn -> {:ok, invalid} end)

    assert {:ok, ^valid} = Ledger.run(handoff_id, fingerprint, nil, fn -> {:ok, valid} end)
  end
end
