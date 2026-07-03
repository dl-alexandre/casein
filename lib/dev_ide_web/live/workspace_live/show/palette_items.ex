defmodule DevIdeWeb.WorkspaceLive.Show.PaletteItems do
  @moduledoc false

  alias DevIDE.CommandPalette
  alias DevIDE.CommandPalette.Fuzzy
  alias DevIDE.CommandPalette.Item, as: PaletteItem
  alias DevIDE.CommandPalette.Usage
  alias DevIDE.Previews
  alias DevIDE.Terminals
  alias DevIdeWeb.WorkspaceLive.Show.TerminalState
  alias DevIdeWeb.WorkspaceLive.Show.WindowTerminalMode

  @max_results 50

  @single_pane_hidden_ids ~w(
    tmux:next_pane
    tmux:previous_pane
    tmux:close_other_panes
    tmux:cycle_layout
    tmux:equalize
  )

  # Static items whose handlers deny via the tmux-mutation gate — hidden when
  # mutations are disallowed so the palette never offers a permanently-failing
  # action (and habit-recording can't boost one; see PaletteEvents).
  @mutation_gated_ids ~w(
    tmux:new_window
    tmux:consolidate_sessions
    agents:apply_pair
  )

  @doc "Static item ids whose dispatch is denied when tmux mutations are off."
  def mutation_gated_ids, do: @mutation_gated_ids

  @spec query(map(), String.t() | nil) :: [PaletteItem.t()]
  def query(socket, q) do
    query = q || ""
    root = palette_root(socket)
    category = socket.assigns[:palette_category] || :all
    usage = socket.assigns[:palette_usage] || %{}
    now = DateTime.utc_now()

    # Frecency (see `Usage.boost/2` for the cap rationale) is threaded INTO
    # CommandPalette.query so static/file items are boosted before that
    # query's own sort + take — boosting after would never promote an item
    # the upstream truncation already cut. Dynamic items are boosted here.
    static_items =
      (root || "")
      |> CommandPalette.query(query, category: category, usage: usage, now: now)
      |> relabel_terminal_mode_items(socket)
      |> filter_static_tmux(socket, query)

    dynamic_items =
      (workflow_items(socket, query, category) ++
         shell_item(socket, query, category) ++
         session_items(socket, query, category) ++
         window_items(socket, query, category) ++
         template_items(socket, query, category) ++
         pane_items(socket, query, category) ++
         rename_items(socket, query, category) ++
         preview_surface_items(socket, query, category))
      |> apply_frecency(usage, now)

    (static_items ++ dynamic_items)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(@max_results)
  end

  defp apply_frecency(items, usage, now) when is_map(usage) and map_size(usage) > 0 do
    Enum.map(items, &%{&1 | score: &1.score + Usage.boost(usage[&1.id], now)})
  end

  defp apply_frecency(items, _usage, _now), do: items

  @spec resolve(map(), String.t() | nil, String.t()) :: {:ok, map()} | :error
  def resolve(socket, _root, "session:switch:" <> session_id) do
    case find_session_tab(socket, session_id) do
      nil ->
        :error

      tab ->
        params =
          %{"session-id" => tab.id}
          |> maybe_put("tmux-session", tab.tmux_session)

        {:ok, %{event: "attach_terminal_session", params: params}}
    end
  end

  def resolve(socket, _root, "session:window:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [session_id, window_id] ->
        case find_session_tab(socket, session_id) do
          nil ->
            :error

          tab ->
            params =
              %{"session-id" => tab.id, "window-id" => window_id}
              |> maybe_put("tmux-session", tab.tmux_session)

            {:ok, %{event: "attach_terminal_session", params: params}}
        end

      _ ->
        :error
    end
  end

  def resolve(socket, _root, "window:switch:" <> window_id) do
    if window_known?(socket, window_id) do
      {:ok, %{event: "tmux:select_window", params: %{"window-id" => window_id}}}
    else
      :error
    end
  end

  def resolve(socket, _root, "pane:focus:" <> pane_id) do
    if Enum.any?(socket.assigns[:tmux_panes] || [], &(&1.id == pane_id)) do
      {:ok, %{event: "tmux:select_pane", params: %{"pane-id" => pane_id}}}
    else
      :error
    end
  end

  def resolve(socket, _root, "template:preview:" <> template_id) do
    case get_session_template(socket, template_id) do
      {:ok, _template} ->
        {:ok, %{event: "tmux:preview_template", params: %{"template-id" => template_id}}}

      {:error, _reason} ->
        :error
    end
  end

  def resolve(_socket, _root, "workflow:hint:" <> _spec_id) do
    {:ok, %{event: "workflow:hint", params: %{}}}
  end

  def resolve(socket, _root, "workflow:run:" <> spec_id) do
    workspace_id = socket.assigns.workspace.id

    case Enum.find(Terminals.workflow_specs(workspace_id), &(&1.id == spec_id)) do
      nil ->
        :error

      spec ->
        if Terminals.workflow_palette_runnable?(spec) do
          {:ok,
           %{
             event: "workflow:run",
             params: %{"command-id" => Terminals.workflow_command_id(spec)}
           }}
        else
          :error
        end
    end
  end

  def resolve(socket, _root, "preview:surface:" <> surface_name) do
    case Previews.get_surface(socket.assigns.workspace, surface_name) do
      nil -> :error
      _surface -> {:ok, preview_surface_payload(surface_name)}
    end
  end

  def resolve(socket, _root, "rename:window:" <> window_id) do
    if TerminalState.tmux_mutations_allowed?(socket) and window_known?(socket, window_id) do
      {:ok, %{event: "tmux:rename_start", params: %{"window-id" => window_id}}}
    else
      :error
    end
  end

  def resolve(socket, _root, "rename:session:" <> session_id) do
    if TerminalState.tmux_mutations_allowed?(socket) and
         session_id == socket.assigns[:terminal_sid] do
      {:ok, %{event: "terminal:rename_session_start", params: %{"session-id" => session_id}}}
    else
      :error
    end
  end

  def resolve(socket, _root, "template:apply:" <> template_id) do
    with true <- TerminalState.tmux_mutations_allowed?(socket),
         {:ok, _template} <- get_session_template(socket, template_id) do
      {:ok, %{event: "tmux:apply_template", params: %{"template-id" => template_id}}}
    else
      _ -> :error
    end
  end

  def resolve(_socket, root, id) when is_binary(id), do: CommandPalette.resolve(root, id)

  defp palette_root(socket) do
    case socket.assigns[:host_path] do
      {:ok, root} when is_binary(root) -> root
      _ -> nil
    end
  end

  defp relabel_terminal_mode_items(items, socket) do
    window_name = WindowTerminalMode.active_window_name(socket)

    if is_binary(window_name) and window_name != "" do
      Enum.map(items, fn
        %{id: "action:terminal:raw"} = item ->
          %{
            item
            | label: "Focus terminal (window: #{window_name})",
              detail: "Focus the terminal pane for tmux window \"#{window_name}\""
          }

        item ->
          item
      end)
    else
      items
    end
  end

  defp filter_static_tmux(items, socket, query) do
    items
    |> then(fn items ->
      if single_pane?(socket) and query == "" do
        Enum.reject(items, &(&1.id in @single_pane_hidden_ids))
      else
        items
      end
    end)
    |> then(fn items ->
      if TerminalState.tmux_mutations_allowed?(socket) do
        items
      else
        Enum.reject(items, &(&1.id in @mutation_gated_ids))
      end
    end)
  end

  defp workflow_items(socket, query, category) when category in [:all, :commands] do
    workspace_id = socket.assigns.workspace.id

    Terminals.workflow_specs(workspace_id)
    |> Enum.flat_map(fn spec ->
      searchable =
        Enum.join(
          [
            "Run",
            "Team workflow",
            "Shortcut",
            spec.name,
            spec.description,
            spec.command,
            spec.id
          ],
          " "
        )

      case Fuzzy.score(searchable, query) do
        nil ->
          []

        score ->
          if Terminals.workflow_palette_runnable?(spec) do
            [
              %PaletteItem{
                id: "workflow:run:" <> spec.id,
                kind: :command,
                category: :commands,
                label: "Run " <> spec.name,
                detail: spec.description,
                score: score + 200,
                payload: %{
                  event: "workflow:run",
                  params: %{"command-id" => Terminals.workflow_command_id(spec)}
                }
              }
            ]
          else
            [
              %PaletteItem{
                id: "workflow:hint:" <> spec.id,
                kind: :command,
                category: :commands,
                label: spec.name,
                detail: spec.command <> " — type this in the command line",
                score: score,
                payload: %{event: "workflow:hint", params: %{}}
              }
            ]
          end
      end
    end)
  end

  defp workflow_items(_socket, _query, _category), do: []

  defp shell_item(socket, query, category) when category in [:all, :tmux] do
    default_sid = socket.assigns[:default_terminal_sid]
    current_sid = socket.assigns[:terminal_sid]

    if is_binary(default_sid) and is_binary(current_sid) and current_sid != default_sid do
      searchable = "Return to workspace shell Session Switch detach"

      case Fuzzy.score(searchable, query) do
        nil ->
          []

        score ->
          [
            %PaletteItem{
              id: "session:switch:shell",
              kind: :action,
              category: :tmux,
              label: "Return to workspace shell",
              detail: "Switch back to the default terminal session",
              hint: "C-b d",
              score: score + 1_800,
              payload: %{event: "terminal:switch_to_shell", params: %{}}
            }
          ]
      end
    else
      []
    end
  end

  defp shell_item(_socket, _query, _category), do: []

  defp session_items(socket, query, category) when category in [:all, :tmux] do
    active_sid = socket.assigns[:terminal_sid]

    (socket.assigns[:session_tabs] || [])
    |> Enum.flat_map(fn tab ->
      session_row(tab, query, active_sid) ++ session_window_rows(tab, query, active_sid)
    end)
  end

  defp session_items(_socket, _query, _category), do: []

  defp session_row(tab, query, active_sid) do
    searchable =
      Enum.join(
        ["Switch session", "Session", tab.label, tab.detail, tab.title, tab.id, tab.tmux_session],
        " "
      )

    case Fuzzy.score(searchable, query) do
      nil ->
        []

      score ->
        boost = if tab.id == active_sid, do: 2_000, else: 0

        [
          %PaletteItem{
            id: "session:switch:" <> tab.id,
            kind: :action,
            category: :tmux,
            label: "Switch session: " <> tab.label,
            detail: tab.detail,
            score: score + boost,
            payload: %{
              event: "attach_terminal_session",
              params:
                %{"session-id" => tab.id}
                |> maybe_put("tmux-session", tab.tmux_session)
            }
          }
        ]
    end
  end

  defp session_window_rows(tab, query, active_sid) do
    if tab.id == active_sid do
      []
    else
      Enum.flat_map(tab.windows || [], &session_window_row(tab, &1, query))
    end
  end

  defp session_window_row(tab, window, query) do
    window_id = window.id

    if is_binary(window_id) and window_id != "" do
      searchable =
        Enum.join(
          [
            "Switch window",
            "Window",
            window.name,
            tab.label,
            window_id,
            to_string(window.index)
          ],
          " "
        )

      case Fuzzy.score(searchable, query) do
        nil ->
          []

        score ->
          boost = if window.active?, do: 1_500, else: 0

          [
            %PaletteItem{
              id: "session:window:" <> tab.id <> ":" <> window_id,
              kind: :action,
              category: :tmux,
              label: "Switch window: " <> window.name,
              detail: tab.label <> " · window " <> to_string(window.index),
              score: score + boost,
              payload: %{
                event: "attach_terminal_session",
                params:
                  %{
                    "session-id" => tab.id,
                    "window-id" => window_id
                  }
                  |> maybe_put("tmux-session", tab.tmux_session)
              }
            }
          ]
      end
    else
      []
    end
  end

  defp window_items(socket, query, category) when category in [:all, :tmux] do
    active_window_id = socket.assigns[:tmux_active_window_id]

    Enum.flat_map(socket.assigns[:tmux_window_tabs] || [], fn window ->
      searchable =
        Enum.join(
          [
            "Switch window",
            "Window",
            window.name,
            window.full_title,
            window.command,
            window.id,
            to_string(window.index)
          ],
          " "
        )

      case Fuzzy.score(searchable, query) do
        nil ->
          []

        score ->
          boost = if window.id == active_window_id, do: 1_500, else: 0

          [
            %PaletteItem{
              id: "window:switch:" <> window.id,
              kind: :action,
              category: :tmux,
              label: "Switch window: " <> window.name,
              detail: window.full_title,
              score: score + boost,
              payload: %{
                event: "tmux:select_window",
                params: %{"window-id" => window.id}
              }
            }
          ]
      end
    end)
  end

  defp window_items(_socket, _query, _category), do: []

  defp template_items(_socket, "", _category), do: []

  defp template_items(socket, query, category) when category in [:all, :tmux] do
    mutations? = TerminalState.tmux_mutations_allowed?(socket)

    socket
    |> palette_session_templates()
    |> Enum.flat_map(fn template ->
      searchable =
        Enum.join(
          [
            "Template",
            "Session Template",
            "Apply template",
            "Preview template",
            template.source_label,
            template.name,
            template.description,
            template.id
          ],
          " "
        )

      case Fuzzy.score(searchable, query) do
        nil ->
          []

        score ->
          rows = [
            %PaletteItem{
              id: "template:preview:" <> template.id,
              kind: :action,
              category: :tmux,
              label: "Preview template: " <> template.name,
              detail: template.description,
              score: score,
              payload: %{
                event: "tmux:preview_template",
                params: %{"template-id" => template.id}
              }
            }
          ]

          if mutations? do
            [
              %PaletteItem{
                id: "template:apply:" <> template.id,
                kind: :action,
                category: :tmux,
                label: "Apply template: " <> template.name,
                detail: template.source_label <> " · " <> template.description,
                score: score + 50,
                payload: %{
                  event: "tmux:apply_template",
                  params: %{"template-id" => template.id}
                }
              }
              | rows
            ]
          else
            rows
          end
      end
    end)
  end

  defp template_items(_socket, _query, _category), do: []

  defp pane_items(socket, query, category) when category in [:all, :tmux] do
    if single_pane?(socket) do
      []
    else
      Enum.flat_map(socket.assigns[:tmux_panes] || [], fn pane ->
        pane_row(socket, pane, query)
      end)
    end
  end

  defp pane_items(_socket, _query, _category), do: []

  # Inline-rename openers for the active window and current session. Offered
  # only when tmux mutations are allowed (same gate as template:apply); the
  # rename handlers re-check server-side.
  defp rename_items(socket, query, category) when category in [:all, :tmux] do
    if TerminalState.tmux_mutations_allowed?(socket) do
      rename_window_item(socket, query) ++ rename_session_item(socket, query)
    else
      []
    end
  end

  defp rename_items(_socket, _query, _category), do: []

  defp rename_window_item(socket, query) do
    active_id = socket.assigns[:tmux_active_window_id]

    with window when not is_nil(window) <-
           Enum.find(socket.assigns[:tmux_window_tabs] || [], &(&1.id == active_id)),
         searchable = Enum.join(["Rename window", window.name, window.id], " "),
         score when not is_nil(score) <- Fuzzy.score(searchable, query) do
      [
        %PaletteItem{
          id: "rename:window:" <> window.id,
          kind: :action,
          category: :tmux,
          label: "Rename window: " <> window.name,
          detail: "Open inline rename for the active tmux window",
          hint: "C-b ,",
          score: score,
          payload: %{event: "tmux:rename_start", params: %{"window-id" => window.id}}
        }
      ]
    else
      _ -> []
    end
  end

  defp rename_session_item(socket, query) do
    sid = socket.assigns[:terminal_sid]

    with true <- is_binary(sid) and sid != "",
         label = session_label(socket, sid),
         searchable = Enum.join(["Rename session", label, sid], " "),
         score when not is_nil(score) <- Fuzzy.score(searchable, query) do
      [
        %PaletteItem{
          id: "rename:session:" <> sid,
          kind: :action,
          category: :tmux,
          label: "Rename session: " <> label,
          detail: "Open inline rename for the current session",
          hint: "C-b $",
          score: score,
          payload: %{event: "terminal:rename_session_start", params: %{"session-id" => sid}}
        }
      ]
    else
      _ -> []
    end
  end

  defp session_label(socket, sid) do
    case Enum.find(socket.assigns[:session_tabs] || [], &(&1.id == sid)) do
      %{label: label} when is_binary(label) and label != "" -> label
      _ -> "workspace shell"
    end
  end

  # One item per named preview surface (manager URLs, host DevIDE, and
  # terminal-detected localhost:PORT candidates). Surfaces come from workspace
  # metadata, so listing them is cheap on the query path.
  defp preview_surface_items(socket, query, category) when category in [:all, :preview] do
    socket.assigns.workspace
    |> Previews.discover_surfaces()
    |> Enum.flat_map(fn surface ->
      title = surface.title || surface.name

      searchable =
        Enum.join(["Preview", "Open preview", surface.name, title, surface.url], " ")

      case Fuzzy.score(searchable, query) do
        nil ->
          []

        score ->
          [
            %PaletteItem{
              id: "preview:surface:" <> surface.name,
              kind: :action,
              category: :preview,
              label: "Preview: Open " <> title,
              detail: surface.url,
              score: score,
              payload: preview_surface_payload(surface.name)
            }
          ]
      end
    end)
  end

  defp preview_surface_items(_socket, _query, _category), do: []

  defp preview_surface_payload(surface_name) do
    %{event: "preview:open", params: %{"surface" => surface_name, "mode" => "tab"}}
  end

  defp pane_row(socket, pane, query) do
    pane_id = pane.id
    label = "Pane #{pane.index}"
    detail = pane_palette_detail(socket, pane)
    searchable = Enum.join([label, detail, pane_id, "Focus pane"], " ")

    case Fuzzy.score(searchable, query) do
      nil ->
        []

      score ->
        boost =
          cond do
            socket.assigns[:tmux_active_pane_id] == pane_id -> 1_200
            pane.active -> 800
            true -> 0
          end

        [
          %PaletteItem{
            id: "pane:focus:" <> pane_id,
            kind: :action,
            category: :tmux,
            label: label,
            detail: detail,
            score: score + boost,
            payload: %{event: "tmux:select_pane", params: %{"pane-id" => pane_id}}
          }
        ]
    end
  end

  defp pane_palette_detail(socket, pane) do
    flags =
      []
      |> maybe_add_flag(pane.active, "active")
      |> maybe_add_flag(socket.assigns[:tmux_active_pane_id] == pane.id, "focused")

    title =
      case pane do
        %{current_path: path, current_command: cmd} when is_binary(path) ->
          Path.basename(path) <> " · " <> to_string(cmd)

        %{current_command: cmd} ->
          to_string(cmd)

        _ ->
          nil
      end

    [Enum.reverse(flags), title]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp maybe_add_flag(flags, true, flag), do: [flag | flags]
  defp maybe_add_flag(flags, false, _flag), do: flags

  defp palette_session_templates(socket) do
    built_in =
      (socket.assigns[:session_templates] || Terminals.session_templates())
      |> Enum.map(fn template ->
        %{
          id: template.id,
          name: template.name,
          description: template.description || "",
          source_label: "Built-in"
        }
      end)

    saved =
      (socket.assigns[:saved_session_templates] || [])
      |> Enum.filter(&Terminals.saved_template_apply_supported?/1)
      |> Enum.map(fn template ->
        %{
          id: template.id,
          name: template.name,
          description: saved_template_description(template),
          source_label: "Saved"
        }
      end)

    built_in ++ saved
  end

  defp saved_template_description(template) do
    case Map.get(template, :description) do
      description when is_binary(description) and description != "" -> description
      _ -> ""
    end
  end

  defp find_session_tab(socket, "shell") do
    default_sid = socket.assigns[:default_terminal_sid]

    if is_binary(default_sid) do
      %{id: default_sid, tmux_session: socket.assigns[:tmux_session]}
    end
  end

  defp find_session_tab(socket, session_id) do
    Enum.find(socket.assigns[:session_tabs] || [], &(&1.id == session_id))
  end

  defp window_known?(socket, window_id) do
    Enum.any?(socket.assigns[:tmux_window_tabs] || [], &(&1.id == window_id))
  end

  defp single_pane?(socket) do
    length(socket.assigns[:tmux_panes] || []) <= 1
  end

  defp get_session_template(socket, template_id) do
    case Terminals.get_session_template(template_id) do
      {:ok, template} ->
        {:ok, template}

      {:error, :template_not_found} ->
        case Terminals.get_saved_template(socket.assigns.workspace.id, template_id) do
          {:ok, saved} ->
            if Terminals.saved_template_apply_supported?(saved),
              do: {:ok, saved},
              else: {:error, :unsupported_template}

          {:error, :not_found} ->
            {:error, :template_not_found}
        end
    end
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, _key, ""), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)
end
