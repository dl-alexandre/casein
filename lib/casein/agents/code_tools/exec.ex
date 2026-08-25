defmodule Casein.Agents.CodeTools.Exec do
  @moduledoc """
  code_exec: server-owned allowlisted command execution in the assigned worktree.

  Workers pass a command id, never a shell string. Argv comes from
  `Casein.Commands`; extra args are path-validated. Timeouts, output caps,
  and truncation are explicit in the result.
  """

  use Jido.Action,
    name: "code_exec",
    description:
      "Run a server-owned verifier command (compile/test/format/precommit/assets.build) in the assigned worktree.",
    category: "code",
    tags: ["code", "exec"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      worktree_path: [type: :string, required: true],
      command_id: [type: :string, required: true],
      extra_args: [type: {:list, :string}],
      cwd: [type: :string],
      timeout_ms: [type: :integer],
      max_output_bytes: [type: :integer],
      task_id: [type: :string],
      attempt_id: [type: :string]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.CodeTools.Helpers
  alias Casein.{Commands, Policy}
  alias McpCtl.Tool

  @verifier_ids ~w(compile test format precommit assets.build)

  @impl Casein.Agents.ToolAction
  def parameters do
    Tool.object(
      Map.merge(
        %{
          workspace_id: Helpers.workspace_id_param(),
          worktree_path: Helpers.worktree_path_param(),
          command_id: %{
            type: "string",
            enum: @verifier_ids,
            description: "Server-owned verifier id. Not a shell string."
          },
          extra_args: %{
            type: "array",
            items: %{type: "string"},
            description:
              "Optional extra argv tokens. Each must be a repository-relative path; no shell metacharacters."
          },
          cwd: %{
            type: "string",
            description: "Optional repository-relative working directory inside the worktree."
          },
          timeout_ms: %{
            type: "integer",
            minimum: 1,
            description: "Command timeout in milliseconds (capped)."
          },
          max_output_bytes: %{
            type: "integer",
            minimum: 1,
            description: "Maximum combined stdout/stderr bytes to return (capped)."
          }
        },
        Helpers.identity_params()
      ),
      [:workspace_id, :worktree_path, :command_id]
    )
  end

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Map.put(Helpers.metadata(:high, true), :timeout_ms, 125_000)

  @impl Jido.Action
  def run(params, context) do
    with {:ok, assignment} <- Helpers.resolve_assignment(params, context),
         :ok <- validate_command_id(params.command_id),
         :ok <-
           Helpers.authorize(
             &Policy.can_run_command?(Map.put(&1, :command_id, params.command_id)),
             assignment
           ),
         {:ok, argv} <- Commands.argv_for(params.command_id) |> map_argv(params.command_id),
         {:ok, extra} <-
           validate_extra_args(assignment.worktree_path, Map.get(params, :extra_args)),
         {:ok, cwd} <- resolve_cwd(assignment.worktree_path, Map.get(params, :cwd)) do
      timeout_ms = Helpers.clamp_timeout_ms(Map.get(params, :timeout_ms))
      max_bytes = Helpers.clamp_output_bytes(Map.get(params, :max_output_bytes))
      full_argv = argv ++ extra
      result = run_command(cwd, full_argv, timeout_ms, max_bytes)

      {:ok,
       assignment
       |> Helpers.identity_fields()
       |> Map.merge(%{
         command_id: params.command_id,
         argv: full_argv,
         cwd: cwd,
         timeout_ms: timeout_ms,
         max_output_bytes: max_bytes
       })
       |> Map.merge(result)}
    end
  end

  defp validate_command_id(id) when id in @verifier_ids, do: :ok

  defp validate_command_id(id) do
    {:error,
     %{
       error: :not_allowed,
       command_id: id,
       message: "command_id must be one of #{Enum.join(@verifier_ids, ", ")}"
     }}
  end

  defp map_argv({:ok, argv}, _id), do: {:ok, argv}

  defp map_argv(:error, id) do
    {:error, %{error: :not_allowed, command_id: id, message: "Unknown command id"}}
  end

  defp validate_extra_args(_worktree, nil), do: {:ok, []}
  defp validate_extra_args(_worktree, []), do: {:ok, []}

  defp validate_extra_args(worktree, args) when is_list(args) do
    Enum.reduce_while(args, {:ok, []}, fn arg, {:ok, acc} ->
      case validate_extra_arg(worktree, arg) do
        {:ok, token} -> {:cont, {:ok, acc ++ [token]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_extra_args(_worktree, _args),
    do: {:error, %{error: :invalid_argument, message: "extra_args must be a list of strings"}}

  defp validate_extra_arg(_worktree, arg) when not is_binary(arg) do
    {:error, %{error: :invalid_argument, message: "extra_args entries must be strings"}}
  end

  defp validate_extra_arg(worktree, arg) do
    cond do
      String.contains?(arg, <<0>>) ->
        {:error, %{error: :invalid_argument, message: "extra_args may not contain NUL"}}

      String.match?(arg, ~r/[;|&`$()<>\\]/) ->
        {:error,
         %{error: :invalid_argument, message: "extra_args may not contain shell metacharacters"}}

      String.starts_with?(arg, "-") ->
        {:error, %{error: :invalid_argument, message: "extra_args may not introduce flags"}}

      true ->
        with {:ok, rel, _abs} <- Helpers.resolve_rel_path(worktree, arg) do
          {:ok, rel}
        end
    end
  end

  defp resolve_cwd(worktree, nil), do: {:ok, worktree}
  defp resolve_cwd(worktree, ""), do: {:ok, worktree}

  defp resolve_cwd(worktree, cwd) do
    with {:ok, _rel, abs} <- Helpers.resolve_rel_path(worktree, cwd) do
      if File.dir?(abs),
        do: {:ok, abs},
        else: {:error, %{error: :not_a_directory, path: cwd}}
    end
  end

  defp run_command(cwd, [bin | args] = argv, timeout_ms, max_bytes) do
    parent = self()

    collector =
      spawn_link(fn ->
        collect_output(parent, max_bytes)
      end)

    case Commands.spawn(cwd, argv, collector) do
      {:ok, ref, handle} ->
        send(collector, {:expect, ref})
        await_command(collector, ref, handle, timeout_ms, argv)

      {:error, reason} ->
        Process.exit(collector, :kill)

        %{
          status: "error",
          exit_code: nil,
          output: "",
          output_truncated: false,
          timed_out: false,
          cancelled: false,
          argv: argv,
          message: inspect(reason)
        }
    end
  rescue
    error ->
      %{
        status: "error",
        exit_code: nil,
        output: "",
        output_truncated: false,
        timed_out: false,
        cancelled: false,
        argv: [bin | args],
        message: Exception.message(error)
      }
  end

  defp await_command(collector, ref, handle, timeout_ms, argv) do
    receive do
      {:cmd_done, ^ref, result} ->
        Map.merge(
          %{
            status: status_for(result),
            timed_out: false,
            cancelled: false,
            argv: argv
          },
          result
        )
    after
      timeout_ms ->
        Commands.kill(handle)

        receive do
          {:cmd_done, ^ref, result} ->
            Map.merge(
              %{
                status: "timeout",
                timed_out: true,
                cancelled: true,
                argv: argv
              },
              result
            )
        after
          200 ->
            Process.exit(collector, :kill)

            %{
              status: "timeout",
              exit_code: nil,
              output: "",
              output_truncated: false,
              timed_out: true,
              cancelled: true,
              argv: argv
            }
        end
    end
  end

  defp collect_output(parent, max_bytes) do
    receive do
      {:expect, ref} -> collect_output(parent, ref, "", false, max_bytes)
    after
      5_000 -> :ok
    end
  end

  defp collect_output(parent, ref, acc, truncated?, max_bytes) do
    receive do
      {:cmd_data, ^ref, _stream, data} when is_binary(data) ->
        {acc, truncated?} = append_capped(acc, data, truncated?, max_bytes)
        collect_output(parent, ref, acc, truncated?, max_bytes)

      {:cmd_exit, ^ref, code} ->
        send(
          parent,
          {:cmd_done, ref, %{exit_code: code, output: acc, output_truncated: truncated?}}
        )
    after
      130_000 ->
        send(
          parent,
          {:cmd_done, ref, %{exit_code: nil, output: acc, output_truncated: truncated?}}
        )
    end
  end

  defp append_capped(acc, _data, true, _max), do: {acc, true}

  defp append_capped(acc, data, false, max_bytes) do
    combined = acc <> data

    if byte_size(combined) <= max_bytes do
      {combined, false}
    else
      {binary_part(combined, 0, max_bytes), true}
    end
  end

  defp status_for(%{exit_code: 0}), do: "completed"
  defp status_for(%{exit_code: code}) when is_integer(code), do: "failed"
  defp status_for(_), do: "error"
end
