defmodule Casein.Agents.JidoDelegate do
  @moduledoc """
  Manager-facing Jido admit/status/cancel with OpenCode `worker_launch` fallback.

  External managers call this instead of driving tmux. Only supported typed Jido
  actions are admitted. Code mutations use CodeTools; reporting and human-input
  actions use the typed Jido catalog. `runtime: :opencode` or a disabled workspace flag
  returns a fallback receipt naming `worker_launch`.
  """

  alias Casein.Agents.{JidoActions, JidoPod, JidoSkills}
  alias Casein.Agents.JidoPod.CodeActions

  @max_actions 16
  @allowed_actions CodeActions.allowed()

  @type fallback :: %{
          runtime: :opencode,
          fallback?: true,
          reason: atom(),
          headless: false,
          pane_required?: true,
          next_tool: String.t(),
          next_arguments: map(),
          dry_run: boolean()
        }

  @spec select(String.t(), keyword() | map()) :: {:ok, map()} | {:error, map()}
  def select(workspace_id, opts \\ %{})

  def select(workspace_id, opts) when is_binary(workspace_id) and is_list(opts) do
    select(workspace_id, Map.new(opts))
  end

  def select(workspace_id, opts) when is_binary(workspace_id) and is_map(opts) do
    with :ok <- validate_requested_runtime(opts) do
      case JidoSkills.select(workspace_id, opts) do
        {:ok, selection} -> {:ok, selection_receipt(selection, workspace_id, opts)}
        {:error, error} -> {:error, error}
      end
    end
  end

  def select(_workspace_id, _opts) do
    {:error, %{error: :invalid, result: :invalid, message: "workspace_id required"}}
  end

  @spec admit(map()) :: {:ok, map()} | {:error, map()}
  def admit(attrs) when is_map(attrs) do
    with {:ok, workspace_id} <- required_id(attrs, :workspace_id),
         {:ok, actions} <- normalize_actions(attrs),
         {:ok, selection} <- select(workspace_id, attrs) do
      cond do
        selection.fallback? ->
          {:ok, selection}

        truthy?(get(attrs, :dry_run)) ->
          {:ok, Map.put(selection, :next_tool, "jido_admit")}

        true ->
          start_attempt(workspace_id, attrs, actions, selection)
      end
    end
  end

  def admit(_),
    do: {:error, %{error: :invalid, result: :invalid, message: "admit attrs required"}}

  @spec status(map()) :: {:ok, map()} | {:error, map()}
  def status(attrs) when is_map(attrs) do
    with {:ok, workspace_id} <- required_id(attrs, :workspace_id),
         {:ok, attempt_id} <- required_id(attrs, :attempt_id) do
      wrap_pod(JidoPod.status(workspace_id, attempt_id), workspace_id)
    end
  end

  def status(_) do
    {:error, %{error: :invalid, result: :invalid, message: "status attrs required"}}
  end

  @spec cancel(map()) :: {:ok, map()} | {:error, map()}
  def cancel(attrs) when is_map(attrs) do
    with {:ok, workspace_id} <- required_id(attrs, :workspace_id),
         {:ok, attempt_id} <- required_id(attrs, :attempt_id) do
      wrap_pod(JidoPod.cancel(workspace_id, attempt_id), workspace_id)
    end
  end

  def cancel(_) do
    {:error, %{error: :invalid, result: :invalid, message: "cancel attrs required"}}
  end

  defp start_attempt(workspace_id, attrs, actions, selection) do
    admit_attrs =
      %{workspace_id: workspace_id, runtime: :jido, actions: actions}
      |> maybe_put(:task_id, get(attrs, :task_id))
      |> maybe_put(:attempt_id, get(attrs, :attempt_id))
      |> maybe_put(:worktree_path, get(attrs, :worktree_path))
      |> maybe_put(:principal, get(attrs, :principal))
      |> maybe_put(:deadline_ms, get(attrs, :deadline_ms))
      |> maybe_put(:action_timeout_ms, get(attrs, :action_timeout_ms))
      |> maybe_put(:max_retries, get(attrs, :max_retries))

    case JidoPod.admit(admit_attrs) do
      {:ok, attempt} ->
        {:ok,
         attempt
         |> Map.merge(selection)
         |> Map.put(:next_tool, "jido_status")
         |> Map.put(:next_arguments, %{
           workspace_id: workspace_id,
           attempt_id: attempt.attempt_id
         })}

      {:error, :legacy_opencode} ->
        {:ok, fallback_receipt(workspace_id, :legacy_opencode, attrs)}

      {:error, reason} ->
        {:error, pod_error(reason, workspace_id)}
    end
  end

  defp selection_receipt(%{runtime: :opencode} = selection, workspace_id, opts) do
    Map.merge(fallback_receipt(workspace_id, selection.reason, opts), %{
      skill: selection.skill,
      supported?: selection.supported?,
      missing: selection.missing
    })
  end

  defp selection_receipt(selection, workspace_id, opts) do
    %{
      runtime: :jido,
      fallback?: false,
      reason: selection.reason,
      workspace_id: workspace_id,
      skill: selection.skill,
      supported?: selection.supported?,
      missing: selection.missing,
      model: selection.model,
      provider: selection.provider,
      headless: true,
      pane_required?: false,
      dry_run: truthy?(get(opts, :dry_run)),
      next_tool: "jido_admit"
    }
  end

  defp fallback_receipt(workspace_id, reason, opts) do
    %{
      runtime: :opencode,
      fallback?: true,
      reason: reason,
      workspace_id: workspace_id,
      headless: false,
      pane_required?: true,
      dry_run: truthy?(get(opts, :dry_run)),
      next_tool: "worker_launch",
      next_arguments: %{
        workspace_id: workspace_id,
        runtime: "opencode"
      },
      message: "Jido is not selected; use worker_launch for the OpenCode path"
    }
  end

  defp wrap_pod({:ok, attempt}, workspace_id) do
    {:ok,
     attempt
     |> Map.put(:runtime, :jido)
     |> Map.put(:fallback?, false)
     |> Map.put(:headless, true)
     |> Map.put(:pane_required?, false)
     |> Map.put(:workspace_id, workspace_id)}
  end

  defp wrap_pod({:error, reason}, workspace_id), do: {:error, pod_error(reason, workspace_id)}

  defp pod_error(:not_found, workspace_id) do
    %{
      error: :not_found,
      result: :denied,
      workspace_id: workspace_id,
      message: "no Jido attempt found",
      retryable: false
    }
  end

  defp pod_error(:already_terminal, workspace_id) do
    %{
      error: :already_terminal,
      result: :stale_attempt,
      workspace_id: workspace_id,
      message: "attempt is already terminal",
      retryable: false
    }
  end

  defp pod_error(reason, workspace_id) when is_atom(reason) do
    %{
      error: reason,
      result: :denied,
      workspace_id: workspace_id,
      message: "jido #{reason}",
      retryable: reason in [:backpressure, :queue_full, :provider_limit]
    }
  end

  defp pod_error(%{} = reason, workspace_id) do
    Map.merge(%{workspace_id: workspace_id, result: :denied}, reason)
  end

  defp pod_error(reason, workspace_id) do
    %{
      error: :failed,
      result: :denied,
      workspace_id: workspace_id,
      message: inspect(reason),
      retryable: false
    }
  end

  defp normalize_actions(attrs) do
    case get(attrs, :actions) || [] do
      actions when is_list(actions) and length(actions) > @max_actions ->
        {:error,
         %{
           error: :too_many_actions,
           result: :invalid,
           message: "at most #{@max_actions} typed Jido actions",
           retryable: false
         }}

      actions when is_list(actions) ->
        actions
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {action, index}, {:ok, acc} ->
          case normalize_action(action, index) do
            {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
            {:error, error} -> {:halt, {:error, error}}
          end
        end)

      _ ->
        {:error,
         %{
           error: :invalid,
           result: :invalid,
           message: "actions must be a list of typed Jido steps",
           retryable: false
         }}
    end
  end

  defp normalize_action(name, index) when is_binary(name) do
    normalize_action(%{name: name, args: %{}}, index)
  end

  defp normalize_action(action, index) when is_map(action) do
    name = get(action, :name)

    cond do
      not is_binary(name) or name == "" ->
        {:error,
         %{
           error: :invalid,
           result: :invalid,
           index: index,
           message: "each action needs a name",
           retryable: false
         }}

      JidoActions.forbidden?(name) ->
        {:error,
         %{
           error: :not_allowed,
           result: :denied,
           action: name,
           index: index,
           message: "raw keystrokes, pane scrapes, and tmux are not Jido actions",
           retryable: false
         }}

      name not in @allowed_actions ->
        {:error,
         %{
           error: if(JidoActions.spec(name), do: :not_yet_supported, else: :unknown_tool),
           result: :not_yet_supported,
           action: name,
           index: index,
           message: "only supported typed Jido actions are admitted",
           allowed: @allowed_actions,
           retryable: false
         }}

      true ->
        {:ok,
         %{
           name: name,
           args: sanitize_args(get(action, :args) || %{}),
           mutation_token: get(action, :mutation_token)
         }
         |> reject_nil()}
    end
  end

  defp normalize_action(_action, index) do
    {:error,
     %{
       error: :invalid,
       result: :invalid,
       index: index,
       message: "action must be a map with name and optional args",
       retryable: false
     }}
  end

  defp sanitize_args(args) when is_map(args) do
    Map.drop(args, [
      :workspace_id,
      "workspace_id",
      :attempt_id,
      "attempt_id",
      :task_id,
      "task_id",
      :worktree_path,
      "worktree_path",
      :actor,
      "actor",
      :actor_id,
      "actor_id",
      :principal,
      "principal"
    ])
  end

  defp sanitize_args(_), do: %{}

  defp validate_requested_runtime(opts) do
    case requested_runtime(opts) do
      runtime when runtime in [nil, :jido, :opencode] ->
        :ok

      other ->
        {:error,
         %{
           error: :invalid,
           result: :invalid,
           runtime: other,
           message: "jido_admit runtime must be jido or opencode",
           retryable: false
         }}
    end
  end

  defp requested_runtime(opts) do
    case get(opts, :runtime) do
      :opencode -> :opencode
      "opencode" -> :opencode
      :jido -> :jido
      "jido" -> :jido
      nil -> nil
      "" -> nil
      other -> other
    end
  end

  defp required_id(attrs, key) do
    case get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_argument, to_string(key)}}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp reject_nil(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp get(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp truthy?(value), do: value in [true, "true", "1", 1]
end
