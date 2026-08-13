defmodule HexVetLedgerTest do
  use ExUnit.Case, async: true

  @valid_criteria [:safe_to_deploy, :safe_to_run, :does_not_implement_crypto]

  test "hex_vet.exs has the deps-vet ledger shape and non-empty audits" do
    {ledger, _} = Code.eval_file("hex_vet.exs")

    assert %{
             imports: %{},
             audits: audits,
             grandfathered: grandfathered,
             policy: %{criteria_required: :safe_to_deploy, block_on_unvetted: :new_only}
           } = ledger

    assert is_list(audits)
    assert audits != []
    assert is_list(grandfathered)
    assert grandfathered != []
    assert Enum.all?(grandfathered, &is_binary/1)
    assert grandfathered == Enum.sort(grandfathered)
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
    locked_versions = locked_versions()

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

  test "audited packages are not also grandfathered" do
    {ledger, _} = Code.eval_file("hex_vet.exs")
    audited = MapSet.new(Enum.map(ledger.audits, & &1.package))
    grandfathered = MapSet.new(ledger.grandfathered)
    overlap = MapSet.intersection(audited, grandfathered)

    assert MapSet.size(overlap) == 0,
           "packages must be audited or grandfathered, not both: #{inspect(MapSet.to_list(overlap))}"
  end

  test "every mix.lock package is audited or explicitly grandfathered" do
    {ledger, _} = Code.eval_file("hex_vet.exs")
    names = lock_package_names()

    assert unclassified(names, ledger) == [], """
    #936: mix.lock has packages that are neither audited nor grandfathered.
    Vet them in hex_vet.exs audits (do not grow grandfathered).

    #{Enum.join(unclassified(names, ledger), "\n")}
    """
  end

  test "a lock package that is neither audited nor grandfathered is unclassified" do
    {ledger, _} = Code.eval_file("hex_vet.exs")
    assert unclassified(["brand_new_dep"], ledger) == ["brand_new_dep"]
    assert unclassified(["file_system"], ledger) == []
    assert unclassified(["phoenix"], ledger) == []
  end

  test "single-author NIF chain is audited, not grandfathered" do
    {ledger, _} = Code.eval_file("hex_vet.exs")
    audited = MapSet.new(Enum.map(ledger.audits, & &1.package))
    grandfathered = MapSet.new(ledger.grandfathered)

    for package <- ["ghostty", "zigler_precompiled", "boxart", "oxc"] do
      assert package in audited, "#{package} must be in audits"
      refute package in grandfathered, "#{package} must not be grandfathered"
    end
  end

  defp unclassified(lock_names, ledger) do
    known =
      ledger.audits
      |> Enum.map(& &1.package)
      |> Kernel.++(ledger.grandfathered)
      |> MapSet.new()

    Enum.reject(lock_names, &MapSet.member?(known, &1))
  end

  defp lock_package_names do
    locked_versions()
    |> Map.keys()
    |> Enum.sort()
  end

  defp locked_versions do
    {lock, _} = Code.eval_file("mix.lock")
    Map.new(lock, fn {k, v} -> {to_string(k), elem(v, 2)} end)
  end
end
