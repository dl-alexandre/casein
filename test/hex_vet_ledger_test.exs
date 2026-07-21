defmodule HexVetLedgerTest do
  use ExUnit.Case, async: true

  @valid_criteria [:safe_to_deploy, :safe_to_run, :does_not_implement_crypto]

  test "hex_vet.exs has the deps-vet ledger shape and non-empty audits" do
    {ledger, _} = Code.eval_file("hex_vet.exs")

    assert %{
             imports: %{},
             audits: audits,
             policy: %{criteria_required: :safe_to_deploy}
           } = ledger

    assert is_list(audits)
    assert audits != []
  end

  test "every audit entry has required keys, valid criteria, version binary, and Date reviewed_at" do
    {ledger, _} = Code.eval_file("hex_vet.exs")
    audits = ledger.audits

    for entry <- audits do
      assert Map.has_key?(entry, :package)
      assert Map.has_key?(entry, :version)
      assert Map.has_key?(entry, :criteria)
      assert Map.has_key?(entry, :reviewer)
      assert Map.has_key?(entry, :notes)
      assert Map.has_key?(entry, :reviewed_at)

      assert entry.criteria in @valid_criteria
      assert is_binary(entry.version)
      assert match?(%Date{}, entry.reviewed_at)
    end
  end

  test "audited package versions match mix.lock (lock wins)" do
    {ledger, _} = Code.eval_file("hex_vet.exs")
    {lock, _} = Code.eval_file("mix.lock")

    locked_versions =
      Map.new(lock, fn {k, v} -> {to_string(k), elem(v, 2)} end)

    for entry <- ledger.audits do
      case Map.fetch(locked_versions, entry.package) do
        {:ok, locked_version} ->
          assert entry.version == locked_version,
                 "ledger version for #{entry.package} (#{entry.version}) does not match lock (#{locked_version})"

        :error ->
          :ok
      end
    end
  end
end
