defmodule Casein.UAT.VisualTest do
  use Casein.TestCase, async: true

  alias Casein.UAT.Visual

  defp tmp(content) do
    path = Path.join(System.tmp_dir!(), "uat-vis-#{System.unique_integer([:positive])}")
    File.write!(path, content)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  test "identical files match with distance 0.0" do
    a = tmp("samebytes")
    b = tmp("samebytes")
    assert {:ok, %{match: true, distance: +0.0}} = Visual.compare(a, b)
  end

  test "different files do not match at the default (exact) threshold" do
    a = tmp("aaaa")
    b = tmp("abba")
    assert {:ok, %{match: false, distance: distance}} = Visual.compare(a, b)
    assert distance > 0.0
  end

  test "a tolerant threshold accepts a small difference" do
    a = tmp("aaaa")
    b = tmp("aaab")
    assert {:ok, %{match: true}} = Visual.compare(a, b, threshold: 0.5)
  end

  test "a missing baseline is a non-match with reason, not an error" do
    a = tmp("x")
    assert {:ok, %{match: false, reason: :no_baseline}} = Visual.compare(a, "/no/such/baseline")
  end

  test "a missing actual is a non-match with reason" do
    b = tmp("x")
    assert {:ok, %{match: false, reason: :no_actual}} = Visual.compare(nil, b)
  end

  test "an injected differ is used" do
    a = tmp("x")
    b = tmp("y")
    differ = fn _actual, _baseline -> {:ok, 0.0} end
    assert {:ok, %{match: true, distance: +0.0}} = Visual.compare(a, b, differ: differ)
  end
end
