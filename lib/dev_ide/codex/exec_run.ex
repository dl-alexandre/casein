defmodule Casein.Codex.ExecRun do
  @moduledoc """
  Observable, cancellable `codex exec --json` job.

  Arguments are always an argv list (never a shell command), the default
  sandbox is read-only, approvals are non-interactive, and Casein bearer tokens
  are removed from the child environment. JSONL records flow through the same
  canonical event hub used by hooks and App Server runtimes.
  """

  use GenServer

  alias Casein.{BoundedBuffer, Commands}
  alias Casein.Codex.{EventHub, ExecProtocol}
  alias Casein.Runs.Ledger

  @max_buffer_bytes 512 * 1024
  @max_line_bytes 10 * 1024 * 1024
  @default_timeout_ms :timer.minutes(30)
  @sensitive_env [
    {"DEV_IDE_API_TOKEN", false},
    {"DEV_IDE_ADMIN_API_TOKEN", false},
    {"DEV_IDE_WORKSPACE_API_TOKENS", false}
  ]

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :run_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    GenServer.start_link(__MODULE__, opts, name: via(run_id))
  end

  @spec start(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, pid(), String.t()} | {:error, term()}
  def start(workspace_id, root, prompt, opts \\ [])
      when is_binary(workspace_id) and is_binary(root) and is_binary(prompt) do
    run_id = Keyword.get_lazy(opts, :run_id, &Ledger.new_run_id/0)

    opts =
      Keyword.merge(opts, workspace_id: workspace_id, root: root, prompt: prompt, run_id: run_id)

    case DynamicSupervisor.start_child(Casein.Agents.Supervisor, {__MODULE__, opts}) do
      {:ok, pid} -> {:ok, pid, run_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec state(pid() | String.t()) :: map()
  def state(run_id) when is_binary(run_id), do: GenServer.call(via(run_id), :state)
  def state(pid) when is_pid(pid), do: GenServer.call(pid, :state)

  @spec subscribe(pid() | String.t(), pid()) :: {:ok, map()}
  def subscribe(server, subscriber \\ self()),
    do: GenServer.call(server_ref(server), {:subscribe, subscriber})

  @spec cancel(pid() | String.t()) :: :ok
  def cancel(server), do: GenServer.cast(server_ref(server), :cancel)

  def via(run_id), do: {:via, Registry, {Casein.Agents.Registry, {:codex_exec, run_id}}}

  @impl true
  def init(opts) do
    with {:ok, config} <- validate_options(opts),
         {:ok, ref, handle} <-
           Commands.spawn(config.root, argv(config), self(), env: @sensitive_env) do
      started_at = DateTime.utc_now()
      timer_ref = Process.send_after(self(), :hard_timeout, config.timeout_ms)

      Ledger.run_started(%{
        workspace_id: config.workspace_id,
        actor_id: config.actor_id,
        command_id: "codex.exec",
        run_id: config.run_id,
        metadata: %{
          protocol: "codex.exec.jsonl",
          source: "codex",
          transport: "exec",
          sandbox: Atom.to_string(config.sandbox)
        }
      })

      {:ok,
       %{
         workspace_id: config.workspace_id,
         actor_id: config.actor_id,
         run_id: config.run_id,
         runtime_id: "exec:#{config.run_id}",
         root: config.root,
         sandbox: config.sandbox,
         ref: ref,
         handle: handle,
         status: :running,
         started_at: started_at,
         finished_at: nil,
         exit_code: nil,
         timer_ref: timer_ref,
         timeout_ms: config.timeout_ms,
         stdout_remainder: "",
         stderr: "",
         last_message: nil,
         thread_id: nil,
         turn_id: "exec-turn:#{config.run_id}",
         protocol_errors: 0,
         subscribers: %{}
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, snapshot(state), state}

  def handle_call({:subscribe, subscriber}, _from, state) when is_pid(subscriber) do
    subscribers =
      Map.put_new_lazy(state.subscribers, subscriber, fn -> Process.monitor(subscriber) end)

    {:reply, {:ok, snapshot(state)}, %{state | subscribers: subscribers}}
  end

  @impl true
  def handle_cast(:cancel, %{status: :running} = state) do
    Commands.kill(state.handle)
    {:noreply, state}
  end

  def handle_cast(:cancel, state), do: {:noreply, state}

  @impl true
  def handle_info({:cmd_data, ref, :stdout, data}, %{ref: ref, status: :running} = state) do
    state = consume_stdout(state, IO.iodata_to_binary(data))
    {:noreply, state}
  end

  def handle_info({:cmd_data, ref, :stderr, data}, %{ref: ref} = state) do
    binary = IO.iodata_to_binary(data)

    stderr =
      BoundedBuffer.append(state.stderr, binary, @max_buffer_bytes,
        truncation_marker: "[…truncated]\n"
      )

    notify(state, {:codex_exec_data, state.run_id, :stderr, binary})
    {:noreply, %{state | stderr: stderr}}
  end

  def handle_info({:cmd_exit, ref, code}, %{ref: ref, status: :running} = state) do
    state = flush_stdout(state)
    status = if code == 0, do: :succeeded, else: :failed
    {:stop, :normal, finish(state, status, code)}
  end

  def handle_info(:hard_timeout, %{status: :running} = state) do
    Commands.kill(state.handle)
    {:stop, :normal, finish(state, :timed_out, :timeout)}
  end

  def handle_info(:hard_timeout, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    subscribers =
      case Map.get(state.subscribers, pid) do
        ^ref -> Map.delete(state.subscribers, pid)
        _other -> state.subscribers
      end

    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp validate_options(opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    root = Keyword.get(opts, :root)
    prompt = Keyword.get(opts, :prompt)
    run_id = Keyword.get(opts, :run_id)
    sandbox = Keyword.get(opts, :sandbox, :read_only)

    cond do
      not present?(workspace_id) ->
        {:error, :workspace_id_required}

      not present?(run_id) ->
        {:error, :run_id_required}

      not is_binary(root) or not File.dir?(root) ->
        {:error, :no_root}

      not present?(prompt) ->
        {:error, :prompt_required}

      byte_size(prompt) > 200_000 ->
        {:error, :prompt_too_large}

      sandbox not in [:read_only, :workspace_write] ->
        {:error, :invalid_sandbox}

      true ->
        {:ok,
         %{
           workspace_id: workspace_id,
           actor_id: Keyword.get(opts, :actor_id),
           run_id: run_id,
           root: root,
           prompt: prompt,
           sandbox: sandbox,
           executable: Keyword.get(opts, :executable, "codex"),
           timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
           extra_args: Keyword.get(opts, :extra_args, [])
         }}
    end
  end

  defp argv(config) do
    sandbox = if config.sandbox == :workspace_write, do: "workspace-write", else: "read-only"

    [
      config.executable,
      "exec",
      "--json",
      "--sandbox",
      sandbox,
      "--config",
      ~s(approval_policy="never"),
      "--cd",
      config.root
    ] ++ safe_extra_args(config.extra_args) ++ [config.prompt]
  end

  defp safe_extra_args(args) when is_list(args) do
    Enum.filter(args, fn
      value when is_binary(value) ->
        String.starts_with?(value, ["--model=", "--profile="]) or
          value in ["--ephemeral", "--skip-git-repo-check"]

      _other ->
        false
    end)
  end

  defp safe_extra_args(_args), do: []

  defp consume_stdout(state, binary) do
    combined = state.stdout_remainder <> binary
    {lines, remainder} = split_complete_lines(combined)

    state = Enum.reduce(lines, state, &consume_line(&2, &1))
    %{state | stdout_remainder: bounded_remainder(remainder)}
  end

  defp flush_stdout(%{stdout_remainder: ""} = state), do: state

  defp flush_stdout(state),
    do: consume_line(%{state | stdout_remainder: ""}, state.stdout_remainder)

  defp consume_line(state, line) do
    case Jason.decode(line) do
      {:ok, record} when is_map(record) -> publish_record(state, record)
      _error -> %{state | protocol_errors: state.protocol_errors + 1}
    end
  end

  defp publish_record(state, record) do
    thread_id = record["thread_id"] || state.thread_id
    turn_id = record["turn_id"] || state.turn_id

    context = %{
      workspace_id: state.workspace_id,
      runtime_id: state.runtime_id,
      transport: :exec,
      sequence: 1,
      occurred_at: DateTime.utc_now(),
      thread_id: thread_id,
      turn_id: turn_id
    }

    case ExecProtocol.normalize(record, context) do
      {:ok, events} ->
        Enum.each(events, fn event ->
          case EventHub.publish(event) do
            {:ok, routed} -> notify(state, {:codex_exec_event, state.run_id, routed})
            {:error, _reason} -> :ok
          end
        end)

        %{
          state
          | thread_id: thread_id,
            turn_id: turn_id,
            last_message: final_message(record) || state.last_message
        }

      :ignore ->
        %{state | thread_id: thread_id, turn_id: turn_id}

      {:error, _reason} ->
        %{
          state
          | thread_id: thread_id,
            turn_id: turn_id,
            protocol_errors: state.protocol_errors + 1
        }
    end
  end

  defp final_message(%{
         "type" => "item.completed",
         "item" => %{"type" => "agent_message"} = item
       }),
       do: item["text"]

  defp final_message(_record), do: nil

  defp finish(state, status, exit_code) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    finished_at = DateTime.utc_now()

    Ledger.run_finished(status, %{
      workspace_id: state.workspace_id,
      actor_id: state.actor_id,
      command_id: "codex.exec",
      run_id: state.run_id,
      metadata: %{
        protocol: "codex.exec.jsonl",
        source: "codex",
        transport: "exec",
        thread_id: state.thread_id,
        exit_code: exit_code,
        protocol_errors: state.protocol_errors
      }
    })

    state = %{state | status: status, exit_code: exit_code, finished_at: finished_at}
    notify(state, {:codex_exec_exit, state.run_id, exit_code, status})
    state
  end

  defp snapshot(state) do
    Map.take(state, [
      :workspace_id,
      :run_id,
      :runtime_id,
      :root,
      :sandbox,
      :status,
      :started_at,
      :finished_at,
      :exit_code,
      :stderr,
      :last_message,
      :thread_id,
      :turn_id,
      :protocol_errors
    ])
  end

  defp notify(state, message), do: Enum.each(Map.keys(state.subscribers), &send(&1, message))

  defp split_complete_lines(binary) do
    parts = String.split(binary, "\n")

    if String.ends_with?(binary, "\n") do
      {Enum.drop(parts, -1), ""}
    else
      {Enum.drop(parts, -1), List.last(parts) || ""}
    end
  end

  defp bounded_remainder(remainder) when byte_size(remainder) <= @max_line_bytes, do: remainder
  defp bounded_remainder(_remainder), do: ""
  defp server_ref(run_id) when is_binary(run_id), do: via(run_id)
  defp server_ref(pid) when is_pid(pid), do: pid
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
