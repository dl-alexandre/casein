defmodule Casein.UAT.MatcherTest do
  use Casein.TestCase, async: true

  alias Casein.UAT.Matcher

  defp elements do
    [
      %{element_id: "el_1", selector: "button[type=submit]", role: "button", name: "Submit"},
      %{element_id: "el_2", selector: "button[type=submit]", role: "button", name: "Cancel"},
      %{element_id: "el_3", selector: "input[name=q]", role: "textbox", name: "Search"}
    ]
  end

  test "resolves a unique selector" do
    assert {:ok, %{element_id: "el_3"}} =
             Matcher.resolve(elements(), %{"selector" => "input[name=q]"})
  end

  test "narrows an ambiguous selector by name" do
    assert {:ok, %{element_id: "el_2"}} =
             Matcher.resolve(elements(), %{
               "selector" => "button[type=submit]",
               "name" => "Cancel"
             })
  end

  test "narrows by role then disambiguates with nth" do
    assert {:ok, %{element_id: "el_1"}} =
             Matcher.resolve(elements(), %{
               "selector" => "button[type=submit]",
               "role" => "button",
               "nth" => 0
             })
  end

  test "a vanished selector is :no_match (treated as drift by the caller)" do
    assert {:error, :no_match} =
             Matcher.resolve(elements(), %{"selector" => "button[name=ghost]"})
  end

  test "several matches with no nth is :ambiguous" do
    assert {:error, :ambiguous} =
             Matcher.resolve(elements(), %{"selector" => "button[type=submit]"})
  end

  test "an out-of-range nth is :no_match" do
    assert {:error, :no_match} =
             Matcher.resolve(elements(), %{"selector" => "button[type=submit]", "nth" => 9})
  end

  test "tolerates string-keyed element maps" do
    string_keyed = [%{"selector" => "#only", "role" => "link", "name" => "Home"}]

    assert {:ok, %{"selector" => "#only"}} =
             Matcher.resolve(string_keyed, %{"selector" => "#only"})
  end
end
