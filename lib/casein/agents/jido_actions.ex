defmodule Casein.Agents.JidoActions do
  @moduledoc """
  Typed Casein action catalog for headless Jido workers (#1015).

  One validated action per capability. Identity is resolved from a trusted
  invocation context; workers call Casein services in-process. The catalog is
  behind the same `CASEIN_JIDO_HEADLESS` flag as `Casein.Agents.JidoPod`.
  OpenCode continues to use Code/Terminal MCP through
  `Casein.Agents.JidoActions.Compatibility`.
  """

  alias Casein.Agents.JidoActions.{
    CodeApplyPatch,
    CodeExec,
    CodeRead,
    CodeSearch,
    Compatibility,
    Context,
    GitDiff,
    GitPush,
    GitStatus,
    HandoffEvidence,
    ReportProgress,
    ReportResult,
    RequestClarification,
    RequestHumanInput,
    Result,
    Runner,
    TaskCancel,
    TaskWait
  }

  @type action_spec :: %{
          name: String.t(),
          module: module(),
          capability: atom(),
          idempotent: boolean(),
          mutates: boolean(),
          supported: boolean()
        }

  @catalog [
    %{
      name: "code_read",
      module: CodeRead,
      capability: :code,
      idempotent: true,
      mutates: false,
      supported: true
    },
    %{
      name: "code_search",
      module: CodeSearch,
      capability: :code,
      idempotent: true,
      mutates: false,
      supported: true
    },
    %{
      name: "code_apply_patch",
      module: CodeApplyPatch,
      capability: :code,
      idempotent: true,
      mutates: true,
      supported: true
    },
    %{
      name: "code_exec",
      module: CodeExec,
      capability: :code,
      idempotent: false,
      mutates: true,
      supported: true
    },
    %{
      name: "git_push",
      module: GitPush,
      capability: :handoff,
      idempotent: true,
      mutates: true,
      supported: true
    },
    %{
      name: "git_status",
      module: GitStatus,
      capability: :git,
      idempotent: true,
      mutates: false,
      supported: false
    },
    %{
      name: "git_diff",
      module: GitDiff,
      capability: :git,
      idempotent: true,
      mutates: false,
      supported: false
    },
    %{
      name: "task_wait",
      module: TaskWait,
      capability: :task,
      idempotent: true,
      mutates: false,
      supported: false
    },
    %{
      name: "task_cancel",
      module: TaskCancel,
      capability: :task,
      idempotent: true,
      mutates: true,
      supported: false
    },
    %{
      name: "request_clarification",
      module: RequestClarification,
      capability: :human,
      idempotent: true,
      mutates: true,
      supported: true
    },
    %{
      name: "request_human_input",
      module: RequestHumanInput,
      capability: :human,
      idempotent: true,
      mutates: true,
      supported: true
    },
    %{
      name: "report_progress",
      module: ReportProgress,
      capability: :handoff,
      idempotent: true,
      mutates: false,
      supported: true
    },
    %{
      name: "report_result",
      module: ReportResult,
      capability: :handoff,
      idempotent: true,
      mutates: true,
      supported: true
    },
    %{
      name: "handoff_evidence",
      module: HandoffEvidence,
      capability: :handoff,
      idempotent: true,
      mutates: true,
      supported: true
    }
  ]

  @by_name Map.new(@catalog, &{&1.name, &1})

  @forbidden ~w(
    terminal_send_keys
    terminal_send_command
    terminal_send_agent_keys
    terminal_send_agent_command
    terminal_paste_agent_text
    terminal_capture
    terminal_capture_agent
  )

  @doc "Discovery catalog for Jido skill/tool registration."
  @spec catalog() :: [action_spec()]
  def catalog, do: @catalog

  @spec names() :: [String.t()]
  def names, do: Enum.map(@catalog, & &1.name)

  @spec spec(String.t()) :: action_spec() | nil
  def spec(name) when is_binary(name), do: Map.get(@by_name, name)

  @spec forbidden?(String.t()) :: boolean()
  def forbidden?(name) when is_binary(name), do: name in @forbidden
  def forbidden?(_), do: false

  @doc "Invoke a typed action. Identity is taken from `context`, not args."
  @spec invoke(String.t(), map(), map()) :: {:ok, map()} | {:error, map()}
  def invoke(name, args, context \\ %{})

  def invoke(name, args, context) when is_binary(name) and is_map(args) and is_map(context) do
    cond do
      name in @forbidden ->
        Result.normalize(
          name,
          {:error,
           %{
             error: :not_allowed,
             message: "raw keystrokes and pane scrapes are not Jido actions"
           }},
          context
        )

      match?(%{module: _}, Map.get(@by_name, name)) ->
        dispatch(Map.fetch!(@by_name, name), args, context)

      true ->
        Result.normalize(
          name,
          {:error, %{error: :unknown_tool, message: "unknown Jido action #{name}"}},
          context
        )
    end
  end

  def invoke(_name, _args, context) do
    Result.normalize("unknown", {:error, :invalid}, context || %{})
  end

  defdelegate compatibility_invoke(name, args, context \\ %{}),
    to: Compatibility,
    as: :invoke

  defp dispatch(spec, args, raw_context) do
    with {:ok, ctx} <- Context.resolve(raw_context, args),
         :ok <- Context.authorize_runtime(ctx),
         :ok <- Context.ensure_fresh(ctx) do
      ctx = Map.put(ctx, :capability, spec.capability)
      result = Runner.invoke_action(spec.module, args, ctx)
      Result.normalize(spec.name, result, ctx)
    else
      {:error, reason} -> Result.normalize(spec.name, {:error, reason}, raw_context)
    end
  end
end
