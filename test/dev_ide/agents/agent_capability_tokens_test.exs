defmodule DevIDE.Agents.AgentCapabilityTokensTest do
  use DevIDE.DataCase, async: false

  alias DevIDE.Agents.AgentCapabilityToken
  alias DevIDE.Agents.AgentCapabilityTokens
  alias DevIDE.Repo

  @leader_id "0123456789abcdef01234567"
  @bundle_digest String.duplicate("a", 64)
  @checkout_digest String.duplicate("b", 64)

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        workspace_id: "workspace-123",
        runtime: "grok",
        tmux_session_id: "devide_workspace-123_agent-7",
        pane_id: "%7",
        leader_id: @leader_id,
        bundle_digest: @bundle_digest,
        workspace_mode: "manual",
        allowed_tools: %{
          "terminal" => ["terminal_capture", "terminal_report_agent_state"],
          "preview" => ["preview_screenshot"]
        },
        checkout_digest: @checkout_digest
      },
      overrides
    )
  end

  test "mints a hash-at-rest token and verifies only safe frozen claims" do
    assert {:ok, raw, record} = AgentCapabilityTokens.create_for_grok(attrs())

    assert String.starts_with?(raw, "grokcap_")
    refute raw == record.token_hash
    assert record.token_hash == AgentCapabilityTokens.token_hash(raw)
    refute Repo.get_by(AgentCapabilityToken, token_hash: raw)
    assert record.workspace_id == "workspace-123"
    assert %DateTime{} = record.expires_at
    assert DateTime.compare(record.expires_at, DateTime.utc_now()) == :gt

    assert {:ok, claims} = AgentCapabilityTokens.verify(raw)

    assert Map.keys(claims) |> Enum.sort() ==
             ~w(allowed_tools bundle_digest checkout_digest expires_at id leader_id pane_id runtime tmux_session_id workspace_id workspace_mode)a
             |> Enum.sort()

    assert claims.id == record.id
    assert claims.workspace_id == "workspace-123"
    assert claims.runtime == "grok"
    assert claims.tmux_session_id == "devide_workspace-123_agent-7"
    assert claims.pane_id == "%7"
    assert claims.leader_id == @leader_id
    assert claims.bundle_digest == @bundle_digest
    assert claims.workspace_mode == "manual"
    assert claims.allowed_tools == record.allowed_tools
    assert claims.checkout_digest == @checkout_digest

    assert %AgentCapabilityToken{last_seen_at: %DateTime{}} =
             Repo.get!(AgentCapabilityToken, record.id)
  end

  test "uses a configurable TTL with a twelve-hour default" do
    original = Application.get_env(:dev_ide, :grok_agent_capability_token_ttl_seconds)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:dev_ide, :grok_agent_capability_token_ttl_seconds)
      else
        Application.put_env(:dev_ide, :grok_agent_capability_token_ttl_seconds, original)
      end
    end)

    Application.delete_env(:dev_ide, :grok_agent_capability_token_ttl_seconds)
    assert AgentCapabilityTokens.ttl_seconds() == 12 * 60 * 60

    Application.put_env(:dev_ide, :grok_agent_capability_token_ttl_seconds, 90)
    assert AgentCapabilityTokens.ttl_seconds() == 90

    assert {:ok, _raw, record} = AgentCapabilityTokens.create_for_grok(attrs())
    remaining = DateTime.diff(record.expires_at, DateTime.utc_now(), :second)
    assert remaining in 89..90

    Application.put_env(:dev_ide, :grok_agent_capability_token_ttl_seconds, 0)
    assert AgentCapabilityTokens.ttl_seconds() == 12 * 60 * 60
  end

  test "verify rejects missing, unknown, revoked, and expired tokens" do
    assert {:error, :missing} = AgentCapabilityTokens.verify("")
    assert {:error, :missing} = AgentCapabilityTokens.verify(nil)
    assert {:error, :invalid_token} = AgentCapabilityTokens.verify("not-a-capability")

    {:ok, raw, record} = AgentCapabilityTokens.create_for_grok(attrs())
    assert {:ok, _record} = AgentCapabilityTokens.revoke(record.id, record.workspace_id)
    assert {:error, :revoked} = AgentCapabilityTokens.verify(raw)

    {:ok, raw2, record2} = AgentCapabilityTokens.create_for_grok(attrs())

    record2
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:error, :expired} = AgentCapabilityTokens.verify(raw2)
  end

  test "workspace-scoped and current-token revocation are idempotent" do
    {:ok, raw, record} = AgentCapabilityTokens.create_for_grok(attrs())

    assert {:error, :not_found} = AgentCapabilityTokens.revoke(record.id, "another-workspace")
    assert {:ok, first} = AgentCapabilityTokens.revoke_current(record.id)
    assert %DateTime{} = first.revoked_at
    assert {:ok, second} = AgentCapabilityTokens.revoke_current(record.id)
    assert second.revoked_at == first.revoked_at
    assert {:error, :revoked} = AgentCapabilityTokens.verify(raw)
    assert {:error, :not_found} = AgentCapabilityTokens.revoke_current(Ecto.UUID.generate())
    assert {:error, :not_found} = AgentCapabilityTokens.revoke_current("bogus")
    assert {:error, :not_found} = AgentCapabilityTokens.revoke("bogus", record.workspace_id)
  end

  test "minting a replacement revokes the prior live binding" do
    {:ok, first_raw, first} = AgentCapabilityTokens.create_for_grok(attrs())
    {:ok, second_raw, second} = AgentCapabilityTokens.create_for_grok(attrs())

    refute first.id == second.id
    assert {:error, :revoked} = AgentCapabilityTokens.verify(first_raw)
    assert {:ok, %{id: id}} = AgentCapabilityTokens.verify(second_raw)
    assert id == second.id
  end

  test "fails closed on invalid identifiers, digests, modes, runtimes, and tool grants" do
    invalid = [
      %{workspace_id: "../workspace"},
      %{tmux_session_id: "session/escape"},
      %{pane_id: "7"},
      %{leader_id: String.duplicate("A", 24)},
      %{bundle_digest: "sha256-" <> @bundle_digest},
      %{checkout_digest: "short"},
      %{workspace_mode: "trusted"},
      %{runtime: "claude"},
      %{allowed_tools: %{}},
      %{allowed_tools: %{terminal: ["terminal_capture"]}},
      %{allowed_tools: %{"unknown" => ["terminal_capture"]}},
      %{allowed_tools: %{"terminal" => []}},
      %{allowed_tools: %{"terminal" => ["terminal_capture", "terminal_capture"]}},
      %{allowed_tools: %{"terminal" => ["bad/tool"]}},
      %{allowed_tools: %{"terminal" => Enum.map(1..129, &"tool_#{&1}")}}
    ]

    Enum.each(invalid, fn override ->
      assert {:error, %Ecto.Changeset{valid?: false}} =
               AgentCapabilityTokens.create_for_grok(attrs(override))
    end)

    assert {:ok, _raw, _record} =
             AgentCapabilityTokens.create_for_grok(Map.put(attrs(), :unexpected, true))
  end

  test "prunes expired and revoked records without deleting active capabilities" do
    {:ok, _active_raw, active} = AgentCapabilityTokens.create_for_grok(attrs())

    {:ok, _revoked_raw, revoked} =
      AgentCapabilityTokens.create_for_grok(
        attrs(%{pane_id: "%8", leader_id: String.duplicate("1", 24)})
      )

    {:ok, _expired_raw, expired} =
      AgentCapabilityTokens.create_for_grok(
        attrs(%{pane_id: "%9", leader_id: String.duplicate("2", 24)})
      )

    assert {:ok, _} = AgentCapabilityTokens.revoke_current(revoked.id)

    expired
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert AgentCapabilityTokens.prune_stale() == 2
    assert Repo.get(AgentCapabilityToken, active.id)
    refute Repo.get(AgentCapabilityToken, revoked.id)
    refute Repo.get(AgentCapabilityToken, expired.id)
  end
end
