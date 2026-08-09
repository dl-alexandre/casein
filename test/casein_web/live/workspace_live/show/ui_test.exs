defmodule CaseinWeb.WorkspaceLive.Show.UITest do
  use Casein.TestCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias CaseinWeb.WorkspaceLive.Show.UI

  describe "workspace_short_name/1" do
    test "drops the redundant owner prefix from owner/repo names" do
      assert UI.workspace_short_name("dalexandre/casein") == "casein"
    end

    test "leaves a bare name untouched" do
      assert UI.workspace_short_name("casein") == "casein"
    end

    test "takes the final segment of a deep path and ignores a trailing slash" do
      assert UI.workspace_short_name("a/b/c/") == "c"
    end

    test "passes through non-binary names" do
      assert UI.workspace_short_name(nil) == nil
    end
  end

  describe "panel_state/1" do
    defp render_state(kind, overrides \\ %{}) do
      assigns =
        Map.merge(
          %{
            id: "state-#{kind}",
            kind: kind,
            title: nil,
            message: "#{kind} message",
            action_label: nil,
            action_event: nil,
            action_values: %{},
            class: nil
          },
          Map.new(overrides)
        )

      rendered_to_string(~H"""
      <UI.panel_state
        id={@id}
        kind={@kind}
        title={@title}
        message={@message}
        action_label={@action_label}
        action_event={@action_event}
        action_values={@action_values}
        class={@class}
      />
      """)
    end

    test "empty, degraded, and error never share role or data-panel-state" do
      empty = render_state(:empty)
      degraded = render_state(:degraded)
      error = render_state(:error)

      assert empty =~ ~s(data-panel-state="empty")
      assert empty =~ ~s(role="status")
      refute empty =~ ~s(role="alert")

      assert degraded =~ ~s(data-panel-state="degraded")
      assert degraded =~ ~s(role="status")
      refute degraded =~ ~s(role="alert")

      assert error =~ ~s(data-panel-state="error")
      assert error =~ ~s(role="alert")
    end

    test "error can name a fix via action_label/event" do
      html =
        render_state(:error,
          title: "Could not load runs",
          message: "ledger unavailable",
          action_label: "Retry",
          action_event: "run_ledger:refresh"
        )

      assert html =~ "Could not load runs"
      assert html =~ "ledger unavailable"
      assert html =~ ~s(phx-click="run_ledger:refresh")
      assert html =~ "Retry"
    end
  end
end
