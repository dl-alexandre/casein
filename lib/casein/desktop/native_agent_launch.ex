defmodule Casein.Desktop.NativeAgentLaunch do
  @moduledoc """
  Prepares native Windows agent launches without exposing workspace credentials.

  Provider diagnostics run before worktree creation. Successful preparations
  create and report an isolated worktree, materialize workspace-scoped MCP
  configuration, and return a PowerShell command containing no bearer token.
  """

  alias Casein.Desktop.{AgentEnvironment, AgentLauncher, AgentWorktree, PowerShellSession}
  alias Casein.Runtimes

  defstruct [
    :runtime,
    :worktree,
    :diagnostics,
    :command,
    :workspace,
    :workspace_id,
    environment: %{}
  ]

  @type t :: %__MODULE__{}

  @spec prepare(map(), String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def prepare(workspace, runtime, task, opts \\ [])

  def prepare(workspace, runtime, task, opts)
      when is_map(workspace) and is_binary(runtime) and is_binary(task) and is_list(opts) do
    primary = value(workspace, :path)
    workspace_id = value(workspace, :id)
    diagnoser = Keyword.get(opts, :diagnoser, &AgentLauncher.diagnose/2)
    creator = Keyword.get(opts, :creator, &AgentWorktree.create/4)
    environment_builder = Keyword.get(opts, :environment_builder, &AgentEnvironment.build/2)
    reporter = Keyword.get(opts, :reporter, &report/2)

    with :ok <- required(primary, :workspace_path_required),
         :ok <- required(workspace_id, :workspace_id_required),
         {:ok, diagnostics} <- diagnoser.(runtime, Keyword.get(opts, :diagnostic_opts, [])),
         :ok <- launchable(diagnostics),
         {:ok, worktree} <-
           creator.(primary, runtime, task, Keyword.get(opts, :worktree_opts, [])),
         {:ok, environment} <- environment_builder.(workspace, worktree.path),
         :ok <- install_provider_config(runtime, worktree.path, environment),
         {:ok, command} <-
           AgentLauncher.command(runtime, launch_context(workspace, worktree, environment)),
         {:ok, _reported} <- reporter.(workspace_id, report_attrs(runtime, worktree)) do
      {:ok,
       %__MODULE__{
         runtime: runtime,
         worktree: worktree,
         diagnostics: diagnostics,
         command: command,
         workspace: workspace,
         workspace_id: workspace_id,
         environment: environment
       }}
    else
      {:error, _reason} = error -> error
    end
  end

  def prepare(_workspace, _runtime, _task, _opts), do: {:error, :invalid_arguments}

  @doc "Prepare and start one native provider launch as a single backend transaction."
  @spec launch(map(), String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def launch(workspace, runtime, task, opts \\ [])

  def launch(workspace, runtime, task, opts)
      when is_map(workspace) and is_binary(runtime) and is_binary(task) and is_list(opts) do
    preparer = Keyword.get(opts, :preparer, &prepare/4)
    starter = Keyword.get(opts, :starter, &start/2)

    with {:ok, %__MODULE__{} = plan} <-
           preparer.(workspace, runtime, task, Keyword.get(opts, :prepare_opts, [])),
         :ok <- starter.(plan, Keyword.get(opts, :start_opts, [])) do
      {:ok, plan}
    end
  end

  def launch(_workspace, _runtime, _task, _opts), do: {:error, :invalid_arguments}

  @doc "Start a prepared provider command in its workspace-owned native ConPTY session."
  @spec start(t(), keyword()) :: :ok | {:error, term()}
  def start(plan, opts \\ [])

  def start(%__MODULE__{} = plan, opts) do
    ensure_session = Keyword.get(opts, :ensure_session, &PowerShellSession.ensure_started/2)
    send_input = Keyword.get(opts, :send_input, &PowerShellSession.send_input/2)
    reporter = Keyword.get(opts, :reporter, &report/2)

    with :ok <- ensure_session.(plan.worktree.path, plan.workspace),
         :ok <- send_input.(plan.workspace, plan.command) do
      :ok
    else
      {:error, _reason} = error ->
        _ =
          reporter.(
            plan.workspace_id,
            report_attrs(plan.runtime, plan.worktree)
            |> Map.merge(%{
              "exit_status" => "handoff",
              "handoff" => "native #{plan.runtime} session launch failed"
            })
          )

        error
    end
  end

  def start(_plan, _opts), do: {:error, :invalid_launch_plan}

  @doc "Report launch completion and remove only a clean, landed worktree."
  @spec finish(t(), String.t(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def finish(plan, exit_status, handoff \\ nil, opts \\ [])

  def finish(%__MODULE__{} = plan, exit_status, handoff, opts)
      when exit_status in ["landed", "wip", "handoff"] do
    reporter = Keyword.get(opts, :reporter, &report/2)
    git = Keyword.get(opts, :git, &run_git/2)

    attrs =
      report_attrs(plan.runtime, plan.worktree)
      |> Map.merge(%{"exit_status" => exit_status, "handoff" => handoff})

    with {:ok, _reported} <- reporter.(plan.workspace_id, attrs) do
      maybe_remove(plan, exit_status, git)
    end
  end

  def finish(_plan, _exit_status, _handoff, _opts), do: {:error, :invalid_exit_status}

  defp launchable(%{executable_status: :available, version: {:ok, _version}, auth: auth})
       when auth in [:signed_in, :provider_managed],
       do: :ok

  defp launchable(%{executable_status: :missing}), do: {:error, :executable_missing}
  defp launchable(%{auth: :not_detected}), do: {:error, :authentication_not_detected}
  defp launchable(%{version: {:error, reason}}), do: {:error, {:version_probe_failed, reason}}
  defp launchable(_diagnostics), do: {:error, :invalid_diagnostics}

  defp install_provider_config(runtime, checkout, environment) do
    staging = Map.fetch!(environment, "CASEIN_AGENT_MCP_HOME")

    case runtime do
      "grok" ->
        copy_private(Path.join([staging, "grok", ".mcp.json"]), Path.join(checkout, ".mcp.json"))

      "opencode" ->
        copy_private(
          Path.join(staging, "opencode.json"),
          Path.join([checkout, ".opencode", "opencode.json"])
        )

      _ ->
        :ok
    end
  end

  # Source and destination are derived from validated worktree and materializer roots.
  # sobelow_skip ["Traversal.FileModule"]
  defp copy_private(source, destination) do
    :ok = File.mkdir_p(Path.dirname(destination))
    :ok = File.cp(source, destination)
    File.chmod(destination, 0o600)
  end

  defp launch_context(workspace, worktree, environment) do
    %{
      checkout: worktree.path,
      staging: Map.fetch!(environment, "CASEIN_AGENT_MCP_HOME"),
      workspace_slug: workspace_slug(value(workspace, :name) || value(workspace, :id)),
      terminal_url: Map.fetch!(environment, "CASEIN_TERMINAL_MCP_URL"),
      preview_url: Map.fetch!(environment, "CASEIN_PREVIEW_MCP_URL"),
      artifact_url: Map.fetch!(environment, "CASEIN_ARTIFACT_MCP_URL")
    }
  end

  defp report_attrs(runtime, worktree) do
    %{
      "worktree_path" => worktree.path,
      "branch" => worktree.branch,
      "agent" => runtime,
      "os" => "windows",
      "source" => "native_desktop"
    }
  end

  defp report(workspace_id, attrs), do: Runtimes.observe_worktree(workspace_id, attrs)

  defp maybe_remove(plan, "landed", git) do
    case git.(["-C", plan.worktree.path, "status", "--porcelain"], []) do
      {output, 0} when output in ["", "\n", "\r\n"] ->
        case git.(
               ["-C", plan.worktree.primary, "worktree", "remove", "--", plan.worktree.path],
               []
             ) do
          {_output, 0} -> {:ok, %{removed: true, path: plan.worktree.path}}
          {output, status} -> {:error, {:worktree_remove_failed, status, bounded(output)}}
        end

      {_output, 0} ->
        {:ok, %{removed: false, path: plan.worktree.path, reason: :dirty_worktree}}

      {output, status} ->
        {:error, {:git_status_failed, status, bounded(output)}}
    end
  end

  defp maybe_remove(plan, _exit_status, _git),
    do: {:ok, %{removed: false, path: plan.worktree.path, reason: :handoff_preserved}}

  # Git is fixed and receives an argv list; no shell parses any path.
  # sobelow_skip ["CI.System"]
  defp run_git(args, opts),
    do: System.cmd("git", args, Keyword.merge([stderr_to_stdout: true], opts))

  defp required(value, _reason) when is_binary(value) and value != "", do: :ok
  defp required(_value, reason), do: {:error, reason}
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp workspace_slug(value),
    do:
      value
      |> to_string()
      |> String.replace(~r/[^a-zA-Z0-9]+/, "-")
      |> String.trim("-")
      |> String.downcase()

  defp bounded(output), do: output |> to_string() |> String.trim() |> String.slice(0, 1_024)
end

defimpl Inspect, for: Casein.Desktop.NativeAgentLaunch do
  import Inspect.Algebra

  def inspect(plan, opts) do
    safe = %{
      runtime: plan.runtime,
      worktree: plan.worktree,
      diagnostics: plan.diagnostics,
      command: plan.command,
      workspace_id: plan.workspace_id,
      environment: "[REDACTED]"
    }

    concat(["#Casein.Desktop.NativeAgentLaunch<", to_doc(safe, opts), ">"])
  end
end
