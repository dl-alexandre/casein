defmodule DevIDE.Terminals.Templates.Reconciler do
  @moduledoc """
  Read-only diff engine for saved DevIDE session template v2 exports.

  The reconciler compares a saved template's exact replay plan with the
  current tmux topology and reports what could be reused versus created. It is
  deliberately side-effect free; executable reconciliation is a later step.
  """

  alias DevIDE.Terminals.Templates.Executor

  @type saved :: map()

  @spec diff(map(), saved(), keyword()) :: {:ok, map()} | {:error, term()}
  def diff(topology, saved, opts \\ []) when is_map(topology) and is_map(saved) do
    with {:ok, dry_run} <- Executor.dry_run(saved, opts) do
      workspace_root = Keyword.get(opts, :workspace_root)
      window_plans = window_plans(dry_run.steps)
      pane_plans = pane_plans(dry_run.steps)
      select_steps = Enum.filter(dry_run.steps, &(&1.action == "select_pane"))
      current_windows = field(topology, :windows, [])

      {window_changes, window_matches} = match_windows(window_plans, current_windows)

      {pane_changes, pane_matches} =
        match_panes(pane_plans, window_matches, current_windows, workspace_root)

      select_changes = select_changes(select_steps, pane_matches)
      changes = index_changes(window_changes ++ pane_changes ++ select_changes)
      summary = summarize(changes)

      {:ok,
       %{
         template: dry_run.template,
         template_id: saved.id,
         session: field(topology, :session),
         strategy: "reconcile",
         summary: summary,
         estimated_disruption: estimated_disruption(summary),
         changes: changes
       }}
    end
  end

  defp window_plans(steps) do
    steps
    |> Enum.filter(&(&1.action == "new_window"))
    |> Enum.with_index(1)
    |> Enum.map(fn {step, index} ->
      %{
        ref: step.ref,
        name: get_in(step, [:params, :name]),
        cwd: get_in(step, [:params, :cwd]),
        index: index
      }
    end)
  end

  defp pane_plans(steps) do
    steps
    |> Enum.reduce({%{}, []}, fn step, {panes, order} ->
      case step.action do
        "new_window" ->
          ref = root_ref(step.ref)

          pane = %{
            ref: ref,
            window_ref: step.ref,
            name: "root",
            cwd: get_in(step, [:params, :cwd]),
            command: nil,
            target_ref: nil,
            source_action: "root"
          }

          {Map.put(panes, ref, pane), order ++ [ref]}

        "split_pane" ->
          ref = step.ref

          pane = %{
            ref: ref,
            window_ref: window_ref_for_pane(ref),
            name: pane_name(ref),
            cwd: get_in(step, [:params, :cwd]),
            command: nil,
            target_ref: step.target_ref,
            source_action: "split_pane",
            direction: get_in(step, [:params, :direction])
          }

          {Map.put(panes, ref, pane), order ++ [ref]}

        "send_command" ->
          target_ref = step.target_ref

          pane =
            panes
            |> Map.get(target_ref, %{
              ref: target_ref,
              window_ref: window_ref_for_pane(target_ref),
              name: pane_name(target_ref),
              target_ref: nil,
              source_action: "unknown"
            })
            |> Map.merge(%{
              command: get_in(step, [:params, :command]),
              cwd: get_in(step, [:params, :cwd]) || Map.get(panes[target_ref] || %{}, :cwd)
            })

          order = if target_ref in order, do: order, else: order ++ [target_ref]
          {Map.put(panes, target_ref, pane), order}

        _other ->
          {panes, order}
      end
    end)
    |> then(fn {panes, order} ->
      order
      |> Enum.uniq()
      |> Enum.map(&Map.fetch!(panes, &1))
    end)
  end

  defp match_windows(window_plans, current_windows) do
    Enum.reduce(window_plans, {[], %{}, MapSet.new()}, fn plan, {changes, matches, used_ids} ->
      {window, reason} = find_window_match(plan, current_windows, used_ids)

      change =
        if window do
          %{
            action: "reuse_window",
            target_id: field(window, :id),
            template_ref: window_template_ref(plan),
            current_ref: window_current_ref(window),
            reason: reason
          }
        else
          %{
            action: "create_window",
            target_id: nil,
            template_ref: window_template_ref(plan),
            current_ref: nil,
            reason: "no_matching_window"
          }
        end

      used_ids = if window, do: MapSet.put(used_ids, field(window, :id)), else: used_ids
      matches = if window, do: Map.put(matches, plan.ref, window), else: matches
      {changes ++ [change], matches, used_ids}
    end)
    |> then(fn {changes, matches, _used_ids} -> {changes, matches} end)
  end

  defp match_panes(pane_plans, window_matches, current_windows, workspace_root) do
    Enum.reduce(pane_plans, {[], %{}, %{}}, fn plan, {changes, matches, used_by_window} ->
      window = Map.get(window_matches, plan.window_ref)

      {change_group, matches, used_by_window} =
        cond do
          is_nil(window) ->
            {missing_window_pane_changes(plan, matches), matches, used_by_window}

          true ->
            available = pane_list(window, current_windows)
            used_ids = Map.get(used_by_window, field(window, :id), MapSet.new())
            {pane, reason} = find_pane_match(plan, available, used_ids, workspace_root)

            if pane do
              change = %{
                action: "reuse_pane",
                target_id: field(pane, :id),
                template_ref: pane_template_ref(plan),
                current_ref: pane_current_ref(pane),
                reason: reason
              }

              matches = Map.put(matches, plan.ref, pane)

              used_by_window =
                Map.put(
                  used_by_window,
                  field(window, :id),
                  MapSet.put(used_ids, field(pane, :id))
                )

              {[change], matches, used_by_window}
            else
              {unmatched_existing_window_pane_changes(plan, window, matches), matches,
               used_by_window}
            end
        end

      {changes ++ change_group, matches, used_by_window}
    end)
    |> then(fn {changes, matches, _used_by_window} -> {changes, matches} end)
  end

  defp missing_window_pane_changes(plan, matches) do
    case plan.source_action do
      "root" -> command_changes(plan, nil, "new_window_root_command")
      _ -> split_and_command_changes(plan, matches, "no_matching_window")
    end
  end

  defp unmatched_existing_window_pane_changes(%{source_action: "root"} = plan, window, _matches) do
    root_pane =
      window
      |> pane_list([])
      |> List.first()

    command_changes(plan, root_pane, "root_pane_signature_mismatch")
  end

  defp unmatched_existing_window_pane_changes(plan, _window, matches) do
    split_and_command_changes(plan, matches, "no_matching_pane_signature")
  end

  defp split_and_command_changes(plan, matches, reason) do
    target = Map.get(matches, plan.target_ref)

    split_change = %{
      action: "split_pane",
      target_id: field(target, :id),
      template_ref: pane_template_ref(plan),
      current_ref: pane_current_ref(target),
      reason: reason,
      direction: plan[:direction]
    }

    [split_change | command_changes(plan, nil, "new_pane_command")]
  end

  defp command_changes(%{command: command} = plan, target, reason)
       when is_binary(command) and command != "" do
    [
      %{
        action: "send_command",
        target_id: field(target, :id),
        template_ref: pane_template_ref(plan),
        current_ref: pane_current_ref(target),
        reason: reason,
        command: command,
        cwd: plan[:cwd]
      }
    ]
  end

  defp command_changes(_plan, _target, _reason), do: []

  defp select_changes(select_steps, pane_matches) do
    Enum.map(select_steps, fn step ->
      target = Map.get(pane_matches, step.target_ref)

      %{
        action: "select_pane",
        target_id: field(target, :id),
        template_ref: %{ref: step.target_ref},
        current_ref: pane_current_ref(target),
        reason: "startup_focus"
      }
    end)
  end

  defp find_window_match(plan, current_windows, used_ids) do
    by_name =
      Enum.find(current_windows, fn window ->
        not MapSet.member?(used_ids, field(window, :id)) and field(window, :name) == plan.name
      end)

    cond do
      by_name ->
        {by_name, "name_match"}

      by_index = find_window_by_index(current_windows, plan.index, used_ids) ->
        {by_index, "index_match"}

      true ->
        {nil, nil}
    end
  end

  defp find_window_by_index(current_windows, index, used_ids) do
    Enum.find(current_windows, fn window ->
      not MapSet.member?(used_ids, field(window, :id)) and field(window, :index) == index - 1
    end) ||
      Enum.at(Enum.reject(current_windows, &MapSet.member?(used_ids, field(&1, :id))), index - 1)
  end

  defp find_pane_match(plan, panes, used_ids, workspace_root) do
    panes
    |> Enum.reject(&MapSet.member?(used_ids, field(&1, :id)))
    |> Enum.map(&pane_match_score(plan, &1, workspace_root))
    |> Enum.reject(fn {_pane, score, _reason} -> score == 0 end)
    |> Enum.max_by(fn {_pane, score, _reason} -> score end, fn -> nil end)
    |> case do
      {pane, _score, reason} -> {pane, reason}
      nil -> {nil, nil}
    end
  end

  defp pane_match_score(plan, pane, workspace_root) do
    cwd_match? = cwd_match?(plan[:cwd], field(pane, :current_path), workspace_root)
    command_match? = command_match?(plan[:command], field(pane, :current_command))

    cond do
      cwd_match? and command_match? -> {pane, 3, "signature_match"}
      cwd_match? -> {pane, 2, "cwd_match"}
      command_match? -> {pane, 1, "command_match"}
      true -> {pane, 0, nil}
    end
  end

  defp cwd_match?(nil, _current, _workspace_root), do: false
  defp cwd_match?(_template, nil, _workspace_root), do: false

  defp cwd_match?(template, current, workspace_root) when is_binary(template) do
    template
    |> resolve_template_path(workspace_root)
    |> case do
      nil -> false
      resolved -> Path.expand(resolved) == Path.expand(current)
    end
  end

  defp cwd_match?(_template, _current, _workspace_root), do: false

  defp command_match?(nil, _current), do: false
  defp command_match?(_template, nil), do: false

  defp command_match?(template, current) when is_binary(template) and is_binary(current) do
    normalize_command(template) == normalize_command(current)
  end

  defp command_match?(_template, _current), do: false

  defp resolve_template_path("${workspace_root}", workspace_root) when is_binary(workspace_root),
    do: workspace_root

  defp resolve_template_path("${workspace_root}/" <> relative, workspace_root)
       when is_binary(workspace_root),
       do: Path.join(workspace_root, relative)

  defp resolve_template_path(path, _workspace_root) when is_binary(path), do: path

  defp normalize_command(command) do
    command
    |> String.trim()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
  end

  defp pane_list(window, _current_windows) when is_map(window) do
    case field(window, :pane_list, []) do
      panes when is_list(panes) -> panes
      _ -> []
    end
  end

  defp pane_list(_window, _current_windows), do: []

  defp summarize(changes) do
    %{
      reuse_windows: count_action(changes, "reuse_window"),
      create_windows: count_action(changes, "create_window"),
      reuse_panes: count_action(changes, "reuse_pane"),
      new_panes: count_action(changes, "split_pane"),
      send_commands: count_action(changes, "send_command"),
      select_panes: count_action(changes, "select_pane"),
      resize_panes: count_action(changes, "resize_pane"),
      change_count: length(changes)
    }
  end

  defp count_action(changes, action), do: Enum.count(changes, &(&1.action == action))

  defp estimated_disruption(%{create_windows: 0, new_panes: 0, send_commands: 0}), do: "low"

  defp estimated_disruption(%{create_windows: windows, new_panes: panes})
       when windows > 1 or panes > 4, do: "high"

  defp estimated_disruption(_summary), do: "medium"

  defp index_changes(changes) do
    changes
    |> Enum.with_index(1)
    |> Enum.map(fn {change, index} -> Map.put(change, :index, index) end)
  end

  defp window_template_ref(plan), do: compact(%{ref: plan.ref, name: plan.name, cwd: plan.cwd})

  defp window_current_ref(window) do
    compact(%{
      id: field(window, :id),
      index: field(window, :index),
      name: field(window, :name)
    })
  end

  defp pane_template_ref(plan) do
    compact(%{
      ref: plan.ref,
      window_ref: plan.window_ref,
      target_ref: plan[:target_ref],
      name: plan[:name],
      cwd: plan[:cwd],
      command: plan[:command]
    })
  end

  defp pane_current_ref(nil), do: nil

  defp pane_current_ref(pane) do
    compact(%{
      id: field(pane, :id),
      index: field(pane, :index),
      window_id: field(pane, :window_id),
      cwd: field(pane, :current_path),
      command: field(pane, :current_command)
    })
  end

  defp root_ref("window:" <> window_id), do: "pane:" <> window_id <> ":root"
  defp root_ref(ref), do: ref <> ":root"

  defp window_ref_for_pane("pane:" <> rest) do
    rest
    |> String.split(":", parts: 2)
    |> List.first()
    |> then(&("window:" <> &1))
  end

  defp window_ref_for_pane(_ref), do: nil

  defp pane_name("pane:" <> rest) do
    rest
    |> String.split(":")
    |> List.last()
  end

  defp pane_name(_ref), do: nil

  defp field(nil, _key), do: nil
  defp field(map, key), do: field(map, key, nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_value, _key, default), do: default

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
