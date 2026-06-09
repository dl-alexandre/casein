defmodule DevIDE.Terminals.SessionTemplate.Planner do
  @moduledoc """
  Builds dry-run tmux mutation plans from session templates.
  """

  alias DevIDE.Terminals.SessionTemplate
  alias DevIDE.Terminals.SessionTemplate.Window

  @spec plan(String.t() | SessionTemplate.t(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  def plan(template_or_id, opts \\ []) do
    with {:ok, template} <- resolve_template(template_or_id) do
      {:ok, build_plan(template, opts)}
    end
  end

  @spec dry_run(String.t() | SessionTemplate.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def dry_run(template_or_id, opts \\ []) do
    with {:ok, template} <- resolve_template(template_or_id),
         steps <- build_plan(template, opts) do
      {:ok,
       %{
         dry_run: true,
         template: template_summary(template),
         step_count: length(steps),
         steps: steps
       }}
    end
  end

  defp resolve_template(%SessionTemplate{} = template), do: {:ok, template}
  defp resolve_template(id) when is_binary(id), do: SessionTemplate.get(id)
  defp resolve_template(_), do: {:error, :template_not_found}

  defp build_plan(%SessionTemplate{} = template, opts) do
    {step_groups, focus_ref} =
      template.windows
      |> Enum.with_index(1)
      |> Enum.reduce({[], nil}, fn {window, index}, {step_groups, focus_ref} ->
        {window_steps, window_focus_ref} = plan_window(window, index, opts)
        {[window_steps | step_groups], window_focus_ref || focus_ref}
      end)

    steps = step_groups |> Enum.reverse() |> List.flatten()

    steps
    |> maybe_add_focus_step(focus_ref)
    |> Enum.with_index(1)
    |> Enum.map(fn {step, index} -> Map.put(step, :index, index) end)
  end

  defp plan_window(%Window{} = window, index, _opts) do
    window_ref = window_ref(window, index)
    root_pane_ref = pane_ref(window, "root")

    create_step = %{
      action: "new_window",
      ref: window_ref,
      params: compact(%{name: window.name, cwd: window.cwd})
    }

    command_steps =
      if window.command do
        [send_command_step(root_pane_ref, window.command, window.cwd)]
      else
        []
      end

    {pane_step_groups, pane_focus_ref} =
      window.panes
      |> Enum.with_index(1)
      |> Enum.reduce({[], nil}, fn {pane, pane_index}, {step_groups, focus_ref} ->
        ref = pane_ref(window, pane.id || "pane-#{pane_index}")

        split_step = %{
          action: "split_pane",
          ref: ref,
          target_ref: root_pane_ref,
          params:
            compact(%{
              direction: pane.split_direction,
              cwd: pane.cwd || window.cwd,
              size_percent: pane.size_percent
            })
        }

        command_steps =
          if pane.command do
            [send_command_step(ref, pane.command, pane.cwd || window.cwd)]
          else
            []
          end

        new_focus_ref = if pane.focus, do: ref, else: focus_ref
        {[[split_step | command_steps] | step_groups], new_focus_ref}
      end)

    pane_steps = pane_step_groups |> Enum.reverse() |> List.flatten()

    window_focus_ref =
      cond do
        pane_focus_ref -> pane_focus_ref
        window.focus -> root_pane_ref
        true -> nil
      end

    {[create_step | command_steps ++ pane_steps], window_focus_ref}
  end

  defp send_command_step(target_ref, command, cwd) do
    %{
      action: "send_command",
      target_ref: target_ref,
      params: compact(%{command: command, cwd: cwd})
    }
  end

  defp maybe_add_focus_step(steps, nil), do: steps

  defp maybe_add_focus_step(steps, pane_ref) do
    steps ++ [%{action: "select_pane", target_ref: pane_ref, params: %{}}]
  end

  defp template_summary(%SessionTemplate{} = template) do
    %{
      id: template.id,
      name: template.name,
      description: template.description,
      windows: length(template.windows)
    }
  end

  defp window_ref(%Window{id: id}, _index) when is_binary(id), do: "window:" <> id
  defp window_ref(_window, index), do: "window:#{index}"

  defp pane_ref(%Window{id: id}, pane_id) when is_binary(id), do: "pane:" <> id <> ":" <> pane_id
  defp pane_ref(_window, pane_id), do: "pane:window:" <> pane_id

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end
end
