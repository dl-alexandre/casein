defmodule Casein.UAT.ManifestTest do
  use Casein.TestCase, async: true

  alias Casein.UAT.Manifest

  defp base(overrides \\ %{}) do
    Map.merge(
      %{
        "scenario_id" => "checkout",
        "identity" => "uat-owner@example.com",
        "seed_cmd" => "mix run priv/uat/seeds/checkout.exs",
        "tiers" => ["tier_a", "tier_b"]
      },
      overrides
    )
  end

  test "parses tiers into atoms and validates a complete manifest" do
    m = Manifest.from_map(base())
    assert m.tiers == [:tier_a, :tier_b]
    assert Manifest.validate(m) == :ok
    assert Manifest.tier_eligible?(m, :tier_a)
    assert Manifest.tier_eligible?(m, :tier_b)
  end

  test "defaults tiers to [:tier_a] when omitted" do
    m = Manifest.from_map(base() |> Map.delete("tiers"))
    assert m.tiers == [:tier_a]
  end

  test "a tier_a scenario without a seed_cmd fails the determinism contract" do
    m = Manifest.from_map(base(%{"seed_cmd" => nil}))
    assert {:error, errors} = Manifest.validate(m)
    assert Enum.any?(errors, &(&1 =~ "seed_cmd"))
  end

  test "a tier_b-only scenario needs no seed_cmd" do
    m = Manifest.from_map(base(%{"tiers" => ["tier_b"], "seed_cmd" => nil}))
    assert Manifest.validate(m) == :ok
    refute Manifest.tier_eligible?(m, :tier_a)
    assert Manifest.tier_eligible?(m, :tier_b)
  end

  test "rejects an unknown tier" do
    m = Manifest.from_map(base(%{"tiers" => ["tier_a", "tier_c"]}))
    assert {:error, errors} = Manifest.validate(m)
    assert Enum.any?(errors, &(&1 =~ "invalid tiers"))
  end

  test "requires a scenario_id" do
    m = Manifest.from_map(base(%{"scenario_id" => ""}))
    assert {:error, errors} = Manifest.validate(m)
    assert Enum.any?(errors, &(&1 =~ "scenario_id"))
  end

  test "rejects a scenario_id with path-traversal characters" do
    m = Manifest.from_map(base(%{"scenario_id" => "../../etc/passwd"}))
    assert {:error, errors} = Manifest.validate(m)
    assert Enum.any?(errors, &(&1 =~ "scenario_id must match"))
  end

  test "rejects a fixtures_dir that can escape the scenario directory" do
    m = Manifest.from_map(base(%{"fixtures_dir" => "../outside"}))
    assert {:error, errors} = Manifest.validate(m)
    assert Enum.any?(errors, &(&1 =~ "fixtures_dir must be a relative path"))
  end

  test "loads and validates the committed checkout reference manifest" do
    path = Application.app_dir(:dev_ide, "priv/uat/checkout/manifest.json")
    assert {:ok, m} = Manifest.load(path)
    assert m.scenario_id == "checkout"
    assert :tier_a in m.tiers
  end
end
