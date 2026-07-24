defmodule Casein.Terminals.AgentPromptSender do
  @moduledoc """
  Sends agent prompts to a tmux pane in small, line-preserving chunks.

  This is the terminal-layer bridge between `Casein.AgentPrompt` planning and
  tmux paste-buffer transport. MCP/LiveView callers can use it to avoid one
  opaque multiline paste while keeping pane targeting and submit semantics
  explicit.
  """

  alias Casein.{AgentPrompt, Audit, Labels}
  alias Casein.Agents.Activity
  alias Casein.Export.Sanitizer
  alias Casein.Terminals.SessionTemplate

  @prompt_excerpt_bytes 512

  @type status :: :running | :done | :attention | :noop
  @type naming_status :: :set | :renamed | :kept | :skipped | :failed
  @type naming_result :: %{
          session_alias: naming_status(),
          pane_label: naming_status(),
          window: naming_status(),
          window_id: String.t() | nil,
          errors: [map()]
        }

  @type result :: %{
          session: String.t(),
          pane: String.t(),
          chunks_sent: non_neg_integer(),
          total_chunks: non_neg_integer(),
          max_lines_per_chunk: pos_integer(),
          max_bytes_per_chunk: pos_integer(),
          submit?: boolean(),
          status: status(),
          title: String.t() | nil,
          title_source: :first_prompt | :none,
          naming: naming_result()
        }

  @auto_window_names MapSet.new(["", "work", "agent", "agents", "shell", "bash", "main"])

  @doc """
  Paste a prompt into `pane` in planned chunks.

  `:submit` is sent only with the final chunk. Empty prompt text sends nothing,
  even when `submit: true`, so callers cannot accidentally press Enter with an
  empty prompt.

  If `:workspace_id` is provided, the helper emits a bounded audit event with
  the derived title, status, target session/pane, chunk counts, and a short
  normalized prompt excerpt. The event is searchable through previous-session
  search without storing the full paste blob.

  Naming options:

    * `:name_session` - `:if_blank` (default), `:always`, or `false`. Stores the
      first-prompt title as the tmux session alias.
    * `:name_window` - `:agent_role` (default), `:always`, or `false`. Renames
      the containing window only when the target pane is role-marked `agent`
      unless `:always` is supplied.
  """
  @spec send_prompt(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, result()} | {:error, map()}
  def send_prompt(session, pane, text, opts \\ [])
      when is_binary(session) and is_binary(pane) and is_binary(text) and is_list(opts) do
    tmux = Keyword.get(opts, :tmux, Casein.Terminals.tmux_adapter())
    plan = AgentPrompt.plan(text, opts)
    title = text |> AgentPrompt.title_from_first_prompt() |> redact_text()
    pane_label = maybe_set_pane_label(session, pane, title, plan, opts)

    maybe_record_running(session, pane, plan, title, pane_label, text, opts)

    case paste_chunks(tmux, session, pane, plan.chunks, plan.submit?) do
      {:ok, chunks_sent} ->
        status = if(chunks_sent == 0, do: :noop, else: :done)

        naming =
          if chunks_sent == 0 do
            skipped_naming()
          else
            apply_naming(tmux, session, pane, title, pane_label, opts)
          end

        {:ok,
         %{
           session: session,
           pane: pane,
           chunks_sent: chunks_sent,
           total_chunks: length(plan.chunks),
           max_lines_per_chunk: plan.max_lines_per_chunk,
           max_bytes_per_chunk: plan.max_bytes_per_chunk,
           submit?: plan.submit?,
           status: status,
           title: title,
           title_source: title_source(title),
           naming: naming
         }
         |> tap(&record_observability(&1, text, opts))}

      {:error, error} ->
        {:error,
         Map.merge(error, %{
           session: session,
           pane: pane,
           total_chunks: length(plan.chunks),
           max_lines_per_chunk: plan.max_lines_per_chunk,
           max_bytes_per_chunk: plan.max_bytes_per_chunk,
           submit?: plan.submit?,
           status: :attention,
           title: title,
           title_source: title_source(title),
           naming: skipped_naming(pane_label)
         })
         |> tap(&record_observability(&1, text, opts))}
    end
  end

  @doc """
  Resolve the role-marked agent pane and send a prompt to it.

  Pass `auto_apply_agent_pair: true` to apply the built-in `agent_pair`
  template once when no role-marked agent pane exists, then retry pane
  resolution. The default remains fail-closed so callers must opt into layout
  mutation explicitly.
  """
  @spec send_to_agent_pane(String.t(), String.t(), keyword()) :: {:ok, result()} | {:error, map()}
  def send_to_agent_pane(session, text, opts \\ [])
      when is_binary(session) and is_binary(text) and is_list(opts) do
    tmux = Keyword.get(opts, :tmux, Casein.Terminals.tmux_adapter())

    case Casein.Terminals.AgentPane.find(session, tmux: tmux) do
      {:ok, %{id: pane_id}} when is_binary(pane_id) ->
        send_prompt(session, pane_id, text, Keyword.put(opts, :tmux, tmux))

      {:ok, pane} ->
        {:error,
         %{
           error: :agent_pane_missing_id,
           message: "The role-marked agent pane did not include a pane id.",
           pane: Map.take(pane, [:role, :window_id, :current_command, :current_path])
         }}

      {:error, error} ->
        maybe_apply_agent_pair_and_retry(session, text, tmux, opts, error)
    end
  end

  defp maybe_apply_agent_pair_and_retry(session, text, tmux, opts, error) do
    if Keyword.get(opts, :auto_apply_agent_pair, false) == true do
      template_opts =
        opts
        |> Keyword.take([:workspace_root])
        |> Keyword.put(:tmux, tmux)

      case SessionTemplate.execute(session, "agent_pair", template_opts) do
        {:ok, _applied} ->
          opts =
            opts
            |> Keyword.put(:tmux, tmux)
            |> Keyword.put(:auto_apply_agent_pair, false)

          case send_to_agent_pane(session, text, opts) do
            {:error, %{error: :agent_pane_not_found} = retry_error} ->
              {:error,
               Map.merge(retry_error, %{
                 auto_apply_agent_pair: :applied_no_agent_pane
               })}

            other ->
              other
          end

        {:error, reason} ->
          {:error,
           Map.merge(error, %{
             auto_apply_agent_pair: :failed,
             auto_apply_reason: reason
           })}
      end
    else
      {:error, error}
    end
  end

  defp paste_chunks(_tmux, _session, _pane, [], _submit?), do: {:ok, 0}

  defp paste_chunks(tmux, session, pane, chunks, submit?) do
    total = length(chunks)

    chunks
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, 0}, fn {chunk, index}, {:ok, sent} ->
      opts = [target: pane, submit: submit? and index == total]

      case tmux.paste_text(session, chunk, opts) do
        :ok ->
          {:cont, {:ok, sent + 1}}

        {:error, reason} ->
          {:halt,
           {:error,
            %{
              reason: reason,
              chunks_sent: sent,
              failed_chunk: index
            }}}
      end
    end)
  end

  defp title_source(nil), do: :none
  defp title_source(_title), do: :first_prompt

  defp maybe_record_running(_session, _pane, %{chunks: []}, _title, _pane_label, _text, _opts),
    do: nil

  defp maybe_record_running(session, pane, plan, title, pane_label, text, opts) do
    %{
      session: session,
      pane: pane,
      chunks_sent: 0,
      total_chunks: length(plan.chunks),
      max_lines_per_chunk: plan.max_lines_per_chunk,
      max_bytes_per_chunk: plan.max_bytes_per_chunk,
      submit?: plan.submit?,
      status: :running,
      title: title,
      title_source: title_source(title),
      naming: skipped_naming(pane_label)
    }
    |> record_observability(text, opts)
  end

  defp record_observability(%{session: session, pane: pane, status: status} = result, text, opts) do
    case Keyword.get(opts, :workspace_id) do
      workspace_id when is_binary(workspace_id) and workspace_id != "" ->
        metadata =
          result
          |> audit_metadata(text)
          |> Map.merge(%{
            "session" => session,
            "pane" => pane,
            "tool" => "send_agent_prompt"
          })

        Audit.emit!(%{
          workspace_id: workspace_id,
          actor_id: audit_actor_id(opts),
          action: "terminal.agent_prompt_" <> Atom.to_string(status),
          target_type: "tmux_pane",
          target_ref: pane,
          metadata: metadata
        })

        Activity.record(%{
          workspace_id: workspace_id,
          source: :terminal_mcp,
          tool: "send_agent_prompt",
          summary: activity_summary(result),
          metadata: metadata,
          status: activity_status(status)
        })

      _ ->
        nil
    end

    result
  end

  defp activity_summary(result) do
    status = result.status |> Atom.to_string()
    title = Map.get(result, :title) || "Untitled prompt"
    session = Map.get(result, :session)
    pane = Map.get(result, :pane)
    chunks = "#{Map.get(result, :chunks_sent, 0)}/#{Map.get(result, :total_chunks, 0)}"

    "#{status}: #{title} · session=#{session} pane=#{pane} chunks=#{chunks}"
  end

  defp activity_status(:attention), do: :error
  defp activity_status(_status), do: :ok

  defp audit_actor_id(opts) do
    case Keyword.get(opts, :actor_id) do
      actor_id when is_binary(actor_id) and actor_id != "" -> actor_id
      _ -> "terminal"
    end
  end

  defp audit_metadata(result, text) do
    excerpt = prompt_excerpt(text)

    %{
      "chunks_sent" => Map.get(result, :chunks_sent),
      "failed_chunk" => Map.get(result, :failed_chunk),
      "max_lines_per_chunk" => Map.get(result, :max_lines_per_chunk),
      "max_bytes_per_chunk" => Map.get(result, :max_bytes_per_chunk),
      "naming" => audit_naming(Map.get(result, :naming)),
      "prompt_excerpt" => excerpt.text,
      "prompt_truncated" => excerpt.truncated?,
      "reason" => audit_reason(Map.get(result, :reason)),
      "status" => result.status |> Atom.to_string(),
      "submit" => Map.get(result, :submit?),
      "title" => Map.get(result, :title),
      "title_source" => result.title_source |> Atom.to_string(),
      "total_chunks" => Map.get(result, :total_chunks)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp audit_naming(%{} = naming) do
    %{
      "session_alias" => audit_atom(Map.get(naming, :session_alias)),
      "pane_label" => audit_atom(Map.get(naming, :pane_label)),
      "window" => audit_atom(Map.get(naming, :window)),
      "window_id" => Map.get(naming, :window_id),
      "errors" => Enum.map(Map.get(naming, :errors, []), &audit_error/1)
    }
  end

  defp audit_naming(_naming), do: nil

  defp audit_error(%{} = error) do
    error
    |> Enum.map(fn {key, value} -> {to_string(key), audit_reason(value)} end)
    |> Map.new()
  end

  defp audit_error(error), do: %{"reason" => audit_reason(error)}

  defp audit_reason(nil), do: nil
  defp audit_reason(value) when is_binary(value), do: redact_text(value)
  defp audit_reason(value) when is_atom(value), do: Atom.to_string(value)
  defp audit_reason(value), do: value |> inspect(limit: 20, printable_limit: 200) |> redact_text()

  defp audit_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp audit_atom(value), do: value

  defp prompt_excerpt(text) do
    normalized = text |> AgentPrompt.normalize_newlines() |> redact_text()

    if byte_size(normalized) > @prompt_excerpt_bytes do
      %{text: String.slice(normalized, 0, @prompt_excerpt_bytes), truncated?: true}
    else
      %{text: normalized, truncated?: false}
    end
  end

  defp maybe_set_pane_label(_session, _pane, _title, %{chunks: []}, _opts), do: :skipped
  defp maybe_set_pane_label(_session, _pane, nil, _plan, _opts), do: :skipped

  defp maybe_set_pane_label(session, pane, title, _plan, opts) do
    case Keyword.get(opts, :workspace_id) do
      workspace_id when is_binary(workspace_id) and workspace_id != "" ->
        case Labels.get(session, pane) do
          %{frozen?: true} ->
            :kept

          _ ->
            :ok =
              Labels.set_agent_label(workspace_id, session, pane, title,
                tool: "send_agent_prompt"
              )

            :set
        end

      _ ->
        :skipped
    end
  rescue
    _ -> :failed
  catch
    :exit, _ -> :failed
  end

  defp apply_naming(_tmux, _session, _pane, nil, pane_label, _opts),
    do: skipped_naming(pane_label)

  defp apply_naming(tmux, session, pane, title, pane_label, opts) do
    {session_alias, alias_errors} =
      maybe_set_session_alias(tmux, session, title, Keyword.get(opts, :name_session, :if_blank))

    {window, window_id, window_errors} =
      maybe_rename_window(
        tmux,
        session,
        pane,
        title,
        Keyword.get(opts, :name_window, :agent_role)
      )

    %{
      session_alias: session_alias,
      pane_label: pane_label,
      window: window,
      window_id: window_id,
      errors: alias_errors ++ window_errors
    }
  end

  defp skipped_naming(pane_label \\ :skipped) do
    %{
      session_alias: :skipped,
      pane_label: pane_label,
      window: :skipped,
      window_id: nil,
      errors: []
    }
  end

  defp maybe_set_session_alias(_tmux, _session, _title, false), do: {:skipped, []}

  defp maybe_set_session_alias(tmux, session, title, :always) do
    set_session_alias(tmux, session, title)
  end

  defp maybe_set_session_alias(tmux, session, title, :if_blank) do
    if blank?(current_session_alias(tmux, session)) do
      set_session_alias(tmux, session, title)
    else
      {:kept, []}
    end
  end

  defp maybe_set_session_alias(_tmux, _session, _title, _mode), do: {:skipped, []}

  defp set_session_alias(tmux, session, title) do
    case tmux.set_session_alias(session, title) do
      :ok -> {:set, []}
      {:error, reason} -> {:failed, [%{target: :session_alias, reason: reason}]}
    end
  end

  defp current_session_alias(tmux, session) do
    case tmux.list_sessions()
         |> Enum.find(&(map_value(&1, :session) == session)) do
      nil -> nil
      row -> map_value(row, :session_alias)
    end
  end

  defp maybe_rename_window(_tmux, _session, _pane, _title, false), do: {:skipped, nil, []}

  defp maybe_rename_window(tmux, session, pane, title, mode) do
    panes = tmux.list_session_panes(session)

    case Enum.find(panes, &(map_value(&1, :id) == pane)) do
      nil ->
        {:skipped, nil, []}

      target ->
        rename_target_window(tmux, session, target, title, mode)
    end
  end

  defp rename_target_window(tmux, session, pane, title, mode) do
    window_id = map_value(pane, :window_id)

    cond do
      blank?(window_id) ->
        {:skipped, nil, []}

      mode == :agent_role and map_value(pane, :role) != "agent" ->
        {:skipped, window_id, []}

      mode in [:agent_role, :always] ->
        if renameable_window?(tmux, session, window_id, mode) do
          rename_window(tmux, session, window_id, title)
        else
          {:kept, window_id, []}
        end

      true ->
        {:skipped, window_id, []}
    end
  end

  defp renameable_window?(_tmux, _session, _window_id, :always), do: true

  defp renameable_window?(tmux, session, window_id, :agent_role) do
    case tmux.list_session_windows(session)
         |> Enum.find(&(map_value(&1, :id) == window_id)) do
      nil -> true
      window -> auto_window_name?(map_value(window, :name))
    end
  end

  defp rename_window(tmux, session, window_id, title) do
    case tmux.rename_window(session, window_id, title) do
      :ok -> {:renamed, window_id, []}
      {:error, reason} -> {:failed, window_id, [%{target: :window, reason: reason}]}
    end
  end

  defp auto_window_name?(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> then(&MapSet.member?(@auto_window_names, &1))
  end

  defp auto_window_name?(_name), do: true

  defp map_value(nil, _key), do: nil

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false

  defp redact_text(nil), do: nil
  defp redact_text(value) when is_binary(value), do: Sanitizer.redact_text(value)
end
