defmodule CaseinWeb.WorkspaceLive.Show.LogsPanelTest do
  use Casein.TestCase, async: true

  import Phoenix.LiveViewTest

  alias CaseinWeb.WorkspaceLive.Show.LogsPanel

  defp log_streams(lines) do
    %{
      log_lines: Phoenix.LiveView.LiveStream.new(:log_lines, make_ref(), lines, [])
    }
  end

  describe "logs_panel/1" do
    test "renders service input and local-unavailable message when log_ref is nil" do
      html =
        render_component(&LogsPanel.logs_panel/1,
          log_service: "web",
          log_ref: nil,
          streams: log_streams([])
        )

      assert html =~ ~s(name="service")
      assert html =~ ~s(value="web")

      assert html =~
               ~r/(Log streaming is not available for local filesystem workspaces|Log stream unavailable)/

      assert html =~ ~s(id="log-lines")
    end

    test "renders stream entries when log_ref is set" do
      html =
        render_component(&LogsPanel.logs_panel/1,
          log_service: "api",
          log_ref: make_ref(),
          streams:
            log_streams([
              %{id: "log-1", text: "boot complete"},
              %{id: "log-2", text: "listening on :4000"}
            ])
        )

      refute html =~ "Log streaming is not available"
      assert html =~ ~s(id="log-lines")
      assert html =~ "boot complete"
      assert html =~ "listening on :4000"
    end
  end
end
