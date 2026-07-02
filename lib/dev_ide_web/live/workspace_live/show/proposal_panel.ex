defmodule DevIdeWeb.WorkspaceLive.Show.ProposalPanel do
  @moduledoc false

  use DevIdeWeb, :html

  import DevIdeWeb.WorkspaceLive.Show.UI, only: [dom_fragment: 1]

  attr :proposals, :list, required: true
  attr :proposal_selected, :any, default: nil
  attr :proposal_analysis, :any, default: nil
  attr :proposal_pending_confirm, :any, default: nil
  attr :proposal_error, :any, default: nil

  def proposal_panel(assigns) do
    ~H"""
    <section class="grid h-full min-h-0 grid-cols-[minmax(0,1fr)_minmax(0,1.5fr)] gap-3 overflow-hidden p-2">
      <div class="min-h-0 overflow-auto border-r pr-2">
        <div class="mb-2 flex items-center justify-between">
          <h3 class="text-xs font-medium text-zinc-700">Proposals</h3>
          <button phx-click="proposal:refresh" class="text-[10px] text-zinc-500 hover:underline">
            refresh
          </button>
        </div>
        <%= if @proposals == [] do %>
          <p class="text-xs text-zinc-500">No proposal diffs found.</p>
        <% else %>
          <ul class="space-y-1">
            <%= for p <- @proposals do %>
              <li>
                <button
                  id={"proposal-row-#{dom_fragment(p.rel_path)}"}
                  phx-click="proposal:select"
                  phx-value-path={p.rel_path}
                  class={[
                    "w-full rounded border px-2 py-1.5 text-left text-xs transition hover:bg-zinc-50",
                    @proposal_selected && @proposal_selected.rel_path == p.rel_path &&
                      "border-zinc-900 bg-zinc-50"
                  ]}
                >
                  <div class="font-mono">{p.name}</div>
                  <div class="mt-0.5 flex gap-2 font-mono text-[10px] text-zinc-500">
                    <span>{p.size} bytes</span>
                    <span>{Atom.to_string(p.status)}</span>
                  </div>
                </button>
              </li>
            <% end %>
          </ul>
        <% end %>
      </div>

      <div class="flex min-h-0 flex-col overflow-hidden">
        <%= if @proposal_selected do %>
          <div class="mb-2 flex flex-wrap items-center gap-2">
            <span class="font-mono text-xs">{@proposal_selected.rel_path}</span>
            {risk_badge(assigns)}
          </div>
          <pre class="flex-1 overflow-auto whitespace-pre-wrap rounded bg-zinc-950 p-3 text-[11px] text-zinc-100">{@proposal_selected.diff}</pre>
          <div class="mt-2">
            {apply_action(assigns)}
          </div>
          <%= if @proposal_error do %>
            <p class="mt-1 text-xs text-red-700">{@proposal_error}</p>
          <% end %>
        <% else %>
          <p class="text-xs text-zinc-500">Select a proposal to review its diff.</p>
        <% end %>
      </div>
    </section>
    """
  end

  defp risk_badge(%{proposal_analysis: nil} = assigns), do: ~H""

  defp risk_badge(assigns) do
    ~H"""
    <span class={[
      "rounded px-1.5 py-0.5 text-[10px] font-medium",
      risk_class(@proposal_analysis.risk)
    ]}>
      {Atom.to_string(@proposal_analysis.risk)}
    </span>
    """
  end

  defp risk_class(:clean), do: "bg-green-100 text-green-800"
  defp risk_class(:overlap), do: "bg-amber-100 text-amber-800"
  defp risk_class(:conflict), do: "bg-red-100 text-red-800"
  defp risk_class(:invalid), do: "bg-red-100 text-red-800"

  defp apply_action(%{proposal_analysis: %{risk: risk}} = assigns)
       when risk in [:conflict, :invalid] do
    ~H"""
    <button disabled class="rounded border px-3 py-1 text-xs opacity-50">
      Blocked — {Atom.to_string(@proposal_analysis.risk)}
    </button>
    """
  end

  defp apply_action(
         %{proposal_pending_confirm: path, proposal_selected: %{rel_path: path}} = assigns
       )
       when not is_nil(path) do
    ~H"""
    <div class="flex items-center gap-2 rounded border border-amber-300 bg-amber-50 px-2 py-1.5 text-xs">
      <span>Overlaps in-progress changes — apply anyway?</span>
      <button
        phx-click="proposal:apply_confirm"
        phx-value-path={@proposal_selected.rel_path}
        class="rounded border border-amber-700 px-2 py-0.5 text-amber-800 hover:bg-amber-100"
      >
        Apply anyway
      </button>
      <button phx-click="proposal:apply_cancel" class="rounded border px-2 py-0.5 hover:bg-zinc-50">
        Cancel
      </button>
    </div>
    """
  end

  defp apply_action(%{proposal_analysis: %{risk: risk}} = assigns)
       when risk in [:clean, :overlap] do
    ~H"""
    <button
      phx-click="proposal:apply"
      phx-value-path={@proposal_selected.rel_path}
      class="rounded border px-3 py-1 text-xs hover:bg-zinc-50"
    >
      Apply
    </button>
    """
  end

  defp apply_action(assigns), do: ~H""
end
