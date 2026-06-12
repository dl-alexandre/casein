defmodule DevIDE.Deployment.DriftTest do
  use ExUnit.Case, async: true

  alias DevIDE.Deployment.Drift

  test "assess returns current when a short deployed SHA matches the remote head" do
    assert Drift.assess("1fb643a", {:ok, "1fb643af2c58da2c9b10019cc3de1b06555e3732"}, "master") ==
             :current
  end

  test "assess flags manual labels as deploy drift" do
    assert {:drift, %{reason: :manual_revision, current: "5b1dd81-terminal-handshake-hotfix"}} =
             Drift.assess(
               "5b1dd81-terminal-handshake-hotfix",
               {:ok, String.duplicate("a", 40)},
               "master"
             )
  end

  test "assess flags SHA mismatches as deploy drift" do
    assert {:drift, %{reason: :revision_differs, current: "1fb643a"}} =
             Drift.assess("1fb643a", {:ok, String.duplicate("b", 40)}, "master")
  end

  test "assess keeps remote lookup failures as unknown" do
    assert {:unknown, %{reason: :remote_lookup_failed}} =
             Drift.assess("1fb643a", {:error, :nxdomain}, "master")
  end
end
