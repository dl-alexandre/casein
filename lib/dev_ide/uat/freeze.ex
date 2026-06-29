defmodule DevIDE.UAT.Freeze do
  @moduledoc """
  Freezes a `DevIDE.UAT.Trace` from the audit trail of a successful authoring
  run. The acceptance agent drives the `preview_*` MCP tools; every action it
  takes is a `DevIDE.Previews.ControlAction` row whose `result` holds the full
  observation (including `dom_summary`). Freeze reads those rows in order and
  reconstructs a durable, replayable trace — resolving each action's target to a
  CSS selector plus the role/name observed at author time, never the positional
  `element_id` (see `DevIDE.UAT.Trace`).

  Only replayable verbs become steps; `observe`/`screenshot` actions are skipped.
  Assertions are not inferred here — they are added by the author harness from
  the criterion. Freeze produces the *action* spine of the trace with full
  provenance back-references (`action_id`, `observation_id`).
  """

  import Ecto.Query

  alias DevIDE.Previews.{ControlAction, ControlObservation}
  alias DevIDE.UAT.{Step, Trace}

  @verb_kinds %{"navigate" => :navigate, "click" => :click, "type" => :type, "press" => :press}

  @doc """
  Build a `Trace` from `session_id`'s recorded actions.

  `attrs` supplies the trace metadata the audit trail can't: `:id` (required),
  `:criterion` (required), `:target`, `:identity`, `:provenance` (merged with the
  derived `authored_by_session`). `opts[:repo]` overrides the repo (default
  `DevIde.Repo`).
  """
  @spec from_session(integer(), map(), keyword()) :: {:ok, Trace.t()} | {:error, term()}
  def from_session(session_id, attrs, opts \\ []) do
    repo = Keyword.get(opts, :repo, DevIde.Repo)

    with {:ok, id} <- fetch(attrs, :id),
         {:ok, criterion} <- fetch(attrs, :criterion) do
      obs_by_action = dom_observation_ids(repo, session_id)

      steps =
        repo
        |> actions(session_id)
        |> Enum.map(&step_for(&1, obs_by_action))
        |> Enum.reject(&is_nil/1)

      trace = %Trace{
        id: id,
        criterion: criterion,
        target: Map.get(attrs, :target, %{}),
        identity: Map.get(attrs, :identity),
        provenance: build_provenance(attrs, session_id),
        steps: steps
      }

      {:ok, trace}
    end
  end

  defp actions(repo, session_id) do
    repo.all(
      from a in ControlAction,
        where: a.session_id == ^session_id,
        order_by: [asc: a.inserted_at, asc: a.id]
    )
  end

  # action_id => the dom_summary observation id for that action.
  defp dom_observation_ids(repo, session_id) do
    repo.all(
      from o in ControlObservation,
        where:
          o.session_id == ^session_id and o.kind == "dom_summary" and not is_nil(o.action_id),
        order_by: [asc: o.id],
        select: {o.action_id, o.id}
    )
    |> Map.new()
  end

  defp step_for(%ControlAction{action: verb} = action, obs_by_action) do
    case Map.get(@verb_kinds, verb) do
      nil -> nil
      kind -> build_step(kind, action, obs_by_action)
    end
  end

  defp build_step(:navigate, action, obs),
    do: step(:navigate, action, obs, path: param(action, "url"))

  defp build_step(:press, action, obs), do: step(:press, action, obs, key: param(action, "key"))

  defp build_step(:click, action, obs) do
    step(:click, action, obs, match: match_for(action))
  end

  defp build_step(:type, action, obs) do
    step(:type, action, obs, match: match_for(action), text: param(action, "text"))
  end

  defp step(kind, action, obs_by_action, fields) do
    from = %{
      "action_id" => action.id,
      "observation_id" => Map.get(obs_by_action, action.id)
    }

    struct(Step, [{:kind, kind}, {:from, from} | fields])
  end

  # Resolve a durable matcher: the selector the action used, enriched with the
  # role/name observed for that selector at author time (for disambiguation).
  defp match_for(action) do
    selector = param(action, "selector")
    enrich = element_attrs(action, selector)

    %{"selector" => selector}
    |> put_present("role", enrich["role"])
    |> put_present("name", enrich["name"])
  end

  defp element_attrs(%ControlAction{result: result}, selector)
       when is_map(result) and is_binary(selector) do
    result
    |> get_in(["dom_summary", "elements"])
    |> List.wrap()
    |> Enum.find(%{}, fn el -> is_map(el) and el["selector"] == selector end)
  end

  defp element_attrs(_action, _selector), do: %{}

  defp build_provenance(attrs, session_id) do
    attrs
    |> Map.get(:provenance, %{})
    |> stringify_keys()
    |> Map.put("authored_by_session", session_id)
  end

  defp param(%ControlAction{params: params}, key) when is_map(params), do: Map.get(params, key)
  defp param(_action, _key), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp stringify_keys(%{} = map),
    do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp fetch(attrs, key) do
    case Map.get(attrs, key) do
      nil -> {:error, {:missing, key}}
      "" -> {:error, {:missing, key}}
      value -> {:ok, value}
    end
  end
end
