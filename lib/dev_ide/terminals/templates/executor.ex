defmodule DevIDE.Terminals.Templates.Executor do
  @moduledoc """
  Plans and executes saved DevIDE session template v2 exports.

  This is intentionally imperative: it creates new tmux windows and panes from
  the saved tree, sends captured command hints, then restores focus. It does
  not attempt declarative reconciliation against existing panes yet.
  """

  alias DevIDE.Terminals.Tmux
  alias DevIDE.Terminals.TmuxTopology

  @type saved :: map()

  @spec dry_run(saved(), keyword()) :: {:ok, map()} | {:error, atom()}
  def dry_run(saved, opts \\ []) when is_map(saved) do
    with {:ok, steps, focus_ref} <- build_steps(saved, opts) do
      steps = add_focus_step(steps, focus_ref)

      {:ok,
       %{
         dry_run: true,
         template: template_summary(saved),
         step_count: length(steps),
         steps: index_steps(steps)
       }}
    end
  end

  @spec execute(String.t(), saved(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(session, saved, opts \\ []) when is_binary(session) and is_map(saved) do
    with {:ok, dry_run} <- dry_run(saved, opts),
         {:ok, result} <- execute_steps(session, dry_run, opts) do
      {:ok, result}
    end
  end

  defp build_steps(saved, _opts) do
    body = saved.body || %{}

    case body do
      %{"version" => 2, "windows" => windows} when is_list(windows) and windows != [] ->
        template_root = Map.get(body, "root")
        startup = Map.get(body, "startup", %{})

        {step_groups, focus_ref} =
          windows
          |> Enum.with_index(1)
          |> Enum.reduce({[], nil}, fn {window, index}, {step_groups, acc_focus} ->
            {window_steps, window_focus} =
              plan_window(window, index, template_root, startup)

            {[window_steps | step_groups], window_focus || acc_focus}
          end)

        steps = step_groups |> Enum.reverse() |> List.flatten()

        {:ok, steps, focus_ref}

      %{"version" => 2} ->
        {:error, :windows_required}

      _ ->
        {:error, :unsupported_template}
    end
  end

  defp plan_window(window, index, template_root, startup) do
    window_name = string_field(window, "name") || "window-#{index}"
    window_ref = "window:" <> stable_ref(window_name, index)
    root_ref = pane_ref(window_ref, "root")
    layout = Map.get(window, "layout", %{})
    root_cwd = string_field(window, "root") || first_leaf_cwd(layout) || template_root

    create_step = %{
      action: "new_window",
      ref: window_ref,
      params: compact(%{name: window_name, cwd: root_cwd})
    }

    {layout_steps, layout_focus_ref} =
      plan_layout(layout, %{
        target_ref: root_ref,
        window_ref: window_ref,
        template_root: template_root,
        window_root: string_field(window, "root"),
        split_index: 1,
        startup_pane: Map.get(startup, "pane")
      })

    window_focus_ref =
      cond do
        layout_focus_ref -> layout_focus_ref
        Map.get(startup, "window") == window_name -> root_ref
        truthy?(Map.get(window, "focus")) -> root_ref
        true -> nil
      end

    {[create_step | layout_steps], window_focus_ref}
  end

  defp plan_layout(%{"direction" => direction, "panes" => panes}, ctx)
       when is_list(panes) and panes != [] do
    direction = normalize_direction(direction)

    if direction == "tiled" do
      plan_tiled(panes, ctx)
    else
      plan_split_children(panes, direction, ctx)
    end
  end

  defp plan_layout(leaf, ctx) when is_map(leaf) do
    plan_leaf(leaf, ctx)
  end

  defp plan_layout(_leaf, _ctx), do: {[], nil}

  defp plan_split_children([first | rest], direction, ctx) do
    {first_steps, first_focus} = plan_layout(first, ctx)

    {step_groups, focus, _index} =
      Enum.reduce(rest, {[first_steps], first_focus, ctx.split_index}, fn child,
                                                                          {step_groups, focus, index} ->
        child_ref = pane_ref(ctx.window_ref, leaf_or_group_name(child, index + 1))

        split_step = %{
          action: "split_pane",
          ref: child_ref,
          target_ref: ctx.target_ref,
          params:
            compact(%{
              direction: direction,
              cwd: first_leaf_cwd(child) || ctx.window_root || ctx.template_root,
              size: Map.get(child, "size")
            })
        }

        child_ctx = %{ctx | target_ref: child_ref, split_index: index + 1}
        {child_steps, child_focus} = plan_layout(child, child_ctx)
        {[[split_step | child_steps] | step_groups], child_focus || focus, index + 1}
      end)

    steps = step_groups |> Enum.reverse() |> List.flatten()

    {steps, focus}
  end

  defp plan_tiled(panes, ctx) do
    plan_split_children(panes, "h", ctx)
  end

  defp plan_leaf(leaf, ctx) do
    command = string_field(leaf, "command")
    cwd = string_field(leaf, "cwd") || ctx.window_root || ctx.template_root

    steps =
      if command do
        [
          %{
            action: "send_command",
            target_ref: ctx.target_ref,
            params: compact(%{command: command, cwd: cwd})
          }
        ]
      else
        []
      end

    focus_ref =
      cond do
        string_field(leaf, "name") == ctx.startup_pane -> ctx.target_ref
        truthy?(Map.get(leaf, "focus")) -> ctx.target_ref
        true -> nil
      end

    {steps, focus_ref}
  end

  defp execute_steps(session, dry_run, opts) do
    state = %{
      session: session,
      tmux: Keyword.get(opts, :tmux, Tmux),
      workspace_root: Keyword.get(opts, :workspace_root),
      refs: %{},
      executed_steps: []
    }

    dry_run.steps
    |> Enum.reduce_while({:ok, state}, fn step, {:ok, state} ->
      case execute_step(step, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason} -> {:halt, {:error, {reason, step, execution_summary(dry_run, state)}}}
      end
    end)
    |> case do
      {:ok, state} ->
        {:ok,
         dry_run
         |> Map.take([:template, :step_count])
         |> Map.merge(%{
           executed_steps: Enum.reverse(state.executed_steps),
           refs: state.refs
         })}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_step(%{action: "new_window"} = step, state) do
    with {:ok, cwd} <- resolve_cwd(get_in(step, [:params, :cwd]), state.workspace_root),
         opts <- compact_opts(name: get_in(step, [:params, :name]), cwd: cwd),
         {:ok, window_id} <- state.tmux.new_window(state.session, opts),
         {:ok, root_pane_id} <- active_pane_for_window(state, window_id) do
      state
      |> put_ref(step.ref, window_id)
      |> put_ref(root_ref(step.ref), root_pane_id)
      |> record_step(step, %{window_id: window_id, root_pane_id: root_pane_id})
      |> ok()
    end
  end

  defp execute_step(%{action: "split_pane"} = step, state) do
    with {:ok, target_pane_id} <- resolve_ref(state, step.target_ref),
         {:ok, cwd} <- resolve_cwd(get_in(step, [:params, :cwd]), state.workspace_root),
         opts <- compact_opts(cwd: cwd),
         {:ok, pane_id} <-
           state.tmux.split_pane(
             state.session,
             target_pane_id,
             get_in(step, [:params, :direction]),
             opts
           ) do
      state
      |> put_ref(step.ref, pane_id)
      |> record_step(step, %{pane_id: pane_id, target_pane_id: target_pane_id})
      |> ok()
    end
  end

  defp execute_step(%{action: "send_command"} = step, state) do
    with {:ok, target_pane_id} <- resolve_ref(state, step.target_ref),
         :ok <-
           state.tmux.send_command(state.session, get_in(step, [:params, :command]),
             target: target_pane_id
           ) do
      state
      |> record_step(step, %{target_pane_id: target_pane_id})
      |> ok()
    end
  end

  defp execute_step(%{action: "select_pane"} = step, state) do
    with {:ok, target_pane_id} <- resolve_ref(state, step.target_ref),
         :ok <- state.tmux.select_pane(state.session, target_pane_id) do
      state
      |> record_step(step, %{pane_id: target_pane_id})
      |> ok()
    end
  end

  defp execute_step(step, _state), do: {:error, {:unsupported_step, step.action}}

  defp active_pane_for_window(state, window_id) do
    topology = TmuxTopology.snapshot(state.session, tmux: state.tmux)

    topology.windows
    |> Enum.find(&(&1.id == window_id))
    |> case do
      %{pane_list: [%{id: pane_id} | _]} -> {:ok, pane_id}
      _ -> {:error, :root_pane_not_found}
    end
  end

  defp root_ref("window:" <> window_id), do: "pane:" <> window_id <> ":root"
  defp root_ref(ref), do: ref <> ":root"

  defp put_ref(state, ref, value), do: %{state | refs: Map.put(state.refs, ref, value)}

  defp resolve_ref(%{refs: refs}, ref) do
    case Map.fetch(refs, ref) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:unresolved_ref, ref}}
    end
  end

  defp record_step(state, step, result) do
    executed_step =
      step
      |> Map.take([:index, :action, :ref, :target_ref, :params])
      |> Map.put(:result, result)

    %{state | executed_steps: [executed_step | state.executed_steps]}
  end

  defp execution_summary(dry_run, state) do
    %{
      template: dry_run.template,
      step_count: dry_run.step_count,
      executed_steps: Enum.reverse(state.executed_steps),
      refs: state.refs
    }
  end

  defp resolve_cwd(nil, _workspace_root), do: {:ok, nil}
  defp resolve_cwd("", _workspace_root), do: {:ok, nil}
  defp resolve_cwd(path, nil) when is_binary(path), do: {:ok, path}

  defp resolve_cwd("${workspace_root}", workspace_root) when is_binary(workspace_root),
    do: {:ok, workspace_root}

  defp resolve_cwd("${workspace_root}/" <> relative, workspace_root)
       when is_binary(workspace_root) do
    DevIDE.Files.PathSafety.resolve(workspace_root, relative)
  end

  defp resolve_cwd(path, workspace_root) when is_binary(path) and is_binary(workspace_root) do
    DevIDE.Files.PathSafety.resolve(workspace_root, path)
  end

  defp add_focus_step(steps, nil), do: steps

  defp add_focus_step(steps, pane_ref) do
    steps ++ [%{action: "select_pane", target_ref: pane_ref, params: %{}}]
  end

  defp index_steps(steps) do
    steps
    |> Enum.with_index(1)
    |> Enum.map(fn {step, index} -> Map.put(step, :index, index) end)
  end

  defp template_summary(saved) do
    body = saved.body || %{}

    %{
      id: saved.id,
      name: saved.name,
      description: saved.description,
      source: "exported",
      schema_version: saved.schema_version,
      windows: length(Map.get(body, "windows", []))
    }
  end

  defp leaf_or_group_name(%{"name" => name}, _index) when is_binary(name) and name != "",
    do: stable_ref(name)

  defp leaf_or_group_name(%{"panes" => [first | _rest]}, index),
    do: leaf_or_group_name(first, index)

  defp leaf_or_group_name(_child, index), do: "group-#{index}"

  defp pane_ref(window_ref, pane_name),
    do:
      "pane:" <> String.replace_prefix(window_ref, "window:", "") <> ":" <> stable_ref(pane_name)

  defp stable_ref(value, fallback_index \\ nil)
  defp stable_ref(value, _fallback_index) when is_binary(value), do: sanitize_ref(value)
  defp stable_ref(_value, index), do: "item-#{index}"

  defp sanitize_ref(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9_-]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "item"
      ref -> ref
    end
  end

  defp first_leaf_cwd(%{"direction" => _direction, "panes" => panes}) when is_list(panes) do
    panes
    |> Enum.find_value(&first_leaf_cwd/1)
  end

  defp first_leaf_cwd(%{} = leaf), do: string_field(leaf, "cwd")
  defp first_leaf_cwd(_), do: nil

  defp string_field(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp string_field(_map, _key), do: nil

  defp normalize_direction("horizontal"), do: "h"
  defp normalize_direction("vertical"), do: "v"
  defp normalize_direction("h"), do: "h"
  defp normalize_direction("v"), do: "v"
  defp normalize_direction("tiled"), do: "tiled"
  defp normalize_direction(_), do: "tiled"

  defp truthy?(value) when value in [true, 1, "1", "true", "yes", "on"], do: true
  defp truthy?(_), do: false

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp compact_opts(opts) do
    opts
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp ok(value), do: {:ok, value}
end
