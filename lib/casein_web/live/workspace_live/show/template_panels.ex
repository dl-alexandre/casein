defmodule CaseinWeb.WorkspaceLive.Show.TemplatePanels do
  @moduledoc """
  Session-template UI for the workspace cockpit: the template preview
  modal (apply / reconcile dry-run) and the template library drawer
  (saved templates, edit/duplicate/delete forms).

  Attr-contracted function components: each panel declares exactly the
  assigns it reads instead of receiving the LiveView's whole assigns bag.
  """

  use CaseinWeb, :html

  alias Casein.Terminals

  @template_reconcile_summary_fields [
    {:reuse_windows, "Reuse windows"},
    {:create_windows, "Create windows"},
    {:reuse_panes, "Reuse panes"},
    {:new_panes, "New panes"},
    {:send_commands, "Send commands"},
    {:select_panes, "Focus changes"}
  ]

  attr :template_preview, :any,
    required: true,
    doc: "preview struct with .template + .diff/.steps, or nil when closed"

  def template_preview_modal(assigns) do
    ~H"""
    <%= if @template_preview do %>
      <div
        id="template-preview-modal"
        class="fixed inset-0 z-[60] flex items-start justify-center bg-black/55 px-4 pt-20 text-base-content"
      >
        <section
          id="template-preview-card"
          class="flex max-h-[78vh] w-[720px] max-w-[94vw] flex-col overflow-hidden rounded border border-base-300 bg-base-100 shadow-2xl"
        >
          <header class="flex items-start justify-between gap-4 border-b border-base-300 px-4 py-3">
            <div class="min-w-0">
              <div class="text-[10px] font-semibold uppercase tracking-wide text-primary">
                Session template preview
              </div>
              <h2 id="template-preview-title" class="truncate text-sm font-semibold">
                {@template_preview.template.name}
              </h2>
              <p class="mt-1 text-xs text-base-content/65">
                {@template_preview.template.description}
              </p>
              <%= if template_preview_reconcile?(@template_preview) do %>
                <div class="mt-2 flex flex-wrap items-center gap-2">
                  <span class="rounded border border-primary/25 bg-primary/10 px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide text-primary">
                    Smart reconcile
                  </span>
                  <span
                    id="template-reconcile-disruption"
                    data-disruption={@template_preview.diff.estimated_disruption}
                    class={template_disruption_class(@template_preview.diff.estimated_disruption)}
                  >
                    {template_disruption_label(@template_preview.diff.estimated_disruption)}
                  </span>
                </div>
              <% end %>
            </div>
            <button
              id="template-preview-close"
              type="button"
              phx-click="tmux:cancel_template_preview"
              class="rounded p-1 text-base-content/45 transition hover:bg-base-200 hover:text-base-content"
              title="Close template preview"
              aria-label="Close template preview"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </header>

          <div id="template-preview-steps" class="min-h-0 flex-1 overflow-auto px-4 py-3">
            <%= if template_preview_reconcile?(@template_preview) do %>
              <div
                id="template-reconcile-summary"
                class="mb-3 rounded border border-primary/20 bg-primary/5 px-3 py-3"
              >
                <div class="flex flex-wrap items-center justify-between gap-2">
                  <div>
                    <h3 class="text-xs font-semibold text-base-content">
                      Reconciliation preview
                    </h3>
                    <p class="mt-1 text-[11px] text-base-content/60">
                      {template_reconcile_summary_sentence(@template_preview.diff.summary)}
                    </p>
                  </div>
                  <span class="rounded bg-base-100 px-2 py-1 font-mono text-[10px] text-base-content/55">
                    {@template_preview.diff.strategy}
                  </span>
                </div>

                <div class="mt-3 grid grid-cols-2 gap-2 sm:grid-cols-3">
                  <%= for item <- template_reconcile_summary_items(@template_preview.diff.summary) do %>
                    <div
                      id={"template-reconcile-summary-" <> item.key}
                      class="rounded border border-base-300 bg-base-100 px-2 py-1.5"
                    >
                      <div class="text-[10px] uppercase tracking-wide text-base-content/45">
                        {item.label}
                      </div>
                      <div class="font-mono text-sm font-semibold text-base-content">
                        {item.value}
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>

              <div id="template-reconcile-changes" class="space-y-2">
                <%= for change <- @template_preview.diff.changes do %>
                  <article
                    id={"template-reconcile-change-" <> Integer.to_string(change.index)}
                    data-action={change.action}
                    class={template_change_class(change.action)}
                  >
                    <div class="flex items-start gap-3">
                      <span class="mt-0.5 flex size-5 shrink-0 items-center justify-center rounded border border-base-300 bg-base-100 font-mono text-[10px] text-base-content/60">
                        {change.index}
                      </span>
                      <div class="min-w-0 flex-1">
                        <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
                          <span class="font-medium">{template_change_title(change)}</span>
                          <span class="rounded bg-base-100 px-1.5 py-0.5 font-mono text-[10px] text-base-content/60">
                            {change.action}
                          </span>
                        </div>
                        <%= if template_change_detail(change) != "" do %>
                          <p class="mt-1 truncate font-mono text-[10px] text-base-content/60">
                            {template_change_detail(change)}
                          </p>
                        <% end %>
                      </div>
                    </div>
                  </article>
                <% end %>
              </div>

              <div
                id="template-exact-plan-note"
                class="mt-3 rounded border border-dashed border-base-300 px-3 py-2 text-[11px] text-base-content/55"
              >
                Exact replay would run {@template_preview.step_count} planned tmux operation(s)
                without trying to reuse the current layout.
              </div>
            <% else %>
              <div class="space-y-2">
                <%= for step <- @template_preview.steps do %>
                  <article
                    id={"template-preview-step-" <> Integer.to_string(step.index)}
                    data-action={step.action}
                    class="rounded border border-base-300 bg-base-200/35 px-3 py-2 text-xs"
                  >
                    <div class="flex items-start gap-3">
                      <span class="mt-0.5 flex size-5 shrink-0 items-center justify-center rounded border border-base-300 bg-base-100 font-mono text-[10px] text-base-content/60">
                        {step.index}
                      </span>
                      <div class="min-w-0 flex-1">
                        <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
                          <span class="font-medium">{template_step_title(step)}</span>
                          <span class="rounded bg-base-300 px-1.5 py-0.5 font-mono text-[10px] text-base-content/60">
                            {step.action}
                          </span>
                        </div>
                        <%= if template_step_detail(step) != "" do %>
                          <p class="mt-1 truncate font-mono text-[10px] text-base-content/60">
                            {template_step_detail(step)}
                          </p>
                        <% end %>
                      </div>
                    </div>
                  </article>
                <% end %>
              </div>
            <% end %>
          </div>

          <footer class="flex items-center justify-between gap-3 border-t border-base-300 px-4 py-3 text-xs">
            <span class="text-base-content/55">
              {template_preview_footer(@template_preview)}
            </span>
            <div class="flex items-center gap-2">
              <button
                id="template-preview-cancel"
                type="button"
                phx-click="tmux:cancel_template_preview"
                class="rounded border border-base-300 px-3 py-1.5 text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
              >
                Cancel
              </button>
              <%= if template_preview_reconcile?(@template_preview) do %>
                <button
                  id="template-preview-apply-exact"
                  type="button"
                  phx-click="tmux:apply_previewed_template"
                  phx-value-mode="exact"
                  class="rounded border border-base-300 px-3 py-1.5 font-medium text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
                >
                  Exact replay
                </button>
              <% end %>
              <button
                id="template-preview-apply"
                type="button"
                phx-click="tmux:apply_previewed_template"
                phx-value-mode={template_preview_default_apply_mode(@template_preview)}
                class="rounded border border-primary bg-primary/10 px-3 py-1.5 font-medium text-primary transition hover:bg-primary/15"
              >
                {template_preview_apply_label(@template_preview)}
              </button>
            </div>
          </footer>
        </section>
      </div>
    <% else %>
      <div id="template-preview-empty" class="hidden"></div>
    <% end %>
    """
  end

  defp template_preview_reconcile?(%{diff: diff}) when is_map(diff), do: true
  defp template_preview_reconcile?(_preview), do: false

  def template_preview_default_apply_mode(preview) do
    if template_preview_reconcile?(preview), do: "reconcile", else: "exact"
  end

  defp template_preview_apply_label(preview) do
    if template_preview_reconcile?(preview), do: "Apply reconcile", else: "Apply template"
  end

  defp template_preview_footer(%{diff: diff}) when is_map(diff) do
    changes = diff |> Map.get(:changes, []) |> length()
    "#{changes} reconciliation change(s)"
  end

  defp template_preview_footer(%{step_count: step_count}) do
    "#{step_count} planned tmux operation(s)"
  end

  defp template_reconcile_summary_items(summary) do
    Enum.map(@template_reconcile_summary_fields, fn {key, label} ->
      %{
        key: key |> Atom.to_string() |> String.replace("_", "-"),
        label: label,
        value: Map.get(summary || %{}, key, 0)
      }
    end)
  end

  defp template_reconcile_summary_sentence(summary) do
    summary = summary || %{}

    [
      summary_fragment(summary, :reuse_windows, "window to reuse", "windows to reuse"),
      summary_fragment(summary, :create_windows, "window to create", "windows to create"),
      summary_fragment(summary, :reuse_panes, "pane to reuse", "panes to reuse"),
      summary_fragment(summary, :new_panes, "pane to create", "panes to create"),
      summary_fragment(summary, :send_commands, "command to send", "commands to send")
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "No tmux changes are needed."
      fragments -> "Would " <> Enum.join(fragments, ", ") <> "."
    end
  end

  defp summary_fragment(summary, key, singular, plural) do
    case Map.get(summary, key, 0) do
      0 -> nil
      1 -> "1 " <> singular
      count -> "#{count} #{plural}"
    end
  end

  defp template_disruption_label(disruption) do
    "Disruption: " <> template_value(disruption, "unknown")
  end

  defp template_disruption_class("low"),
    do:
      "rounded bg-success/10 px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide text-success"

  defp template_disruption_class("medium"),
    do:
      "rounded bg-warning/10 px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide text-warning"

  defp template_disruption_class("high"),
    do:
      "rounded bg-error/10 px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide text-error"

  defp template_disruption_class(_),
    do:
      "rounded bg-base-200 px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide text-base-content/55"

  defp template_change_title(%{action: "reuse_window"} = change) do
    "Reuse window " <> template_value(template_ref_name(change), template_ref_value(change))
  end

  defp template_change_title(%{action: "create_window"} = change) do
    "Create window " <> template_value(template_ref_name(change), template_ref_value(change))
  end

  defp template_change_title(%{action: "reuse_pane"} = change) do
    "Reuse pane " <> template_value(template_ref_name(change), template_ref_value(change))
  end

  defp template_change_title(%{action: "split_pane"} = change) do
    "Split pane " <> template_value(template_ref_name(change), template_ref_value(change))
  end

  defp template_change_title(%{action: "send_command", command: command}) do
    "Run " <> template_value(command, "command")
  end

  defp template_change_title(%{action: "select_pane"} = change) do
    "Focus " <> template_value(template_ref_value(change), "pane")
  end

  defp template_change_title(%{action: action}), do: action

  defp template_change_detail(change) do
    [
      {"target", Map.get(change, :target_id)},
      {"ref", template_ref_value(change)},
      {"reason", Map.get(change, :reason)},
      {"direction", Map.get(change, :direction)},
      {"cwd", Map.get(change, :cwd)},
      {"command", Map.get(change, :command)}
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Enum.map_join(" · ", fn {key, value} -> "#{key}=#{value}" end)
  end

  defp template_change_class(action) when action in ["reuse_window", "reuse_pane"] do
    "rounded border border-success/25 bg-success/5 px-3 py-2 text-xs"
  end

  defp template_change_class(action) when action in ["create_window", "split_pane"] do
    "rounded border border-primary/25 bg-primary/5 px-3 py-2 text-xs"
  end

  defp template_change_class("send_command") do
    "rounded border border-info/25 bg-info/5 px-3 py-2 text-xs"
  end

  defp template_change_class(_action) do
    "rounded border border-base-300 bg-base-200/35 px-3 py-2 text-xs"
  end

  defp template_ref_name(change) do
    change
    |> Map.get(:template_ref, %{})
    |> Map.get(:name)
  end

  defp template_ref_value(change) do
    change
    |> Map.get(:template_ref, %{})
    |> Map.get(:ref)
  end

  attr :template_library_open, :boolean, required: true
  attr :workspace, :any, required: true
  attr :saved_session_templates, :list, required: true
  attr :saved_session_template_tags, :list, required: true
  attr :template_tag_filter, :any, default: nil
  attr :template_save_form, :any, default: nil
  attr :template_edit_id, :any, default: nil
  attr :template_edit_form, :any, default: nil
  attr :template_duplicate_id, :any, default: nil
  attr :template_duplicate_form, :any, default: nil

  def template_library_drawer(assigns) do
    ~H"""
    <%= if @template_library_open do %>
      <div
        id="template-library-modal"
        class="fixed inset-0 z-[60] flex items-start justify-center bg-black/55 px-4 pt-16 text-base-content"
      >
        <section
          id="template-library-card"
          class="flex max-h-[82vh] w-[780px] max-w-[96vw] flex-col overflow-hidden rounded border border-base-300 bg-base-100 shadow-2xl"
        >
          <header class="flex items-start justify-between gap-4 border-b border-base-300 px-4 py-3">
            <div class="min-w-0">
              <div class="text-[10px] font-semibold uppercase tracking-wide text-primary">
                Session templates
              </div>
              <h2 id="template-library-title" class="truncate text-sm font-semibold">
                {@workspace.name || @workspace.id}
              </h2>
              <p class="mt-1 text-xs text-base-content/60">
                {length(@saved_session_templates || [])} saved
              </p>
            </div>
            <button
              id="template-library-close"
              type="button"
              phx-click="tmux:close_template_library"
              class="rounded p-1 text-base-content/45 transition hover:bg-base-200 hover:text-base-content"
              title="Close template library"
              aria-label="Close template library"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </header>

          <div class="min-h-0 flex-1 overflow-auto px-4 py-4">
            <.form
              for={@template_save_form}
              id="template-save-form"
              phx-submit="tmux:save_template"
              class="mb-4 grid gap-3 rounded border border-base-300 bg-base-200/30 p-3 sm:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)_minmax(0,0.9fr)_auto]"
            >
              <.input
                field={@template_save_form[:name]}
                type="text"
                label="Name"
                placeholder="daily_layout"
                class="h-9 rounded border border-base-300 bg-base-100 px-3 text-sm text-base-content outline-none transition focus:border-primary focus:ring-1 focus:ring-primary"
              />
              <.input
                field={@template_save_form[:description]}
                type="text"
                label="Description"
                placeholder="Daily dev stack"
                class="h-9 rounded border border-base-300 bg-base-100 px-3 text-sm text-base-content outline-none transition focus:border-primary focus:ring-1 focus:ring-primary"
              />
              <.input
                field={@template_save_form[:tags]}
                type="text"
                label="Tags"
                placeholder="phoenix, daily"
                class="h-9 rounded border border-base-300 bg-base-100 px-3 text-sm text-base-content outline-none transition focus:border-primary focus:ring-1 focus:ring-primary"
              />
              <div class="flex items-end">
                <button
                  id="template-save-submit"
                  type="submit"
                  class="inline-flex h-9 items-center gap-1.5 rounded border border-primary bg-primary/10 px-3 text-sm font-medium text-primary transition hover:bg-primary/15"
                  title="Save current layout"
                  aria-label="Save current layout"
                >
                  <.icon name="hero-bookmark-square" class="size-4" /> Save
                </button>
              </div>
            </.form>

            <div
              :if={@saved_session_template_tags != []}
              id="saved-template-tag-filters"
              class="mb-4 flex flex-wrap items-center gap-1.5 text-xs"
            >
              <button
                id="saved-template-filter-all"
                type="button"
                phx-click="tmux:filter_saved_templates"
                phx-value-tag=""
                class={[
                  "rounded border px-2 py-1 transition",
                  is_nil(@template_tag_filter) &&
                    "border-primary bg-primary/10 text-primary",
                  @template_tag_filter &&
                    "border-base-300 text-base-content/60 hover:bg-base-200 hover:text-base-content"
                ]}
              >
                All
              </button>
              <button
                :for={tag <- @saved_session_template_tags}
                id={"saved-template-filter-" <> tag}
                type="button"
                phx-click="tmux:filter_saved_templates"
                phx-value-tag={tag}
                class={[
                  "rounded border px-2 py-1 transition",
                  @template_tag_filter == tag &&
                    "border-primary bg-primary/10 text-primary",
                  @template_tag_filter != tag &&
                    "border-base-300 text-base-content/60 hover:bg-base-200 hover:text-base-content"
                ]}
              >
                {tag}
              </button>
            </div>

            <div id="saved-template-list" class="space-y-2">
              <div
                :if={(@saved_session_templates || []) == []}
                id="template-library-empty"
                class="rounded border border-dashed border-base-300 px-3 py-6 text-center text-xs text-base-content/55"
              >
                No saved templates
              </div>
              <%= for saved <- @saved_session_templates || [] do %>
                <article
                  id={"saved-template-row-" <> saved.id}
                  class="rounded border border-base-300 bg-base-100 px-3 py-3 transition hover:border-primary/35 hover:bg-base-200/25"
                >
                  <%= if @template_duplicate_id == saved.id do %>
                    <.form
                      for={@template_duplicate_form}
                      id={"saved-template-duplicate-form-" <> saved.id}
                      phx-submit="tmux:duplicate_saved_template"
                      class="grid gap-3 sm:grid-cols-[minmax(0,1fr)_minmax(0,1.15fr)_minmax(0,0.85fr)_auto]"
                    >
                      <input type="hidden" name="template[source_id]" value={saved.id} />
                      <.input
                        field={@template_duplicate_form[:name]}
                        id={"saved-template-duplicate-name-" <> saved.id}
                        type="text"
                        label="Copy name"
                        class="h-9 rounded border border-base-300 bg-base-100 px-3 text-sm text-base-content outline-none transition focus:border-primary focus:ring-1 focus:ring-primary"
                      />
                      <.input
                        field={@template_duplicate_form[:description]}
                        id={"saved-template-duplicate-description-" <> saved.id}
                        type="text"
                        label="Description"
                        class="h-9 rounded border border-base-300 bg-base-100 px-3 text-sm text-base-content outline-none transition focus:border-primary focus:ring-1 focus:ring-primary"
                      />
                      <.input
                        field={@template_duplicate_form[:tags]}
                        id={"saved-template-duplicate-tags-" <> saved.id}
                        type="text"
                        label="Tags"
                        class="h-9 rounded border border-base-300 bg-base-100 px-3 text-sm text-base-content outline-none transition focus:border-primary focus:ring-1 focus:ring-primary"
                      />
                      <div class="flex items-end gap-1">
                        <button
                          id={"saved-template-duplicate-save-" <> saved.id}
                          type="submit"
                          class="inline-flex h-9 items-center gap-1.5 rounded border border-primary bg-primary/10 px-3 text-sm font-medium text-primary transition hover:bg-primary/15"
                          title="Create template copy"
                          aria-label="Create template copy"
                        >
                          <.icon name="hero-document-duplicate" class="size-4" /> Copy
                        </button>
                        <button
                          id={"saved-template-duplicate-cancel-" <> saved.id}
                          type="button"
                          phx-click="tmux:cancel_saved_template_duplicate"
                          class="inline-flex h-9 items-center rounded border border-base-300 px-2 text-sm text-base-content/60 transition hover:bg-base-200 hover:text-base-content"
                          title="Cancel duplicate"
                          aria-label="Cancel duplicate"
                        >
                          <.icon name="hero-x-mark" class="size-4" />
                        </button>
                      </div>
                    </.form>
                  <% else %>
                    <%= if @template_edit_id == saved.id do %>
                      <.form
                        for={@template_edit_form}
                        id={"saved-template-edit-form-" <> saved.id}
                        phx-submit="tmux:update_saved_template"
                        class="grid gap-3 sm:grid-cols-[minmax(0,1fr)_minmax(0,1.15fr)_minmax(0,0.85fr)_auto]"
                      >
                        <input type="hidden" name="template[id]" value={saved.id} />
                        <.input
                          field={@template_edit_form[:name]}
                          id={"saved-template-edit-name-" <> saved.id}
                          type="text"
                          label="Name"
                          class="h-9 rounded border border-base-300 bg-base-100 px-3 text-sm text-base-content outline-none transition focus:border-primary focus:ring-1 focus:ring-primary"
                        />
                        <.input
                          field={@template_edit_form[:description]}
                          id={"saved-template-edit-description-" <> saved.id}
                          type="text"
                          label="Description"
                          class="h-9 rounded border border-base-300 bg-base-100 px-3 text-sm text-base-content outline-none transition focus:border-primary focus:ring-1 focus:ring-primary"
                        />
                        <.input
                          field={@template_edit_form[:tags]}
                          id={"saved-template-edit-tags-" <> saved.id}
                          type="text"
                          label="Tags"
                          class="h-9 rounded border border-base-300 bg-base-100 px-3 text-sm text-base-content outline-none transition focus:border-primary focus:ring-1 focus:ring-primary"
                        />
                        <div class="flex items-end gap-1">
                          <button
                            id={"saved-template-edit-save-" <> saved.id}
                            type="submit"
                            class="inline-flex h-9 items-center gap-1.5 rounded border border-primary bg-primary/10 px-3 text-sm font-medium text-primary transition hover:bg-primary/15"
                            title="Save template metadata"
                            aria-label="Save template metadata"
                          >
                            <.icon name="hero-check" class="size-4" /> Save
                          </button>
                          <button
                            id={"saved-template-edit-cancel-" <> saved.id}
                            type="button"
                            phx-click="tmux:cancel_saved_template_edit"
                            class="inline-flex h-9 items-center rounded border border-base-300 px-2 text-sm text-base-content/60 transition hover:bg-base-200 hover:text-base-content"
                            title="Cancel metadata edit"
                            aria-label="Cancel metadata edit"
                          >
                            <.icon name="hero-x-mark" class="size-4" />
                          </button>
                        </div>
                      </.form>
                    <% else %>
                      <div class="flex items-start justify-between gap-3">
                        <div class="min-w-0">
                          <div class="flex flex-wrap items-center gap-2">
                            <h3 class="truncate text-sm font-medium">{saved.name}</h3>
                            <span class="rounded bg-base-200 px-1.5 py-0.5 text-[10px] uppercase tracking-wide text-base-content/55">
                              v{saved.schema_version}
                            </span>
                            <%= unless Terminals.saved_template_apply_supported?(saved) do %>
                              <span class="rounded bg-warning/10 px-1.5 py-0.5 text-[10px] uppercase tracking-wide text-warning">
                                unsupported
                              </span>
                            <% end %>
                          </div>
                          <p class="mt-1 line-clamp-2 text-xs text-base-content/60">
                            {saved_template_description(saved)}
                          </p>
                          <div
                            :if={saved_template_tags(saved) != []}
                            id={"saved-template-tags-" <> saved.id}
                            class="mt-2 flex flex-wrap gap-1"
                          >
                            <span
                              :for={tag <- saved_template_tags(saved)}
                              id={"saved-template-tag-" <> saved.id <> "-" <> tag}
                              class="rounded bg-primary/10 px-1.5 py-0.5 text-[10px] font-medium text-primary"
                            >
                              {tag}
                            </span>
                          </div>
                          <p class="mt-2 text-[10px] text-base-content/45">
                            {saved_template_window_count(saved)} window(s) · {saved_template_pane_count(
                              saved
                            )} pane(s) · {saved_template_timestamp(saved)}
                          </p>
                        </div>
                        <div class="flex shrink-0 items-center gap-1">
                          <button
                            id={"saved-template-edit-" <> saved.id}
                            type="button"
                            phx-click="tmux:edit_saved_template"
                            phx-value-template-id={saved.id}
                            class="rounded p-1.5 text-base-content/45 transition hover:bg-base-200 hover:text-base-content"
                            title="Edit saved template metadata"
                            aria-label="Edit saved template metadata"
                          >
                            <.icon name="hero-pencil-square" class="size-4" />
                          </button>
                          <button
                            id={"saved-template-duplicate-" <> saved.id}
                            type="button"
                            phx-click="tmux:duplicate_saved_template_start"
                            phx-value-template-id={saved.id}
                            class="rounded p-1.5 text-base-content/45 transition hover:bg-base-200 hover:text-base-content"
                            title="Duplicate saved template"
                            aria-label="Duplicate saved template"
                          >
                            <.icon name="hero-document-duplicate" class="size-4" />
                          </button>
                          <button
                            id={"saved-template-preview-" <> saved.id}
                            type="button"
                            phx-click="tmux:preview_template"
                            phx-value-template-id={saved.id}
                            disabled={!Terminals.saved_template_apply_supported?(saved)}
                            class="rounded p-1.5 text-base-content/55 transition hover:bg-primary/10 hover:text-primary disabled:cursor-not-allowed disabled:opacity-35"
                            title="Preview saved template"
                            aria-label="Preview saved template"
                          >
                            <.icon name="hero-eye" class="size-4" />
                          </button>
                          <button
                            id={"saved-template-apply-" <> saved.id}
                            type="button"
                            phx-click="tmux:preview_template"
                            phx-value-template-id={saved.id}
                            disabled={!Terminals.saved_template_apply_supported?(saved)}
                            class="rounded p-1.5 text-base-content/55 transition hover:bg-primary/10 hover:text-primary disabled:cursor-not-allowed disabled:opacity-35"
                            title="Preview and apply saved template"
                            aria-label="Preview and apply saved template"
                          >
                            <.icon name="hero-play" class="size-4" />
                          </button>
                          <button
                            id={"saved-template-delete-" <> saved.id}
                            type="button"
                            phx-click="tmux:delete_saved_template"
                            phx-value-template-id={saved.id}
                            class="rounded p-1.5 text-base-content/45 transition hover:bg-error/10 hover:text-error"
                            title="Delete saved template"
                            aria-label="Delete saved template"
                          >
                            <.icon name="hero-trash" class="size-4" />
                          </button>
                        </div>
                      </div>
                    <% end %>
                  <% end %>
                </article>
              <% end %>
            </div>
          </div>
        </section>
      </div>
    <% else %>
      <div id="template-library-empty-state" class="hidden"></div>
    <% end %>
    """
  end

  defp template_step_title(%{action: "new_window", params: params}) do
    "New window " <> template_value(Map.get(params, :name), "window")
  end

  defp template_step_title(%{action: "split_pane", ref: ref}) do
    "Split pane " <> template_value(ref, "pane")
  end

  defp template_step_title(%{action: "send_command", params: params}) do
    "Run " <> template_value(Map.get(params, :command), "command")
  end

  defp template_step_title(%{action: "select_pane", target_ref: target_ref}) do
    "Focus " <> template_value(target_ref, "pane")
  end

  defp template_step_title(%{action: action}), do: action

  defp template_step_detail(step) do
    params = Map.get(step, :params, %{})

    [
      {"ref", Map.get(step, :ref)},
      {"target", Map.get(step, :target_ref)},
      {"cwd", Map.get(params, :cwd)},
      {"direction", Map.get(params, :direction)},
      {"size", Map.get(params, :size_percent)},
      {"command", Map.get(params, :command)}
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Enum.map_join(" · ", fn {key, value} -> "#{key}=#{value}" end)
  end

  defp template_value(nil, fallback), do: fallback
  defp template_value("", fallback), do: fallback
  defp template_value(value, _fallback), do: to_string(value)

  def saved_template_description(%{description: description})
      when is_binary(description) and description != "",
      do: description

  def saved_template_description(%{source_session: session})
      when is_binary(session) and session != "",
      do: "Exported from " <> session

  def saved_template_description(_saved), do: "Exported tmux layout"

  defp saved_template_tags(%{tags: tags}) when is_list(tags), do: tags
  defp saved_template_tags(_saved), do: []

  def saved_template_tags_string(saved), do: saved |> saved_template_tags() |> Enum.join(", ")

  def saved_session_template_tags(workspace_id) do
    workspace_id
    |> Terminals.list_saved_templates()
    |> Enum.flat_map(&saved_template_tags/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def saved_template_copy_name(saved_templates, name) do
    names =
      saved_templates
      |> Enum.map(& &1.name)
      |> MapSet.new()

    base = "#{name} (copy)"

    ([base] ++ Enum.map(2..100, &"#{name} (copy #{&1})"))
    |> Enum.find(&(not MapSet.member?(names, &1)))
    |> case do
      nil -> "#{name} (copy)"
      copy_name -> copy_name
    end
  end

  defp saved_template_window_count(saved) do
    saved
    |> saved_template_windows()
    |> length()
  end

  defp saved_template_pane_count(saved) do
    saved
    |> saved_template_windows()
    |> Enum.map(&saved_template_layout_pane_count(Map.get(&1, "layout", %{})))
    |> Enum.sum()
  end

  defp saved_template_windows(%{body: %{"windows" => windows}}) when is_list(windows), do: windows
  defp saved_template_windows(_saved), do: []

  defp saved_template_layout_pane_count(%{"panes" => panes}) when is_list(panes) do
    case panes do
      [] -> 1
      _ -> panes |> Enum.map(&saved_template_layout_pane_count/1) |> Enum.sum()
    end
  end

  defp saved_template_layout_pane_count(_layout), do: 1

  defp saved_template_timestamp(%{inserted_at: %DateTime{} = inserted_at}) do
    Calendar.strftime(inserted_at, "%Y-%m-%d %H:%M UTC")
  end

  defp saved_template_timestamp(_saved), do: "saved"
end
