export const AGENT_REFERENCE_MIME = "application/x-casein-agent-reference"

const REFERENCE_SELECTOR = "[data-agent-reference-kind]"

export function referencePayload(element) {
  const kind = element?.dataset.agentReferenceKind
  if (!["session", "window"].includes(kind)) return null

  return {
    kind,
    workspace_id: element.dataset.agentReferenceWorkspaceId || "",
    session_id: element.dataset.agentReferenceSessionId || "",
    tmux_session: element.dataset.agentReferenceTmuxSession || "",
    window_id: element.dataset.agentReferenceWindowId || "",
    window_index: element.dataset.agentReferenceWindowIndex || "",
    label: element.dataset.agentReferenceLabel || "",
  }
}

export function installAgentReferenceDragSources(root = document) {
  const onDragStart = (event) => {
    const source = event.target?.closest?.(REFERENCE_SELECTOR)
    if (!source || !event.dataTransfer) return

    const payload = referencePayload(source)
    if (!payload) return

    event.dataTransfer.setData(AGENT_REFERENCE_MIME, JSON.stringify(payload))
    event.dataTransfer.setData(
      "text/uri-list",
      source.href || source.dataset.ctxHref || "",
    )
  }

  root.addEventListener("dragstart", onDragStart)
  return () => root.removeEventListener("dragstart", onDragStart)
}

export function readAgentReference(dataTransfer) {
  if (!dataTransfer?.types?.includes?.(AGENT_REFERENCE_MIME)) return null

  try {
    const payload = JSON.parse(dataTransfer.getData(AGENT_REFERENCE_MIME))
    return ["session", "window"].includes(payload?.kind) ? payload : null
  } catch (_error) {
    return null
  }
}
