defmodule DevIDE.UAT.Replay do
  @moduledoc """
  Deterministic replay of a frozen `DevIDE.UAT.Trace` — the Tier A engine. No
  LLM: every action and assertion is driven mechanically through
  `DevIDE.PreviewControl`, so a green run never touches an agent.

  ## Outcomes

    * `:pass`    — every action ran and every assertion held
    * `:fail`    — an assertion failed (a real regression candidate)
    * `:drift`   — an *action* step's frozen target no longer resolves against
      the live page (`Matcher` returned `:no_match`/`:ambiguous`). Distinct from
      `:fail` so the runner escalates to self-heal (UI changed) instead of
      red-flagging a regression.
    * `:errored` — `PreviewControl` itself returned an error (origin rejected,
      session gone): infrastructure, not a product verdict.

  `:drift` and `:errored` halt the run (subsequent steps can't be trusted);
  assertion failures are collected so one run reports every broken assertion.
  The run is persisted as a `DevIDE.UAT.Run` with the structured verdict.
  """

  alias DevIDE.Agents.PreviewTools
  alias DevIDE.PreviewControl
  alias DevIDE.UAT.{Matcher, Run, Trace, Visual}

  @action_kinds ~w(navigate click type press)a

  @doc """
  Replay `trace` against `workspace`, persisting and returning a `DevIDE.UAT.Run`.

  Options:

    * `:tier` — `:tier_a` (default) or `:tier_b`
    * `:target_instance` — label for the instance under test (default `"memory"`)
    * `:repo` — Ecto repo (default `DevIde.Repo`)
    * any other option is forwarded to `PreviewControl.open_session/3`
      (e.g. `:actor_id`, `:adapter`)
  """
  @spec run(Trace.t(), map(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def run(%Trace{} = trace, workspace, opts \\ []) do
    {repo, open_opts} = Keyword.pop(opts, :repo, DevIde.Repo)
    {tier, open_opts} = Keyword.pop(open_opts, :tier, :tier_a)
    {target_instance, open_opts} = Keyword.pop(open_opts, :target_instance, "memory")

    with {:ok, session} <- open(trace, workspace, open_opts) do
      # Everything that drives the session must be inside the `after`, so a raise
      # in execute/classify still closes the session (no leaked ControlSession).
      try do
        results = execute(trace.steps, session.id, open_opts)
        outcome = classify(results)
        persist(repo, trace, session.id, tier, target_instance, outcome, results)
      after
        PreviewControl.close_session(session.id)
      end
    end
  end

  defp open(%Trace{target: target} = _trace, workspace, opts) do
    case target do
      %{"localhost_port" => port} = t when is_integer(port) ->
        PreviewControl.open_localhost_session(
          workspace,
          port,
          Keyword.put(opts, :path, t["path"] || "/")
        )

      %{"surface" => surface} ->
        PreviewControl.open_session(workspace, surface, opts)

      _ ->
        {:error, {:invalid_target, target}}
    end
  end

  # Execute steps in order, halting on the first drift/error.
  defp execute(steps, session_id, opts) do
    steps
    |> Enum.reduce_while([], fn step, acc ->
      result = execute_step(step, session_id, opts)
      acc = [result | acc]

      case result.status do
        status when status in [:drift, :error] -> {:halt, acc}
        _ -> {:cont, acc}
      end
    end)
    |> Enum.reverse()
  end

  defp execute_step(%{kind: kind} = step, session_id, _opts) when kind in @action_kinds do
    do_action(step, session_id)
  end

  defp execute_step(%{kind: kind} = step, session_id, opts) do
    evaluate_assertion(step, session_id, kind, opts)
  end

  # --- actions --------------------------------------------------------------

  defp do_action(%{kind: :navigate, path: path}, session_id) do
    case PreviewControl.navigate(session_id, path || "/") do
      {:ok, _obs} -> step_result(:navigate, :ok, %{path: path})
      {:error, reason} -> step_result(:navigate, :error, %{reason: inspect(reason)})
    end
  end

  defp do_action(%{kind: :press, key: key}, session_id) do
    case PreviewControl.press(session_id, key || "Enter") do
      {:ok, _obs} -> step_result(:press, :ok, %{key: key})
      {:error, reason} -> step_result(:press, :error, %{reason: inspect(reason)})
    end
  end

  defp do_action(%{kind: :click, match: match}, session_id) do
    with_resolved(session_id, match, :click, fn element ->
      case PreviewControl.click(session_id, %{selector: field(element, :selector)}) do
        {:ok, _obs} -> step_result(:click, :ok, %{selector: field(element, :selector)})
        {:error, reason} -> step_result(:click, :error, %{reason: inspect(reason)})
      end
    end)
  end

  defp do_action(%{kind: :type, match: match, text: text}, session_id) do
    with_resolved(session_id, match, :type, fn element ->
      case PreviewControl.type(session_id, field(element, :selector), text || "", %{}) do
        {:ok, _obs} -> step_result(:type, :ok, %{selector: field(element, :selector)})
        {:error, reason} -> step_result(:type, :error, %{reason: inspect(reason)})
      end
    end)
  end

  # Resolve a frozen matcher to a live element; an unresolvable target on an
  # action step is *drift*, not a failure.
  defp with_resolved(session_id, match, kind, fun) do
    with {:ok, elements} <- fetch_elements(session_id),
         {:ok, element} <- Matcher.resolve(elements, match || %{}) do
      fun.(element)
    else
      {:error, reason} when reason in [:no_match, :ambiguous] ->
        step_result(kind, :drift, %{match: match, reason: reason})

      {:error, reason} ->
        step_result(kind, :error, %{reason: inspect(reason)})
    end
  end

  defp fetch_elements(session_id) do
    case PreviewTools.elements(%{session_id: session_id}) do
      {:ok, %{elements: elements}} -> {:ok, elements}
      {:ok, %{"elements" => elements}} -> {:ok, elements}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_elements, other}}
    end
  end

  # --- assertions -----------------------------------------------------------

  defp evaluate_assertion(
         %{kind: :assert_element, match: match, presence: presence},
         session_id,
         _,
         _opts
       ) do
    present? =
      case fetch_elements(session_id) do
        {:ok, elements} -> match?({:ok, _}, Matcher.resolve(elements, match || %{}))
        _ -> false
      end

    want = presence != false
    status = if present? == want, do: :pass, else: :fail
    step_result(:assert_element, status, %{expected_present: want, actual_present: present?})
  end

  defp evaluate_assertion(%{kind: :assert_url, matches: pattern}, session_id, _, _opts) do
    url =
      case PreviewControl.observe(session_id) do
        {:ok, obs} -> obs[:url] || obs["url"] || ""
        _ -> ""
      end

    status = if pattern && String.contains?(url, pattern), do: :pass, else: :fail
    step_result(:assert_url, status, %{pattern: pattern, url: url})
  end

  defp evaluate_assertion(%{kind: :assert_no_errors} = step, session_id, _, _opts) do
    %{console_errors: console, network_errors: network} = PreviewControl.latest_errors(session_id)

    console_bad = step.console != false and console != []
    network_bad = step.network != false and network != []
    status = if console_bad or network_bad, do: :fail, else: :pass

    step_result(:assert_no_errors, status, %{
      console_errors: length(console),
      network_errors: length(network)
    })
  end

  # Advisory visual tier: never :fail. Default-off → :skipped; match → :pass;
  # mismatch → :warn. None of these are in classify's fail/drift/error set, so a
  # flaky pixel diff can never gate the run.
  defp evaluate_assertion(%{kind: :assert_screenshot} = step, session_id, _, opts) do
    if Keyword.get(opts, :visual, false) do
      actual = capture_screenshot(session_id)
      {:ok, result} = Visual.compare(actual, step.baseline, compare_opts(step, opts))
      status = if result.match, do: :pass, else: :warn

      step_result(:assert_screenshot, status, %{
        baseline: step.baseline,
        distance: result.distance,
        reason: result.reason
      })
    else
      step_result(:assert_screenshot, :skipped, %{baseline: step.baseline, disabled: true})
    end
  end

  defp compare_opts(step, opts) do
    base = [threshold: step.threshold || 0.0]
    if differ = opts[:differ], do: Keyword.put(base, :differ, differ), else: base
  end

  defp capture_screenshot(session_id) do
    case PreviewControl.screenshot(session_id) do
      {:ok, obs} -> obs[:artifact_path] || obs["artifact_path"]
      _ -> nil
    end
  end

  # --- classification + persistence -----------------------------------------

  defp classify(results) do
    statuses = Enum.map(results, & &1.status)

    # :fail outranks :drift — a regression already observed before a later drift
    # must be flagged, never routed to self-heal (which could "heal away" a bug).
    cond do
      :error in statuses -> :errored
      :fail in statuses -> :fail
      :drift in statuses -> :drift
      true -> :pass
    end
  end

  defp persist(repo, trace, session_id, tier, target_instance, outcome, results) do
    verdict = %{
      "outcome" => Atom.to_string(outcome),
      "criterion" => trace.criterion,
      "steps" => Enum.map(results, &encode_result/1)
    }

    %Run{}
    |> Run.changeset(%{
      scenario_id: trace.id,
      tier: tier,
      target_instance: target_instance,
      session_id: session_id,
      outcome: outcome,
      verdict: verdict
    })
    |> repo.insert()
  end

  defp encode_result(%{kind: kind, status: status, detail: detail}) do
    %{
      "kind" => Atom.to_string(kind),
      "status" => Atom.to_string(status),
      "detail" => stringify(detail)
    }
  end

  defp step_result(kind, status, detail), do: %{kind: kind, status: status, detail: detail}

  defp field(element, field),
    do: Map.get(element, field) || Map.get(element, Atom.to_string(field))

  defp stringify(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp stringify(value), do: value
end
