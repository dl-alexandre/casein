defmodule DevIdeWeb.WorkspaceLive.Show.TmuxTemplateEventsTest do
  use DevIDE.TestCase, async: true

  alias DevIdeWeb.WorkspaceLive.Show.TmuxTemplateEvents

  # Pure assign-only clauses: close library, cancel edit/duplicate/preview,
  # apply_previewed without a preview.
  # SKIPPED (Show.apply_session_template / Terminals / refresh_saved_session_templates):
  # tmux:apply_template, preview_template, open_template_library, filter_saved_templates,
  # save/update/duplicate/delete saved templates, edit/duplicate start happy paths.

  defp socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            flash: %{},
            workspace: %{id: "ws-tmpl-#{System.unique_integer([:positive])}"},
            template_library_open: true,
            template_edit_id: "edit-1",
            template_duplicate_id: "dup-1",
            template_preview: %{template: %{id: "t1"}},
            template_tag_filter: "old",
            saved_session_templates: []
          },
          assigns
        )
    }
  end

  test "tmux:close_template_library closes the library and clears edit/duplicate forms" do
    s = socket()
    assert {:noreply, s2} = TmuxTemplateEvents.handle_event("tmux:close_template_library", %{}, s)

    assert s2.assigns.template_library_open == false
    assert s2.assigns.template_edit_id == nil
    assert s2.assigns.template_duplicate_id == nil
    assert is_struct(s2.assigns.template_edit_form, Phoenix.HTML.Form)
    assert is_struct(s2.assigns.template_duplicate_form, Phoenix.HTML.Form)
  end

  test "tmux:cancel_saved_template_edit clears the edit form" do
    s = socket(%{template_edit_id: "edit-9"})

    assert {:noreply, s2} =
             TmuxTemplateEvents.handle_event("tmux:cancel_saved_template_edit", %{}, s)

    assert s2.assigns.template_edit_id == nil
    assert is_struct(s2.assigns.template_edit_form, Phoenix.HTML.Form)
  end

  test "tmux:cancel_saved_template_duplicate clears the duplicate form" do
    s = socket(%{template_duplicate_id: "dup-9"})

    assert {:noreply, s2} =
             TmuxTemplateEvents.handle_event("tmux:cancel_saved_template_duplicate", %{}, s)

    assert s2.assigns.template_duplicate_id == nil
    assert is_struct(s2.assigns.template_duplicate_form, Phoenix.HTML.Form)
  end

  test "tmux:cancel_template_preview clears the preview assign" do
    s = socket(%{template_preview: %{template: %{id: "t1"}}})

    assert {:noreply, s2} =
             TmuxTemplateEvents.handle_event("tmux:cancel_template_preview", %{}, s)

    assert s2.assigns.template_preview == nil
  end

  test "tmux:apply_previewed_template without a preview clears the assign" do
    s = socket(%{template_preview: nil})

    assert {:noreply, s2} =
             TmuxTemplateEvents.handle_event("tmux:apply_previewed_template", %{}, s)

    assert s2.assigns.template_preview == nil
  end

  test "tmux:apply_previewed_template with a non-map preview clears the assign" do
    s = socket(%{template_preview: :stale})

    assert {:noreply, s2} =
             TmuxTemplateEvents.handle_event(
               "tmux:apply_previewed_template",
               %{"mode" => "exact"},
               s
             )

    assert s2.assigns.template_preview == nil
  end
end
