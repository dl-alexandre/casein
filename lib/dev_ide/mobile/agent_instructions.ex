defmodule DevIDE.Mobile.AgentInstructions do
  @moduledoc """
  Sends a free-text instruction from a paired phone into a workspace's agent
  pane.

  The cockpit has been able to do this for a while (`terminal:send_agent_text`
  → `DevIDE.Terminals.send_agent_prompt_to_agent_pane/3`). This module is the
  mobile-facing equivalent: it resolves *which* tmux session and pane the
  instruction belongs in — the phone has no view of tmux topology and must not
  be trusted to name a pane — validates the text, and delegates the paste.

  Trust boundary, in order:

    1. **Authorization is the caller's job.** `DevIdeWeb.MobileUserChannel`
       runs the same `authorize_workspace/3` gate it uses for `watch_workspace`
       and `card_action` before calling in here.
    2. **Targets are server-resolved.** A client may pass a `tmux_session`
       hint, but it is only honored when that session is one of the workspace's
       own tabs (`DevIDE.Terminals.SessionDirectory`). Anything else falls back
       to the first tab with a role-marked agent pane.
    3. **The paste is bounded.** Empty text is rejected, text over
       `max_bytes/0` is rejected, and the existing chunked paste path applies
       the rest of the transport rules.
    4. **Every send is audited.** `AgentPromptSender` emits a `terminal.agent_prompt_*`
       audit event and an agent-activity entry; this module stamps mobile
       provenance (`origin: "mobile"`, device link, platform) into that
       metadata so a phone-originated prompt is distinguishable in the ledger.
    5. **Retries are idempotent.** A `request_id` (the phone's outbox key)
       records a `DevIDE.Mobile.ActionOutcome`, so an instruction retried after
       an ambiguous failure replays the recorded outcome instead of pasting the
       same prompt into the agent pane twice.

  No approval gate: a paired phone that may already approve or deny a run is
  trusted to type into that workspace's agent pane, exactly as the cockpit is.
  """

  import Ecto.Query, only: [from: 2]

  alias DevIDE.Mobile.ActionOutcome
  alias DevIDE.Terminals
  alias DevIDE.Terminals.SessionDirectory
  alias DevIDE.Workspaces
  alias DevIde.Repo

  @max_bytes 4_000

  @type context :: %{
          required(:user_id) => String.t(),
          optional(:device_link_id) => String.t() | nil,
          optional(:platform) => String.t() | nil
        }

  @type target :: %{
          tmux_session: String.t(),
          pane_id: String.t(),
          label: String.t() | nil,
          match: String.t() | nil
        }

  @type summary :: %{
          status: String.t(),
          tmux_session: String.t(),
          pane_id: String.t(),
          chunks_sent: non_neg_integer(),
          submitted: boolean(),
          title: String.t() | nil
        }

  @doc "Maximum instruction size, in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  The agent panes a phone may address in this workspace.

  Returns at most one entry per tmux session — the role-marked agent pane —
  so the client can offer a target picker when a workspace runs more than one
  agent session.
  """
  @spec targets(String.t(), keyword()) :: [target()]
  def targets(workspace_id, opts \\ []) when is_binary(workspace_id) do
    workspace_id
    |> tmux_sessions(opts)
    |> Enum.flat_map(fn session ->
      case find_agent_pane(session, opts) do
        {:ok, %{id: pane_id} = pane} when is_binary(pane_id) ->
          [
            %{
              tmux_session: session,
              pane_id: pane_id,
              label: pane_label(pane),
              match: pane[:agent_match] || pane["agent_match"]
            }
          ]

        _ ->
          []
      end
    end)
  end

  @doc """
  Sends `text` to the workspace's agent pane.

  Params:

    * `"workspace_id"` — required, already authorized by the caller.
    * `"text"` — required, 1..#{@max_bytes} bytes after trimming.
    * `"submit"` — optional (default `true`). `false` pastes without pressing
      Enter, which is how the cockpit's "send selection" behaves.
    * `"tmux_session"` — optional target hint, honored only if it is one of the
      workspace's own sessions.
    * `"request_id"` — optional idempotency key. Supplying one makes a retry
      safe; omitting it means every call sends.
  """
  @spec send(context(), map(), keyword()) :: {:ok, summary()} | {:error, atom()}
  def send(context, params, opts \\ [])

  def send(context, %{"workspace_id" => workspace_id, "text" => text} = params, opts)
      when is_binary(workspace_id) and is_binary(text) do
    do_send(context, workspace_id, text, params, opts)
  end

  def send(_context, _params, _opts), do: {:error, :invalid_payload}

  defp do_send(context, workspace_id, text, params, opts) do
    case replayable_outcome(context, params) do
      %ActionOutcome{result: result} -> {:ok, replayed_summary(result)}
      nil -> do_send_new(context, workspace_id, text, params, opts)
    end
  end

  defp do_send_new(context, workspace_id, text, params, opts) do
    with {:ok, trimmed} <- validate_text(text),
         {:ok, target} <- resolve_target(workspace_id, params, opts) do
      submit? = submit?(params)

      send_opts =
        opts
        |> Keyword.take([:tmux])
        |> Keyword.merge(
          submit: submit?,
          workspace_id: workspace_id,
          actor_id: context.user_id,
          metadata: audit_metadata(context)
        )

      case Terminals.send_agent_prompt(
             target.tmux_session,
             target.pane_id,
             trimmed,
             send_opts
           ) do
        {:ok, result} ->
          summary = %{
            status: to_string(result.status),
            tmux_session: target.tmux_session,
            pane_id: target.pane_id,
            chunks_sent: result.chunks_sent,
            submitted: submit? and result.chunks_sent > 0,
            title: result.title,
            replayed: false
          }

          record_outcome(context, workspace_id, params, summary)
          {:ok, summary}

        {:error, _error} ->
          {:error, :send_failed}
      end
    end
  end

  # Idempotency, only when the client opted in with a request_id. The outcome
  # row is the same one card actions use, so a phone's outbox retry and a
  # double-tapped card action are deduped by the same index.
  defp replayable_outcome(context, params) do
    with request_id when is_binary(request_id) <- request_id(params),
         user_id when is_binary(user_id) <- Map.get(context, :user_id) do
      Repo.one(
        from(o in ActionOutcome,
          where:
            o.user_id == ^user_id and o.request_id == ^request_id and o.status == "instructed"
        )
      )
    else
      _ -> nil
    end
  end

  defp record_outcome(context, workspace_id, params, summary) do
    case request_id(params) do
      nil ->
        :ok

      request_id ->
        %ActionOutcome{}
        |> ActionOutcome.changeset(%{
          request_id: request_id,
          user_id: context.user_id,
          card_id: "agent_instruction:" <> workspace_id,
          action_id: "agent_instruction",
          resource_type: "workspace",
          resource_id: workspace_id,
          device_link_id: Map.get(context, :device_link_id),
          platform: Map.get(context, :platform),
          status: "instructed",
          result: %{
            "tmux_session" => summary.tmux_session,
            "pane_id" => summary.pane_id,
            "chunks_sent" => summary.chunks_sent,
            "submitted" => summary.submitted
          }
        })
        |> Repo.insert()

        :ok
    end
  end

  defp replayed_summary(result) when is_map(result) do
    %{
      status: "done",
      tmux_session: Map.get(result, "tmux_session"),
      pane_id: Map.get(result, "pane_id"),
      chunks_sent: Map.get(result, "chunks_sent", 0),
      submitted: Map.get(result, "submitted", false),
      title: nil,
      replayed: true
    }
  end

  defp request_id(params) do
    case Map.get(params, "request_id", Map.get(params, :request_id)) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp validate_text(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" -> {:error, :empty_instruction}
      byte_size(trimmed) > @max_bytes -> {:error, :instruction_too_long}
      true -> {:ok, trimmed}
    end
  end

  # A client-supplied session is a *hint*: it only wins if it is one of this
  # workspace's own tabs. Otherwise a phone could address any tmux session on
  # the host by guessing its name.
  defp resolve_target(workspace_id, params, opts) do
    hint = params["tmux_session"] || params[:tmux_session]
    available = targets(workspace_id, opts)

    cond do
      available == [] ->
        {:error, :agent_pane_not_found}

      is_binary(hint) ->
        case Enum.find(available, &(&1.tmux_session == hint)) do
          nil -> {:error, :unknown_target}
          target -> {:ok, target}
        end

      true ->
        {:ok, hd(available)}
    end
  end

  # `Map.get` twice rather than `||`: the interesting value here is `false`,
  # which `||` would fall through.
  defp submit?(params) do
    case Map.get(params, "submit", Map.get(params, :submit)) do
      false -> false
      "false" -> false
      _ -> true
    end
  end

  defp audit_metadata(context) do
    %{
      "origin" => "mobile",
      "device_link_id" => Map.get(context, :device_link_id),
      "platform" => Map.get(context, :platform)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # `read/2` rather than the cached `tabs/2`: an instruction is a rare,
  # human-driven action where a stale target would paste into the wrong pane,
  # and the direct read runs in this process instead of queueing behind the
  # workspace's directory GenServer.
  defp tmux_sessions(workspace_id, opts) do
    directory_opts =
      opts
      |> Keyword.take([:workspace_name, :workspace_names, :tmux_sessions])
      |> Keyword.put_new_lazy(:workspace_name, fn -> workspace_name(workspace_id) end)

    workspace_id
    |> SessionDirectory.read(directory_opts)
    |> Enum.map(& &1.tmux_session)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  # tmux sessions are named after the workspace *name* (`devide_<name>_<sid>`),
  # so the id alone would only match workspaces that never got one.
  defp workspace_name(workspace_id) do
    case Workspaces.get(workspace_id) do
      {:ok, %{name: name}} when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp find_agent_pane(session, opts) do
    Terminals.find_agent_pane(session, Keyword.take(opts, [:tmux]))
  end

  defp pane_label(pane) do
    pane[:label] || pane["label"] || pane[:current_command] || pane["current_command"]
  end
end
