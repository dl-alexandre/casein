defmodule Casein.Agents.PreviewTools.Interactions do
  @moduledoc false

  alias Casein.Agents.PreviewTools.ControlSession
  alias Casein.Agents.PreviewTools.BrowserControl
  alias Casein.PreviewControl

  def navigate(params) when is_map(params) do
    with {:ok, id} <- parse_id(Map.get(params, "session_id") || Map.get(params, :session_id)),
         path when is_binary(path) <-
           Map.get(params, "path") || Map.get(params, :path) ||
             {:error, {:missing_argument, "path"}} do
      PreviewControl.navigate(id, path)
    end
  end

  defdelegate navigate_pane(params), to: ControlSession
  defdelegate observe_pane(workspace, params), to: ControlSession
  defdelegate observe(params), to: ControlSession
  defdelegate observe_live(params), to: ControlSession
  defdelegate elements(params), to: ControlSession
  defdelegate click(params), to: ControlSession
  defdelegate type(params), to: ControlSession
  defdelegate press(params), to: ControlSession

  def screenshot(%{"session_id" => id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.screenshot(id))

  def screenshot(%{session_id: id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.screenshot(id))

  def screenshot(id) when is_integer(id), do: PreviewControl.screenshot(id)

  def compare_snapshots(workspace, params) when is_map(workspace) and is_map(params) do
    with {:ok, a} <- required_string(params, :artifact_a),
         {:ok, b} <- required_string(params, :artifact_b) do
      PreviewControl.compare_snapshots(workspace, a, b)
    end
  end

  def record_start(%{"session_id" => id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.record_start(id))

  def record_start(%{session_id: id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.record_start(id))

  def record_start(id) when is_integer(id), do: PreviewControl.record_start(id)

  def record_stop(%{"session_id" => id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.record_stop(id))

  def record_stop(%{session_id: id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.record_stop(id))

  def record_stop(id) when is_integer(id), do: PreviewControl.record_stop(id)

  defdelegate close(params), to: ControlSession

  def get_storage(%{"session_id" => id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.get_storage(id))

  def get_storage(%{session_id: id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.get_storage(id))

  def get_storage(id) when is_integer(id), do: PreviewControl.get_storage(id)

  def clear_storage(%{"session_id" => id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.clear_storage(id))

  def clear_storage(%{session_id: id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.clear_storage(id))

  def clear_storage(id) when is_integer(id), do: PreviewControl.clear_storage(id)

  defdelegate report_errors(params), to: ControlSession

  def reload_iframe(workspace, params) when is_map(workspace) and is_map(params) do
    BrowserControl.reload_preview_iframe(workspace, browser_control_opts(params))
  end

  def reload_page(workspace, params) when is_map(workspace) and is_map(params) do
    BrowserControl.reload_page(workspace, browser_control_opts(params))
  end

  defdelegate compute_affected_element_ids(observation, regions), to: ControlSession
  defdelegate enrich_observation_diff_for_test(observation), to: ControlSession
  defdelegate preview_diff_opts_for_test(params), to: ControlSession

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_session_id}
    end
  end

  defp parse_id(_), do: {:error, :invalid_session_id}

  defp required_string(params, key) do
    case Map.get(params, Atom.to_string(key)) || Map.get(params, key) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:missing_argument, key}}
    end
  end

  defp browser_control_opts(params) do
    [
      actor_id: Map.get(params, "actor_id") || Map.get(params, :actor_id),
      reason: Map.get(params, "reason") || Map.get(params, :reason)
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end
end
