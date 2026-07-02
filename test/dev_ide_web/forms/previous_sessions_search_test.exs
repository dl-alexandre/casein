defmodule DevIdeWeb.Forms.PreviousSessionsSearchTest do
  use DevIDE.TestCase, async: true

  alias DevIdeWeb.Forms.PreviousSessionsSearch

  test "normalizes URL aliases and clamps limit" do
    changeset =
      PreviousSessionsSearch.from_params(%{
        "q" => "  phoenix ",
        "workspace_id" => "alpha",
        "sources" => "activity",
        "limit" => "99"
      })

    filters = PreviousSessionsSearch.to_filters(changeset)

    assert filters.query == "phoenix"
    assert filters.workspace == "alpha"
    assert filters.source == "activity"
    assert filters.limit == 20
  end

  test "accepts valid limit values" do
    changeset = PreviousSessionsSearch.from_params(%{"limit" => "10"})
    assert PreviousSessionsSearch.to_filters(changeset).limit == 10
  end

  test "search_opts stringifies limit for the export layer" do
    changeset = PreviousSessionsSearch.from_params(%{"limit" => "50"})
    filters = PreviousSessionsSearch.to_filters(changeset)

    assert PreviousSessionsSearch.search_opts(filters)[:limit] == "50"
  end
end
