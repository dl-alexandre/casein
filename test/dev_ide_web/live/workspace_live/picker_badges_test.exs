defmodule DevIdeWeb.WorkspaceLive.PickerBadgesTest do
  use ExUnit.Case, async: true

  alias DevIdeWeb.WorkspaceLive.PickerBadges

  describe "mode_class/1" do
    test "maps local mode to green badge classes" do
      assert PickerBadges.mode_class(:local) ==
               "bg-green-50 text-green-700 border border-green-200"
    end

    test "maps remote mode to blue badge classes" do
      assert PickerBadges.mode_class(:remote) ==
               "bg-blue-50 text-blue-700 border border-blue-200"
    end

    test "falls through unknown modes to zinc badge classes" do
      assert PickerBadges.mode_class(:unknown) ==
               "bg-zinc-50 text-zinc-600 border border-zinc-200"

      assert PickerBadges.mode_class(nil) ==
               "bg-zinc-50 text-zinc-600 border border-zinc-200"
    end
  end

  describe "status_class/1" do
    test "maps running status to green text" do
      assert PickerBadges.status_class(:running) == "text-green-700"
    end

    test "maps stopped status to zinc text" do
      assert PickerBadges.status_class(:stopped) == "text-zinc-500"
    end

    test "falls through unknown statuses to amber text" do
      assert PickerBadges.status_class(:starting) == "text-amber-700"
      assert PickerBadges.status_class(nil) == "text-amber-700"
      assert PickerBadges.status_class(:error) == "text-amber-700"
    end
  end

  describe "session_agent_status/1" do
    test "returns binary agent_status from atom-key map" do
      assert PickerBadges.session_agent_status(%{agent_status: "running"}) == "running"
      assert PickerBadges.session_agent_status(%{agent_status: "attention"}) == "attention"
      assert PickerBadges.session_agent_status(%{agent_status: "done"}) == "done"
    end

    test "returns binary agent_status from string-key map" do
      assert PickerBadges.session_agent_status(%{"agent_status" => "running"}) == "running"
      assert PickerBadges.session_agent_status(%{"agent_status" => "attention"}) == "attention"
    end

    test "falls through empty, nil, and missing agent_status to nil" do
      assert PickerBadges.session_agent_status(%{agent_status: ""}) == nil
      assert PickerBadges.session_agent_status(%{"agent_status" => ""}) == nil
      assert PickerBadges.session_agent_status(%{agent_status: nil}) == nil
      assert PickerBadges.session_agent_status(%{}) == nil
      assert PickerBadges.session_agent_status(nil) == nil
      assert PickerBadges.session_agent_status(%{other: "running"}) == nil
    end
  end

  describe "workspace_agent_layout_status/1" do
    test "returns ready from atom-key agent_layout" do
      assert PickerBadges.workspace_agent_layout_status(%{
               agent_layout: %{status: "ready"}
             }) == "ready"
    end

    test "returns missing_agent_pane from atom-key agent_layout" do
      assert PickerBadges.workspace_agent_layout_status(%{
               agent_layout: %{status: "missing_agent_pane"}
             }) == "missing_agent_pane"
    end

    test "reads string keys for layout and status" do
      assert PickerBadges.workspace_agent_layout_status(%{
               "agent_layout" => %{"status" => "ready"}
             }) == "ready"

      assert PickerBadges.workspace_agent_layout_status(%{
               "agent_layout" => %{"status" => "missing_agent_pane"}
             }) == "missing_agent_pane"

      assert PickerBadges.workspace_agent_layout_status(%{
               agent_layout: %{"status" => "ready"}
             }) == "ready"
    end

    test "falls through empty maps, missing layout, and unknown status to nil" do
      assert PickerBadges.workspace_agent_layout_status(%{}) == nil
      assert PickerBadges.workspace_agent_layout_status(%{agent_layout: %{}}) == nil

      assert PickerBadges.workspace_agent_layout_status(%{agent_layout: %{status: "other"}}) ==
               nil

      assert PickerBadges.workspace_agent_layout_status(%{agent_layout: %{status: nil}}) == nil
      assert PickerBadges.workspace_agent_layout_status(%{"agent_layout" => nil}) == nil
    end
  end

  describe "workspace_agent_layout_label/1" do
    test "maps ready and missing_agent_pane to presentation labels" do
      assert PickerBadges.workspace_agent_layout_label("ready") == "agent ready"

      assert PickerBadges.workspace_agent_layout_label("missing_agent_pane") ==
               "agent pane missing"
    end
  end

  describe "workspace_agent_layout_icon/1" do
    test "maps ready and missing_agent_pane to hero icons" do
      assert PickerBadges.workspace_agent_layout_icon("ready") == "hero-check-circle"

      assert PickerBadges.workspace_agent_layout_icon("missing_agent_pane") ==
               "hero-exclamation-triangle"
    end
  end

  describe "workspace_agent_layout_class/1" do
    test "maps ready to emerald badge classes" do
      assert PickerBadges.workspace_agent_layout_class("ready") ==
               "inline-flex items-center gap-0.5 rounded border border-emerald-200 bg-emerald-50 px-1.5 py-0.5 text-[10px] font-medium text-emerald-700"
    end

    test "maps missing_agent_pane to amber badge classes" do
      assert PickerBadges.workspace_agent_layout_class("missing_agent_pane") ==
               "inline-flex items-center gap-0.5 rounded border border-amber-200 bg-amber-50 px-1.5 py-0.5 text-[10px] font-medium text-amber-800"
    end
  end

  describe "workspace_agent_layout_title/1" do
    test "includes suggested_template when present as atom key" do
      assert PickerBadges.workspace_agent_layout_title(%{
               agent_layout: %{suggested_template: "agent_pair"}
             }) == "Role-marked agent pane: agent_pair"
    end

    test "includes suggested_template when present as string key" do
      assert PickerBadges.workspace_agent_layout_title(%{
               "agent_layout" => %{"suggested_template" => "agent_pair"}
             }) == "Role-marked agent pane: agent_pair"
    end

    test "falls through empty, nil, and missing template to default title" do
      assert PickerBadges.workspace_agent_layout_title(%{}) == "Role-marked agent pane"

      assert PickerBadges.workspace_agent_layout_title(%{agent_layout: %{}}) ==
               "Role-marked agent pane"

      assert PickerBadges.workspace_agent_layout_title(%{
               agent_layout: %{suggested_template: ""}
             }) == "Role-marked agent pane"

      assert PickerBadges.workspace_agent_layout_title(%{
               agent_layout: %{suggested_template: nil}
             }) == "Role-marked agent pane"

      assert PickerBadges.workspace_agent_layout_title(%{"agent_layout" => nil}) ==
               "Role-marked agent pane"
    end
  end

  describe "session_agent_status_title/1" do
    test "prefers agent_title over title for atom keys" do
      assert PickerBadges.session_agent_status_title(%{
               agent_title: "Fix the badges",
               title: "ignored"
             }) == "Fix the badges"
    end

    test "falls back to title when agent_title is missing" do
      assert PickerBadges.session_agent_status_title(%{title: "Session title"}) ==
               "Session title"
    end

    test "reads string keys for agent_title and title" do
      assert PickerBadges.session_agent_status_title(%{"agent_title" => "String agent title"}) ==
               "String agent title"

      assert PickerBadges.session_agent_status_title(%{"title" => "String title"}) ==
               "String title"
    end

    test "falls through empty, nil, and missing titles to default" do
      assert PickerBadges.session_agent_status_title(%{}) == "Latest agent prompt status"

      assert PickerBadges.session_agent_status_title(%{agent_title: ""}) ==
               "Latest agent prompt status"

      assert PickerBadges.session_agent_status_title(%{title: ""}) == "Latest agent prompt status"

      assert PickerBadges.session_agent_status_title(%{agent_title: nil, title: nil}) ==
               "Latest agent prompt status"

      assert PickerBadges.session_agent_status_title(%{"agent_title" => "", "title" => ""}) ==
               "Latest agent prompt status"
    end
  end

  describe "agent_session_status_class/1" do
    test "maps attention (highest urgency) to red badge classes" do
      assert PickerBadges.agent_session_status_class("attention") ==
               "rounded border border-red-200 bg-red-50 px-1 py-0.5 text-[10px] font-medium text-red-700"
    end

    test "maps done to emerald badge classes" do
      assert PickerBadges.agent_session_status_class("done") ==
               "rounded border border-emerald-200 bg-emerald-50 px-1 py-0.5 text-[10px] font-medium text-emerald-700"
    end

    test "maps running to blue badge classes" do
      assert PickerBadges.agent_session_status_class("running") ==
               "rounded border border-blue-200 bg-blue-50 px-1 py-0.5 text-[10px] font-medium text-blue-700"
    end

    test "falls through unknown and empty status to zinc badge classes" do
      assert PickerBadges.agent_session_status_class("unknown") ==
               "rounded border border-zinc-200 bg-zinc-50 px-1 py-0.5 text-[10px] font-medium text-zinc-600"

      assert PickerBadges.agent_session_status_class(nil) ==
               "rounded border border-zinc-200 bg-zinc-50 px-1 py-0.5 text-[10px] font-medium text-zinc-600"

      assert PickerBadges.agent_session_status_class("") ==
               "rounded border border-zinc-200 bg-zinc-50 px-1 py-0.5 text-[10px] font-medium text-zinc-600"
    end
  end

  describe "session_share_url/1" do
    test "prefixes a non-empty href with the endpoint URL" do
      href = "/workspaces/ws-1/sessions/s-1"

      assert PickerBadges.session_share_url(href) == DevIdeWeb.Endpoint.url() <> href
    end

    test "builds absolute URL for root-relative paths" do
      assert PickerBadges.session_share_url("/workspaces/abc") ==
               DevIdeWeb.Endpoint.url() <> "/workspaces/abc"

      assert String.starts_with?(
               PickerBadges.session_share_url("/workspaces/abc"),
               "http"
             )
    end
  end
end
