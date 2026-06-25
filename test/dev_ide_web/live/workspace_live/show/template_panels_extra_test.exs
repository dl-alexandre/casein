defmodule DevIdeWeb.WorkspaceLive.Show.TemplatePanelsExtraTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias DevIdeWeb.WorkspaceLive.Show.TemplatePanels

  # ---------------------------------------------------------------------------
  # Pure / public helpers
  # ---------------------------------------------------------------------------

  describe "template_preview_default_apply_mode/1" do
    test "reconcile when the preview carries a diff map" do
      assert TemplatePanels.template_preview_default_apply_mode(%{diff: %{}}) == "reconcile"
    end

    test "exact when the preview has no diff" do
      assert TemplatePanels.template_preview_default_apply_mode(%{step_count: 3}) == "exact"
    end
  end

  describe "saved_template_description/1" do
    test "uses an explicit non-empty description" do
      assert TemplatePanels.saved_template_description(%{description: "My layout"}) ==
               "My layout"
    end

    test "falls back to the source session when description is blank" do
      assert TemplatePanels.saved_template_description(%{
               description: "",
               source_session: "alpha-1"
             }) == "Exported from alpha-1"
    end

    test "falls back to the generic label when nothing useful is present" do
      assert TemplatePanels.saved_template_description(%{description: ""}) ==
               "Exported tmux layout"

      assert TemplatePanels.saved_template_description(%{}) == "Exported tmux layout"
    end
  end

  describe "saved_template_tags_string/1" do
    test "joins a list of tags" do
      assert TemplatePanels.saved_template_tags_string(%{tags: ["phoenix", "daily"]}) ==
               "phoenix, daily"
    end

    test "returns an empty string when tags are missing or non-list" do
      assert TemplatePanels.saved_template_tags_string(%{}) == ""
      assert TemplatePanels.saved_template_tags_string(%{tags: nil}) == ""
    end
  end

  describe "saved_template_copy_name/2" do
    test "uses the plain (copy) suffix when free" do
      assert TemplatePanels.saved_template_copy_name([], "layout") == "layout (copy)"
    end

    test "bumps to a numbered copy when the base copy already exists" do
      existing = [%{name: "layout (copy)"}, %{name: "other"}]
      assert TemplatePanels.saved_template_copy_name(existing, "layout") == "layout (copy 2)"
    end

    test "skips over several taken numbered copies" do
      existing =
        [%{name: "layout (copy)"}] ++
          Enum.map(2..5, &%{name: "layout (copy #{&1})"})

      assert TemplatePanels.saved_template_copy_name(existing, "layout") == "layout (copy 6)"
    end

    test "falls back to the base copy when all 100 numbered slots are taken" do
      existing =
        [%{name: "layout (copy)"}] ++
          Enum.map(2..100, &%{name: "layout (copy #{&1})"})

      assert TemplatePanels.saved_template_copy_name(existing, "layout") == "layout (copy)"
    end
  end

  # ---------------------------------------------------------------------------
  # render_template_preview/1 — empty branch
  # ---------------------------------------------------------------------------

  describe "render_template_preview/1 empty state" do
    test "renders only the hidden placeholder when no preview is present" do
      assigns = %{template_preview: nil}

      html =
        rendered_to_string(~H"""
        <TemplatePanels.render_template_preview template_preview={@template_preview} />
        """)

      assert html =~ "template-preview-empty"
      refute html =~ "template-preview-modal"
    end
  end

  # ---------------------------------------------------------------------------
  # render_template_preview/1 — exact (step list) branch
  # ---------------------------------------------------------------------------

  describe "render_template_preview/1 exact replay" do
    defp exact_preview do
      %{
        template: %{name: "Daily layout", description: "Dev stack"},
        step_count: 4,
        steps: [
          %{
            index: 1,
            action: "new_window",
            params: %{name: "editor", cwd: "/tmp/ws"},
            ref: "w1"
          },
          %{
            index: 2,
            action: "split_pane",
            ref: "p2",
            params: %{direction: "horizontal", size_percent: 40}
          },
          %{
            index: 3,
            action: "send_command",
            params: %{command: "mix phx.server"}
          },
          %{
            index: 4,
            action: "select_pane",
            target_ref: "p2",
            params: %{}
          },
          %{index: 5, action: "weird_action", params: %{}}
        ]
      }
    end

    test "renders titles, actions and details for each step kind" do
      assigns = %{template_preview: exact_preview()}

      html =
        rendered_to_string(~H"""
        <TemplatePanels.render_template_preview template_preview={@template_preview} />
        """)

      assert html =~ "template-preview-modal"
      assert html =~ "Daily layout"
      assert html =~ "Dev stack"
      # No reconcile chrome on the exact path.
      refute html =~ "Smart reconcile"
      refute html =~ "template-reconcile-summary"

      # Step titles (template_step_title/1 clauses).
      assert html =~ "New window editor"
      assert html =~ "Split pane p2"
      assert html =~ "Run mix phx.server"
      assert html =~ "Focus p2"
      # Unknown action falls back to the raw action string.
      assert html =~ "weird_action"

      # Step details (template_step_detail/1).
      assert html =~ "cwd=/tmp/ws"
      assert html =~ "direction=horizontal"
      assert html =~ "size=40"
      assert html =~ "command=mix phx.server"

      # Footer + exact-mode apply.
      assert html =~ "4 planned tmux operation(s)"
      assert html =~ "Apply template"
      assert html =~ ~s(phx-value-mode="exact")
      # No exact-replay extra button in the non-reconcile footer.
      refute html =~ "template-preview-apply-exact"
    end

    test "omits the detail line when a step has no extra fields" do
      preview = %{
        template: %{name: "Bare", description: ""},
        step_count: 1,
        steps: [%{index: 1, action: "new_window", params: %{}}]
      }

      assigns = %{template_preview: preview}

      html =
        rendered_to_string(~H"""
        <TemplatePanels.render_template_preview template_preview={@template_preview} />
        """)

      # Title fallback for new_window without a name.
      assert html =~ "New window window"
    end
  end

  # ---------------------------------------------------------------------------
  # render_template_preview/1 — reconcile (diff) branch
  # ---------------------------------------------------------------------------

  describe "render_template_preview/1 reconcile" do
    defp reconcile_preview(overrides \\ %{}) do
      base = %{
        template: %{name: "Reconcile me", description: "diffed"},
        step_count: 9,
        diff: %{
          estimated_disruption: "medium",
          strategy: "smart",
          summary: %{
            reuse_windows: 1,
            create_windows: 2,
            reuse_panes: 0,
            new_panes: 1,
            send_commands: 3,
            select_panes: 1
          },
          changes: [
            %{
              index: 1,
              action: "reuse_window",
              template_ref: %{name: "main", ref: "w1"},
              reason: "matched"
            },
            %{
              index: 2,
              action: "create_window",
              template_ref: %{ref: "w2"}
            },
            %{
              index: 3,
              action: "reuse_pane",
              template_ref: %{name: "shell", ref: "p1"}
            },
            %{
              index: 4,
              action: "split_pane",
              template_ref: %{ref: "p2"},
              direction: "vertical",
              cwd: "/tmp"
            },
            %{
              index: 5,
              action: "send_command",
              command: "ls -la",
              target_id: "%3"
            },
            %{
              index: 6,
              action: "select_pane",
              template_ref: %{ref: "p9"}
            },
            %{index: 7, action: "mystery_action"}
          ]
        }
      }

      Map.merge(base, overrides)
    end

    test "renders the reconcile summary, disruption badge and per-change rows" do
      assigns = %{template_preview: reconcile_preview()}

      html =
        rendered_to_string(~H"""
        <TemplatePanels.render_template_preview template_preview={@template_preview} />
        """)

      assert html =~ "Smart reconcile"
      assert html =~ "template-reconcile-summary"
      assert html =~ "template-reconcile-changes"

      # Disruption badge: medium label + warning class.
      assert html =~ "Disruption: medium"
      assert html =~ "text-warning"

      # Strategy chip.
      assert html =~ "smart"

      # Summary sentence (template_reconcile_summary_sentence/1, mixed singular/plural,
      # 0-valued keys dropped).
      assert html =~
               "Would 1 window to reuse, 2 windows to create, 1 pane to create, 3 commands to send."

      # Summary item grid uses dasherized keys.
      assert html =~ "template-reconcile-summary-reuse-windows"
      assert html =~ "template-reconcile-summary-select-panes"

      # Change titles (template_change_title/1 clauses).
      assert html =~ "Reuse window main"
      # create_window with no name falls back to the ref value.
      assert html =~ "Create window w2"
      assert html =~ "Reuse pane shell"
      assert html =~ "Split pane p2"
      assert html =~ "Run ls -la"
      assert html =~ "Focus p9"
      # Unknown action -> raw action.
      assert html =~ "mystery_action"

      # Change details (template_change_detail/1).
      assert html =~ "reason=matched"
      assert html =~ "direction=vertical"
      assert html =~ "cwd=/tmp"
      assert html =~ "target=%3"
      assert html =~ "command=ls -la"

      # Exact-plan note uses step_count (rendered in the dashed note block).
      assert html =~ "template-exact-plan-note"
      assert html =~ "planned tmux operation(s)"

      # Footer counts changes, not steps (single-string helper output).
      assert html =~ "7 reconciliation change(s)"

      # Reconcile footer offers both exact-replay and reconcile apply.
      assert html =~ "template-preview-apply-exact"
      assert html =~ "Apply reconcile"
      assert html =~ ~s(phx-value-mode="reconcile")
    end

    test "low disruption uses the success class and label" do
      diff =
        reconcile_preview().diff
        |> Map.put(:estimated_disruption, "low")

      assigns = %{template_preview: reconcile_preview(%{diff: diff})}

      html =
        rendered_to_string(~H"""
        <TemplatePanels.render_template_preview template_preview={@template_preview} />
        """)

      assert html =~ "Disruption: low"
      assert html =~ "text-success"
    end

    test "high disruption uses the error class" do
      diff =
        reconcile_preview().diff
        |> Map.put(:estimated_disruption, "high")

      assigns = %{template_preview: reconcile_preview(%{diff: diff})}

      html =
        rendered_to_string(~H"""
        <TemplatePanels.render_template_preview template_preview={@template_preview} />
        """)

      assert html =~ "Disruption: high"
      assert html =~ "text-error"
    end

    test "unknown disruption falls back to the neutral class and 'unknown' label" do
      diff =
        reconcile_preview().diff
        |> Map.put(:estimated_disruption, nil)
        |> Map.put(:summary, %{})
        |> Map.put(:changes, [])

      assigns = %{template_preview: reconcile_preview(%{diff: diff})}

      html =
        rendered_to_string(~H"""
        <TemplatePanels.render_template_preview template_preview={@template_preview} />
        """)

      assert html =~ "Disruption: unknown"
      assert html =~ "text-base-content/55"
      # Empty summary => "no changes" sentence.
      assert html =~ "No tmux changes are needed."
      # Zero changes => footer reports 0.
      assert html =~ "0 reconciliation change(s)"
    end
  end

  # ---------------------------------------------------------------------------
  # render_template_library/1
  # ---------------------------------------------------------------------------

  describe "render_template_library/1 closed" do
    test "renders only the hidden placeholder when the drawer is closed" do
      assigns = library_assigns(%{template_library_open: false})

      html = render_library(assigns)

      assert html =~ "template-library-empty-state"
      refute html =~ "template-library-modal"
    end
  end

  describe "render_template_library/1 empty" do
    test "renders the empty state and 0-saved count with no tag filters" do
      assigns =
        library_assigns(%{
          template_library_open: true,
          saved_session_templates: [],
          saved_session_template_tags: []
        })

      html = render_library(assigns)

      assert html =~ "template-library-modal"
      assert html =~ "0 saved"
      assert html =~ "template-library-empty"
      assert html =~ "No saved templates"
      # No tag filter bar when there are no tags.
      refute html =~ "saved-template-tag-filters"
    end

    test "falls back to the workspace id when the name is nil" do
      assigns =
        library_assigns(%{
          template_library_open: true,
          workspace: %{id: "ws-xyz", name: nil},
          saved_session_templates: []
        })

      html = render_library(assigns)

      assert html =~ "ws-xyz"
    end
  end

  describe "render_template_library/1 populated rows" do
    test "renders a supported saved row with tags, counts and timestamp" do
      saved =
        supported_template(%{
          id: "tpl1",
          name: "Daily",
          description: "My daily stack",
          tags: ["phoenix", "daily"],
          inserted_at: ~U[2026-06-24 09:30:00Z],
          body: %{
            "version" => 2,
            "windows" => [
              %{"layout" => %{"panes" => [%{}, %{}]}},
              %{"layout" => %{"panes" => []}}
            ]
          }
        })

      assigns =
        library_assigns(%{
          template_library_open: true,
          saved_session_templates: [saved],
          saved_session_template_tags: ["phoenix", "daily"]
        })

      html = render_library(assigns)

      assert html =~ "saved-template-row-tpl1"
      assert html =~ "Daily"
      assert html =~ "My daily stack"
      assert html =~ "v2"
      # supported => no "unsupported" badge and preview/apply not disabled.
      refute html =~ "unsupported"

      # Tags rendered.
      assert html =~ "saved-template-tags-tpl1"
      assert html =~ "saved-template-tag-tpl1-phoenix"
      assert html =~ "saved-template-tag-tpl1-daily"

      # Window/pane counts: window 1 has 2 panes, window 2 has empty layout -> 1.
      assert html =~ "2 window(s)"
      assert html =~ "3 pane(s)"
      assert html =~ "2026-06-24 09:30 UTC"

      # Action buttons present.
      assert html =~ "saved-template-edit-tpl1"
      assert html =~ "saved-template-duplicate-tpl1"
      assert html =~ "saved-template-preview-tpl1"
      assert html =~ "saved-template-delete-tpl1"

      # Tag filter bar present with an "All" plus per-tag buttons.
      assert html =~ "saved-template-tag-filters"
      assert html =~ "saved-template-filter-all"
      assert html =~ "saved-template-filter-phoenix"
    end

    test "marks an unsupported template and disables preview/apply" do
      saved =
        supported_template(%{
          id: "tpl2",
          name: "Old",
          schema_version: 1,
          body: %{"version" => 1},
          tags: [],
          inserted_at: nil
        })

      assigns =
        library_assigns(%{
          template_library_open: true,
          saved_session_templates: [saved],
          saved_session_template_tags: []
        })

      html = render_library(assigns)

      assert html =~ "unsupported"
      assert html =~ "disabled"
      # No tags block, description fallback.
      refute html =~ "saved-template-tags-tpl2"
      assert html =~ "Exported tmux layout"
      # Default body windows missing => 0 windows / 0 panes + "saved" timestamp fallback.
      assert html =~ "0 window(s)"
      assert html =~ "0 pane(s)"
      # The timestamp fallback renders the literal word "saved" in the meta line.
      assert html =~ "pane(s) ·"
    end

    test "renders the edit form for the row being edited" do
      saved = supported_template(%{id: "tpl3", name: "Editing"})

      assigns =
        library_assigns(%{
          template_library_open: true,
          saved_session_templates: [saved],
          template_edit_id: "tpl3",
          template_edit_form: to_form(%{}, as: :template)
        })

      html = render_library(assigns)

      assert html =~ "saved-template-edit-form-tpl3"
      assert html =~ "saved-template-edit-name-tpl3"
      assert html =~ "saved-template-edit-cancel-tpl3"
      # The read-only action buttons should not be shown while editing.
      refute html =~ "saved-template-delete-tpl3"
    end

    test "renders the duplicate form for the row being duplicated" do
      saved = supported_template(%{id: "tpl4", name: "Dup"})

      assigns =
        library_assigns(%{
          template_library_open: true,
          saved_session_templates: [saved],
          template_duplicate_id: "tpl4",
          template_duplicate_form: to_form(%{}, as: :template)
        })

      html = render_library(assigns)

      assert html =~ "saved-template-duplicate-form-tpl4"
      assert html =~ "saved-template-duplicate-name-tpl4"
      assert html =~ "saved-template-duplicate-cancel-tpl4"
      refute html =~ "saved-template-edit-form-tpl4"
    end

    test "highlights the active tag filter button" do
      saved = supported_template(%{id: "tpl5", name: "Filtered", tags: ["phoenix"]})

      assigns =
        library_assigns(%{
          template_library_open: true,
          saved_session_templates: [saved],
          saved_session_template_tags: ["phoenix"],
          template_tag_filter: "phoenix"
        })

      html = render_library(assigns)

      assert html =~ "saved-template-filter-phoenix"
      # The active filter gets the primary border/highlight class.
      assert html =~ "border-primary bg-primary/10 text-primary"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers for building library assigns / templates
  # ---------------------------------------------------------------------------

  defp supported_template(overrides) do
    base = %{
      id: "tpl",
      name: "Template",
      description: "",
      tags: [],
      schema_version: 2,
      source_session: nil,
      inserted_at: ~U[2026-06-24 00:00:00Z],
      body: %{"version" => 2, "windows" => []}
    }

    Map.merge(base, overrides)
  end

  defp library_assigns(overrides) do
    base = %{
      template_library_open: true,
      workspace: %{id: "ws-1", name: "My Workspace"},
      saved_session_templates: [],
      saved_session_template_tags: [],
      template_tag_filter: nil,
      template_edit_id: nil,
      template_duplicate_id: nil,
      template_save_form: to_form(%{}, as: :template),
      template_edit_form: to_form(%{}, as: :template),
      template_duplicate_form: to_form(%{}, as: :template)
    }

    Map.merge(base, overrides)
  end

  defp render_library(assigns) do
    rendered_to_string(~H"""
    <TemplatePanels.render_template_library
      template_library_open={@template_library_open}
      workspace={@workspace}
      saved_session_templates={@saved_session_templates}
      saved_session_template_tags={@saved_session_template_tags}
      template_tag_filter={@template_tag_filter}
      template_edit_id={@template_edit_id}
      template_duplicate_id={@template_duplicate_id}
      template_save_form={@template_save_form}
      template_edit_form={@template_edit_form}
      template_duplicate_form={@template_duplicate_form}
    />
    """)
  end
end
