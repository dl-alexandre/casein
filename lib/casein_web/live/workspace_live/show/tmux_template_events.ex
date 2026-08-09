defmodule CaseinWeb.WorkspaceLive.Show.TmuxTemplateEvents do
  # Session-template handle_event clauses ("tmux:*_template*" / template
  # library) extracted from CaseinWeb.WorkspaceLive.Show. Show delegates the
  # template events here; the heavier helpers still live on Show and are called
  # back via Show.* (apply_session_template, save/update/duplicate/delete,
  # refresh_saved_session_templates, the form builders). Pure code motion.
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView

  alias Casein.Terminals
  alias CaseinWeb.WorkspaceLive.Show
  alias CaseinWeb.WorkspaceLive.Show.Overlay
  alias CaseinWeb.WorkspaceLive.Show.TemplatePanels
  alias CaseinWeb.WorkspaceLive.Show.TerminalChrome

  def handle_event("tmux:apply_template", %{"template-id" => template_id}, socket) do
    Show.apply_session_template(socket, template_id)
  end

  def handle_event("tmux:preview_template", %{"template-id" => template_id}, socket) do
    case Show.dry_run_session_template(socket, template_id) do
      {:ok, preview} ->
        {:noreply,
         socket
         |> Overlay.close_others(:template_preview)
         |> assign(:template_preview, preview)}

      {:error, :template_not_found} ->
        {:noreply,
         socket
         |> assign(:palette_open, false)
         |> put_flash(:error, "Session template not found.")}

      {:error, :unsupported_template} ->
        {:noreply,
         socket
         |> assign(:palette_open, false)
         |> put_flash(:error, "This saved template cannot be applied yet.")}
    end
  end

  def handle_event("tmux:open_template_library", _params, socket) do
    {:noreply,
     socket
     |> Overlay.close_others(:template_library)
     |> Show.refresh_saved_session_templates()
     |> assign(:template_library_open, true)
     |> assign(:template_save_form, Show.template_save_form())
     |> assign(:template_edit_id, nil)
     |> assign(:template_edit_form, Show.template_edit_form())
     |> assign(:template_duplicate_id, nil)
     |> assign(:template_duplicate_form, Show.template_duplicate_form())}
  end

  def handle_event("tmux:close_template_library", _params, socket) do
    {:noreply,
     socket
     |> assign(:template_library_open, false)
     |> assign(:template_edit_id, nil)
     |> assign(:template_edit_form, Show.template_edit_form())
     |> assign(:template_duplicate_id, nil)
     |> assign(:template_duplicate_form, Show.template_duplicate_form())}
  end

  def handle_event("tmux:filter_saved_templates", params, socket) do
    tag =
      params
      |> Map.get("tag", "")
      |> to_string()
      |> String.trim()
      |> TerminalChrome.blank_to_nil()

    {:noreply,
     socket
     |> assign(:template_tag_filter, tag)
     |> assign(:template_edit_id, nil)
     |> assign(:template_edit_form, Show.template_edit_form())
     |> assign(:template_duplicate_id, nil)
     |> assign(:template_duplicate_form, Show.template_duplicate_form())
     |> Show.refresh_saved_session_templates()
     |> assign(:template_library_open, true)}
  end

  def handle_event("tmux:save_template", %{"template" => params}, socket) do
    Show.save_current_session_template(socket, params)
  end

  def handle_event("tmux:edit_saved_template", %{"template-id" => template_id}, socket) do
    case Terminals.get_saved_template(socket.assigns.workspace.id, template_id) do
      {:ok, saved} ->
        {:noreply,
         socket
         |> assign(:template_library_open, true)
         |> assign(:template_edit_id, saved.id)
         |> assign(:template_edit_form, Show.template_edit_form(saved))
         |> assign(:template_duplicate_id, nil)
         |> assign(:template_duplicate_form, Show.template_duplicate_form())}

      {:error, _reason} ->
        {:noreply,
         socket
         |> Show.refresh_saved_session_templates()
         |> assign(:template_library_open, true)
         |> put_flash(:error, "Saved template not found.")}
    end
  end

  def handle_event("tmux:cancel_saved_template_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:template_edit_id, nil)
     |> assign(:template_edit_form, Show.template_edit_form())}
  end

  def handle_event("tmux:update_saved_template", %{"template" => params}, socket) do
    Show.update_saved_session_template(socket, params)
  end

  def handle_event("tmux:duplicate_saved_template_start", %{"template-id" => template_id}, socket) do
    case Terminals.get_saved_template(socket.assigns.workspace.id, template_id) do
      {:ok, saved} ->
        {:noreply,
         socket
         |> assign(:template_library_open, true)
         |> assign(:template_edit_id, nil)
         |> assign(:template_edit_form, Show.template_edit_form())
         |> assign(:template_duplicate_id, saved.id)
         |> assign(:template_duplicate_form, Show.template_duplicate_form(socket, saved))}

      {:error, _reason} ->
        {:noreply,
         socket
         |> Show.refresh_saved_session_templates()
         |> assign(:template_library_open, true)
         |> put_flash(:error, "Saved template not found.")}
    end
  end

  def handle_event("tmux:cancel_saved_template_duplicate", _params, socket) do
    {:noreply,
     socket
     |> assign(:template_duplicate_id, nil)
     |> assign(:template_duplicate_form, Show.template_duplicate_form())}
  end

  def handle_event("tmux:duplicate_saved_template", %{"template" => params}, socket) do
    Show.duplicate_saved_session_template(socket, params)
  end

  def handle_event("tmux:delete_saved_template", %{"template-id" => template_id}, socket) do
    Show.delete_saved_session_template(socket, template_id)
  end

  def handle_event("tmux:cancel_template_preview", _params, socket) do
    {:noreply, assign(socket, :template_preview, nil)}
  end

  def handle_event("tmux:apply_previewed_template", params, socket) do
    case socket.assigns[:template_preview] do
      %{template: %{id: template_id}} ->
        mode =
          Map.get(params, "mode") ||
            TemplatePanels.template_preview_default_apply_mode(socket.assigns.template_preview)

        socket
        |> assign(:template_preview, nil)
        |> Show.apply_session_template(template_id, reconcile: mode == "reconcile")

      _ ->
        {:noreply, assign(socket, :template_preview, nil)}
    end
  end
end
