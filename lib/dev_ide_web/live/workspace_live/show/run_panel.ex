defmodule DevIdeWeb.WorkspaceLive.Show.RunPanel do
  @moduledoc false

  use DevIdeWeb, :html

  import DevIdeWeb.WorkspaceLive.Show.UI, only: [dom_fragment: 1]

  alias DevIDE.Commands.Allowlist
  alias DevIDE.Runs.Status

  attr :host_loc, :any, required: true
  attr :active_run, :any, default: nil
  attr :review_commands, :list, default: []
  attr :agent_write_unlock, :any, default: %{status: :inactive, until: nil, by: nil}
  attr :run_ledger, :list, required: true
  attr :selected_run_id, :any, default: nil
  attr :selected_run_timeline, :list, required: true
  attr :selected_run_summary, :any, default: nil
  attr :selected_run_failure_reason, :any, default: nil
  attr :selected_run_can_retry, :boolean, default: false
  attr :selected_run_artifacts, :list, required: true

  def run_panel(assigns) do
    ~H"""
    <section class="flex h-full min-h-0 flex-col gap-2 overflow-auto pr-1">
      <%= case @host_loc do %>
        <% {:ok, _} -> %>
          <div class="flex gap-2 items-center text-sm">
            <%= for {id, argv} <- Enum.sort(Allowlist.all()) do %>
              <button
                phx-click="run:start"
                phx-value-id={id}
                disabled={@active_run && @active_run.status == :running}
                class="rounded border px-3 py-1 disabled:opacity-50"
              >
                {run_button_label(id, argv)}
              </button>
            <% end %>
            <%= if @active_run && @active_run.status == :running do %>
              <button phx-click="run:cancel" class="ml-2 rounded border px-3 py-1 text-red-700">
                cancel
              </button>
            <% end %>
          </div>
          <%= if @active_run do %>
            <div class="text-xs text-zinc-500 font-mono flex gap-3">
              <span>{Enum.join(@active_run.argv, " ")}</span>
              <span class={run_status_class(@active_run.status)}>{@active_run.status}</span>
              <%= if @active_run.exit_code != nil do %>
                <span>exit={inspect(@active_run.exit_code)}</span>
              <% end %>
              <%= if @active_run.started_at do %>
                <span>started {DateTime.to_string(@active_run.started_at)}</span>
              <% end %>
              <%= if @active_run.finished_at do %>
                <span>finished {DateTime.to_string(@active_run.finished_at)}</span>
              <% end %>
            </div>
            <pre class="bg-zinc-950 text-zinc-100 text-xs p-3 rounded overflow-auto whitespace-pre-wrap h-[40dvh] min-h-[12rem]">{@active_run.buffer}</pre>
          <% else %>
            <p class="text-xs text-zinc-500">No runs yet.</p>
          <% end %>

          <%= if @review_commands != [] do %>
            <div id="review-runs" class="border-t pt-3 mt-3">
              <h3 class="mb-2 text-xs font-medium text-zinc-700">Review runs</h3>
              <div class="flex flex-wrap gap-2">
                <%= for {cmd, available?} <- @review_commands do %>
                  <button
                    id={"review-run-#{dom_fragment(cmd.id)}"}
                    phx-click="agent:start_review_run"
                    phx-value-id={cmd.id}
                    disabled={not available?}
                    title={cmd.description}
                    class="rounded border px-3 py-1 text-xs disabled:opacity-50"
                  >
                    {cmd.id}
                  </button>
                <% end %>
              </div>
            </div>
          <% end %>

          <div id="agent-write-unlock" class="border-t pt-3 mt-3">
            <h3 class="mb-2 text-xs font-medium text-zinc-700">Agent write unlock</h3>
            <%= if @agent_write_unlock.status == :active do %>
              <div class="flex flex-wrap items-center gap-2 rounded border border-amber-300 bg-amber-50 px-2 py-1.5 text-xs">
                <span>
                  Unlocked until {Calendar.strftime(@agent_write_unlock.until, "%H:%M")} by {@agent_write_unlock.by}
                </span>
                <button
                  id="agent-write-unlock-revoke"
                  phx-click="workspace:revoke_agent_write_unlock"
                  class="ml-auto rounded border border-red-700 px-2 py-0.5 text-red-700 hover:bg-red-50"
                >
                  Revoke now
                </button>
              </div>
            <% else %>
              <form
                phx-submit="workspace:grant_agent_write_unlock"
                class="flex items-center gap-2 text-xs"
              >
                <label for="agent-write-unlock-minutes">Unlock for</label>
                <select
                  id="agent-write-unlock-minutes"
                  name="minutes"
                  class="rounded border px-1 py-0.5"
                >
                  <option value="15">15 min</option>
                  <option value="30" selected>30 min</option>
                  <option value="60">60 min</option>
                  <option value="120">120 min</option>
                </select>
                <button type="submit" class="rounded border px-3 py-1 hover:bg-zinc-50">
                  Unlock agent write
                </button>
              </form>
            <% end %>
          </div>

          <div
            id="run-ledger"
            class="border-t pt-3 mt-3 grid gap-3 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)]"
          >
            <section>
              <div class="flex items-center justify-between mb-2">
                <h3 class="text-xs font-medium text-zinc-700">Run ledger</h3>
                <span class="text-[10px] font-mono text-zinc-400">
                  {length(@run_ledger)} runs
                </span>
              </div>
              <%= if @run_ledger == [] do %>
                <p id="run-ledger-empty" class="text-xs text-zinc-500">
                  No runs recorded.
                </p>
              <% else %>
                <ol class="space-y-1">
                  <%= for r <- @run_ledger do %>
                    <li>
                      <button
                        id={"run-ledger-run-#{dom_fragment(r.id)}"}
                        phx-click="run_ledger:select"
                        phx-value-id={r.id}
                        data-ctx-menu="run_entry"
                        data-ctx-run-id={r.id}
                        data-ctx-command-id={Map.get(r, :command_id) || Map.get(r, :safe_action_id)}
                        class={[
                          "w-full rounded border px-2 py-1.5 text-left text-xs transition hover:bg-zinc-50",
                          @selected_run_id == r.id && "border-zinc-900 bg-zinc-50"
                        ]}
                      >
                        <div class="flex items-center gap-2">
                          <span class="font-mono">
                            {Map.get(r, :command_id) || Map.get(r, :safe_action_id) || r.id}
                          </span>
                          <span class={run_status_class(Status.status_class(Map.get(r, :status)))}>
                            {Map.get(r, :status, "unknown")}
                          </span>
                        </div>
                        <div class="mt-1 flex flex-wrap gap-2 font-mono text-[10px] text-zinc-500">
                          <span>{Map.get(r, :protocol, "ledger")}</span>
                          <%= if Map.get(r, :assignment_id) do %>
                            <span>assignment={Map.get(r, :assignment_id)}</span>
                          <% end %>
                          <%= if Map.get(r, :finished_at) do %>
                            <span>{Map.get(r, :finished_at)}</span>
                          <% end %>
                        </div>
                      </button>
                    </li>
                  <% end %>
                </ol>
              <% end %>
            </section>

            <section>
              <div class="flex items-center justify-between mb-2">
                <h3 class="text-xs font-medium text-zinc-700">Timeline</h3>
                <%= if @selected_run_id do %>
                  <span class="text-[10px] font-mono text-zinc-400">
                    {@selected_run_id}
                  </span>
                <% end %>
              </div>
              <%= if @selected_run_timeline == [] do %>
                <p id="run-ledger-timeline-empty" class="text-xs text-zinc-500">
                  Select a run to inspect its canonical events.
                </p>
              <% else %>
                <%= if @selected_run_summary do %>
                  <dl
                    id="run-ledger-summary"
                    class="mb-2 grid grid-cols-[auto_1fr] gap-x-2 gap-y-0.5 rounded border bg-zinc-50 px-2 py-1.5 text-[10px]"
                  >
                    <dt class="text-zinc-500">status</dt>
                    <dd class="font-mono">{Map.get(@selected_run_summary, :status, "unknown")}</dd>
                    <dt class="text-zinc-500">command</dt>
                    <dd class="font-mono">
                      {Map.get(@selected_run_summary, :command_id) ||
                        Map.get(@selected_run_summary, :safe_action_id) || "unknown"}
                    </dd>
                    <%= if Map.get(@selected_run_summary, :assignment_id) do %>
                      <dt class="text-zinc-500">assignment</dt>
                      <dd class="font-mono">{Map.get(@selected_run_summary, :assignment_id)}</dd>
                    <% end %>
                  </dl>
                  <%= if Status.failed?(@selected_run_summary.status) do %>
                    <div
                      id="run-failure-surface"
                      class="rounded border bg-red-50 px-2 py-1.5 text-xs space-y-1 mb-2"
                    >
                      <div class="flex items-center gap-2">
                        <span class="text-red-700 font-medium">Failed</span>
                        <%= if @selected_run_failure_reason do %>
                          <span class="font-mono text-zinc-600">{@selected_run_failure_reason}</span>
                        <% end %>
                      </div>
                      <%= if @selected_run_can_retry do %>
                        <button
                          id="run-retry-btn"
                          phx-click="run:start"
                          phx-value-id={@selected_run_summary.command_id}
                          class="rounded border px-2 py-0.5 bg-white hover:bg-zinc-50"
                        >
                          Retry
                        </button>
                      <% end %>
                    </div>
                  <% end %>
                <% end %>
                <ol id="run-ledger-timeline" class="space-y-1.5">
                  <%= for e <- @selected_run_timeline do %>
                    <li
                      id={"run-ledger-event-#{dom_fragment(e.id)}"}
                      class="rounded border px-2 py-1.5 text-xs"
                    >
                      <div class="flex flex-wrap items-baseline gap-2">
                        <span class={"inline-block w-1.5 h-1.5 rounded-full " <> audit_dot_class(e)}></span>
                        <span class="font-mono text-zinc-400">
                          {Calendar.strftime(e.inserted_at, "%H:%M:%S")}
                        </span>
                        <span class={"font-medium " <> audit_verb_class(e)}>
                          {e.action}
                        </span>
                        <span class="font-mono text-[10px] text-zinc-500">
                          {ledger_event_noun(e)}
                        </span>
                      </div>
                      <p class="mt-1 font-mono text-[10px] text-zinc-600 break-all">
                        {audit_detail(e)}
                      </p>
                    </li>
                  <% end %>
                </ol>
                <div id="run-ledger-artifacts" class="mt-3 space-y-2">
                  <h3 class="text-xs font-medium text-zinc-700">Artifacts</h3>
                  <%= if @selected_run_artifacts == [] do %>
                    <p class="text-xs text-zinc-500">No artifacts recorded for this run.</p>
                  <% else %>
                    <%= for artifact <- @selected_run_artifacts do %>
                      <.run_artifact artifact={artifact} />
                    <% end %>
                  <% end %>
                </div>
              <% end %>
            </section>
          </div>
        <% _ -> %>
          <p class="text-sm text-red-700">Cannot run commands: workspace path unavailable.</p>
      <% end %>
    </section>
    """
  end

  attr :artifact, :map, required: true

  def run_artifact(assigns) do
    ~H"""
    <%= case Map.get(@artifact, :type) do %>
      <% "command_output" -> %>
        <section id="run-artifact-command-output" class="rounded border text-xs">
          <header class="flex flex-wrap items-center gap-2 border-b px-2 py-1 font-mono text-[10px] text-zinc-500">
            <span>command output</span>
            <span>{Map.get(@artifact, :command_id)}</span>
            <span>{Map.get(@artifact, :status)}</span>
            <%= if Map.get(@artifact, :exit_code) do %>
              <span>exit={Map.get(@artifact, :exit_code)}</span>
            <% end %>
            <%= if Map.get(@artifact, :output_truncated) do %>
              <span class="text-amber-700">truncated</span>
            <% end %>
          </header>
          <pre class="max-h-72 overflow-auto whitespace-pre-wrap bg-zinc-950 p-2 text-[11px] text-zinc-100">{Map.get(@artifact, :output, "")}</pre>
        </section>
      <% _ -> %>
        <section class="rounded border px-2 py-1.5 text-xs text-zinc-500">
          Unknown artifact.
        </section>
    <% end %>
    """
  end

  defp run_status_class(status) do
    case Status.status_class(status) do
      :running -> "text-amber-700"
      :succeeded -> "text-green-700"
      :failed -> "text-red-700"
      :timed_out -> "text-purple-700"
      _ -> "text-zinc-500"
    end
  end

  defp run_button_label(id, ["mix" | _]), do: "mix " <> id
  defp run_button_label(id, _argv), do: id

  defp ledger_event_noun(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "noun") || "event"
  end

  defp ledger_event_noun(_), do: "event"

  defp audit_dot_class(%{decision: :deny}), do: "bg-red-600"
  defp audit_dot_class(%{decision: :allow}), do: "bg-green-600"
  defp audit_dot_class(%{action: "workspace.mode_set"}), do: "bg-amber-500"
  defp audit_dot_class(_), do: "bg-zinc-400"

  defp audit_verb_class(%{decision: :deny}), do: "text-red-700"
  defp audit_verb_class(%{decision: :allow}), do: "text-green-700"
  defp audit_verb_class(%{action: "workspace.mode_set"}), do: "text-amber-700"
  defp audit_verb_class(_), do: "text-zinc-600"

  defp audit_detail(%{action: action, target_ref: ref, reason: reason}) do
    base = action

    base =
      cond do
        ref && ref != "" -> "#{base} · #{ref}"
        true -> base
      end

    cond do
      reason -> "#{base} · #{Atom.to_string(reason)}"
      true -> base
    end
  end
end
