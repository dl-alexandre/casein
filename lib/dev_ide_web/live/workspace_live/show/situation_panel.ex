defmodule DevIdeWeb.WorkspaceLive.Show.SituationPanel do
  @moduledoc """
  Minimal operator situation surface: a floating risk badge (active-risk
  count, colored by max severity) that opens a drawer listing the active
  risks from `DevIDE.Operator.SituationServer`.

  Both components render nothing unless `enabled` — the Show LiveView sets
  it only when the `:situation_server` flag is on AND a live server has been
  seen for the workspace (`DevIdeWeb.WorkspaceLive.Show.SituationEvents`),
  so with the flag off this surface adds zero DOM.
  """

  use DevIdeWeb, :html

  attr :enabled, :boolean, required: true
  attr :risks, :list, required: true

  def situation_badge(assigns) do
    ~H"""
    <button
      :if={@enabled}
      id="situation-badge"
      phx-click="situation_drawer:toggle"
      class={"fixed bottom-3 right-3 z-30 flex items-center gap-1.5 rounded-full border px-2.5 py-1 font-mono text-[11px] shadow-sm " <>
        badge_class(@risks)}
      title="operator situation risks"
    >
      <span class={"inline-block w-1.5 h-1.5 rounded-full " <> severity_dot_class(max_severity(@risks))}></span>
      {length(@risks)} risk{if length(@risks) == 1, do: "", else: "s"}
    </button>
    """
  end

  attr :enabled, :boolean, required: true
  attr :open, :boolean, required: true
  attr :risks, :list, required: true
  attr :workspace, :map, required: true

  def situation_drawer(assigns) do
    ~H"""
    <div
      :if={@enabled and @open}
      class="fixed inset-0 z-40 pointer-events-none"
      aria-hidden="false"
    >
      <div
        class="absolute inset-0 bg-black/20 pointer-events-auto"
        phx-click="situation_drawer:close"
      >
      </div>
      <aside
        class="absolute right-0 top-0 bottom-0 w-[380px] bg-white border-l shadow-xl pointer-events-auto flex flex-col"
        role="complementary"
        aria-label="Situation risks drawer"
      >
        <header class="flex items-center justify-between px-4 py-3 border-b">
          <div>
            <h2 class="text-sm font-semibold tracking-tight">Situation risks</h2>
            <p class="text-[11px] text-zinc-500 font-mono">
              {length(@risks)} active · workspace {@workspace.name}
            </p>
          </div>
          <button
            phx-click="situation_drawer:close"
            class="text-[11px] border rounded px-2 py-0.5 hover:bg-zinc-50"
            title="close"
          >
            ×
          </button>
        </header>
        <div class="flex-1 overflow-auto px-3 py-2 text-[11px] leading-relaxed">
          <p :if={@risks == []} class="text-zinc-400 italic font-mono">no active risks</p>
          <ol class="space-y-2">
            <li :for={risk <- sort_risks(@risks)} class="rounded border px-2 py-1.5">
              <div class="flex items-baseline gap-2 font-mono">
                <span class={"inline-block w-1.5 h-1.5 rounded-full shrink-0 " <>
                  severity_dot_class(Map.get(risk, :severity))}></span>
                <span class={"font-medium " <> severity_text_class(Map.get(risk, :severity))}>
                  {Map.get(risk, :id)}
                </span>
                <span :if={present?(Map.get(risk, :subject))} class="text-zinc-500 break-all">
                  {Map.get(risk, :subject)}
                </span>
                <span
                  :if={match?(%DateTime{}, Map.get(risk, :detected_at))}
                  class="ml-auto text-zinc-400 shrink-0"
                >
                  {Calendar.strftime(Map.get(risk, :detected_at), "%H:%M:%S")}
                </span>
              </div>
              <p class="mt-1 text-zinc-600">{Map.get(risk, :suggestion)}</p>
            </li>
          </ol>
        </div>
        <footer class="px-3 py-2 border-t text-[10px] text-zinc-500 font-mono">
          live · raised/cleared on transitions · audit: operator.risk_*
        </footer>
      </aside>
    </div>
    """
  end

  @severity_rank %{critical: 0, warn: 1, info: 2}

  def max_severity(risks) do
    risks
    |> Enum.map(&Map.get(&1, :severity))
    |> Enum.min_by(&Map.get(@severity_rank, &1, 3), fn -> nil end)
  end

  defp sort_risks(risks),
    do: Enum.sort_by(risks, &Map.get(@severity_rank, Map.get(&1, :severity), 3))

  defp badge_class(risks) do
    case max_severity(risks) do
      :critical -> "border-red-300 bg-red-50 text-red-700"
      :warn -> "border-amber-300 bg-amber-50 text-amber-700"
      :info -> "border-zinc-300 bg-white text-zinc-600"
      _ -> "border-zinc-200 bg-white text-zinc-400"
    end
  end

  defp severity_dot_class(:critical), do: "bg-red-600"
  defp severity_dot_class(:warn), do: "bg-amber-500"
  defp severity_dot_class(:info), do: "bg-zinc-400"
  defp severity_dot_class(_), do: "bg-zinc-300"

  defp severity_text_class(:critical), do: "text-red-700"
  defp severity_text_class(:warn), do: "text-amber-700"
  defp severity_text_class(_), do: "text-zinc-600"

  defp present?(value), do: is_binary(value) and value != ""
end
