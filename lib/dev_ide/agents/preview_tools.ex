defmodule DevIDE.Agents.PreviewTools do
  @moduledoc """
  Narrow agent-facing preview operations.

  Agents can open workspace surfaces, observe pages, interact with trusted
  previews, and capture evidence — without arbitrary browser or external URL
  access.

  Each preview tool is a `Jido.Action` module under `DevIDE.Agents.PreviewTools.*`,
  invoked through `DevIDE.Agents.ToolAction`: params are schema-validated at
  runtime while the MCP wire shapes (tools/list JSON Schema, error
  structuredContent) stay exactly as before.
  """

  alias DevIDE.Agents.PreviewTools.{
    ClearStorage,
    Click,
    Close,
    CompareSnapshots,
    DevideReloadPage,
    Elements,
    EnsureServerHere,
    GetStorage,
    Impl,
    Navigate,
    NavigatePane,
    Observe,
    ObserveLive,
    ObservePane,
    Open,
    OpenApp,
    OpenCurrentWorkspace,
    OpenHere,
    OpenLocalhost,
    PlaybackOpen,
    Press,
    RecordStart,
    RecordStop,
    ReloadIframe,
    ReportErrors,
    ResolveWorkspace,
    Screenshot,
    Surfaces,
    Type
  }

  alias DevIDE.Agents.ToolAction
  alias McpCtl.Tool

  @type tool :: Tool.t()

  @actions [
    ResolveWorkspace,
    Surfaces,
    Open,
    OpenCurrentWorkspace,
    OpenHere,
    EnsureServerHere,
    OpenApp,
    OpenLocalhost,
    Navigate,
    NavigatePane,
    ObservePane,
    Observe,
    ObserveLive,
    Elements,
    Click,
    Type,
    Press,
    Screenshot,
    CompareSnapshots,
    RecordStart,
    RecordStop,
    PlaybackOpen,
    Close,
    GetStorage,
    ClearStorage,
    ReportErrors,
    ReloadIframe,
    DevideReloadPage
  ]

  @by_name Map.new(@actions, &{&1.name(), &1})

  @doc "Tool definitions exposed to agent runtimes."
  @spec definitions() :: [tool()]
  def definitions, do: Enum.map(@actions, &ToolAction.definition/1)

  @doc "Dispatch a named agent preview tool."
  @spec invoke(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def invoke(tool_name, workspace, params)
      when is_map(workspace) and is_map(params) do
    params = merge_workspace_params(workspace, params)

    case Map.fetch(@by_name, tool_name) do
      {:ok, action} -> ToolAction.invoke(action, params, %{workspace: workspace})
      :error -> {:error, :unknown_tool}
    end
  end

  defp merge_workspace_params(workspace, params) do
    params
    |> maybe_put_workspace_param("workspace_id", workspace, :id)
    |> maybe_put_workspace_param("workspace_path", workspace, :path)
  end

  defp maybe_put_workspace_param(params, key, workspace, field) do
    if present_param?(params, key) do
      params
    else
      case Map.get(workspace, field) || Map.get(workspace, to_string(field)) do
        value when is_binary(value) and value != "" -> Map.put(params, key, value)
        _ -> params
      end
    end
  end

  defp present_param?(params, key) when is_binary(key) do
    case Map.get(params, key) do
      value when is_binary(value) -> String.trim(value) != ""
      value when not is_nil(value) -> true
      _ -> false
    end
  end

  defdelegate surfaces(workspace, params \\ %{}), to: Impl
  defdelegate registration_origin(registration), to: Impl
  defdelegate open_app_preview(workspace, params \\ %{}), to: Impl
  defdelegate open_app_here(workspace, params \\ %{}), to: Impl
  defdelegate ensure_server_here(workspace, params \\ %{}), to: Impl
  defdelegate open_localhost_preview(workspace, params), to: Impl
  defdelegate split_preview_pane(workspace, url, opts), to: Impl
  defdelegate navigate(params), to: Impl
  defdelegate navigate_pane(params), to: Impl
  defdelegate observe_pane(workspace, params), to: Impl
  defdelegate observe(params), to: Impl
  defdelegate observe_live(params), to: Impl
  defdelegate elements(params), to: Impl
  defdelegate click(params), to: Impl
  defdelegate type(params), to: Impl
  defdelegate press(params), to: Impl
  defdelegate screenshot(params), to: Impl
  defdelegate compare_snapshots(workspace, params), to: Impl
  defdelegate record_start(params), to: Impl
  defdelegate record_stop(params), to: Impl
  defdelegate playback_open(workspace, params), to: Impl
  defdelegate close(params), to: Impl
  defdelegate get_storage(params), to: Impl
  defdelegate clear_storage(params), to: Impl
  defdelegate report_errors(params), to: Impl
  defdelegate reload_iframe(workspace, params), to: Impl
  defdelegate reload_page(workspace, params), to: Impl
  defdelegate compute_affected_element_ids(observation, regions), to: Impl
  defdelegate enrich_observation_diff_for_test(observation), to: Impl
  defdelegate preview_diff_opts_for_test(params), to: Impl
  defdelegate list_surfaces(workspace), to: Impl
end
