#!/usr/bin/env node
// WebSocket + Phoenix LiveView reconnect evidence for preview-ui-walk.
//
// Answers the questions a LiveView walk actually needs: did the socket connect,
// did the LiveView JOIN succeed, did it drop, did it come back, and how long did
// recovery take. A page can render a perfect first paint and still be broken if
// the socket never joins — that failure is invisible to HTTP/DOM evidence.
//
// SECURITY POSTURE (this collector sees the most sensitive traffic in the walk):
//   * URLs are sanitized — LiveView puts the session token in ?vsn=&token=, and
//     the cookie rides the upgrade. Query values are dropped, not truncated.
//   * Frame PAYLOADS ARE NEVER RETAINED. We keep direction, type, byte size and
//     timing, plus a structural summary (topic/event/status) for Phoenix frames.
//     Never the payload body, because LiveView diffs carry rendered user data.
//   * Memory is bounded: frames are capped and counted-past-cap, so a chatty
//     socket cannot balloon a walk report.

/** Phoenix message: [join_ref, ref, topic, event, payload] */
export function parsePhoenixFrame(text) {
  if (typeof text !== "string" || text.length === 0) return null;
  let msg;
  try {
    msg = JSON.parse(text);
  } catch {
    return null;
  }
  if (!Array.isArray(msg) || msg.length < 4) return null;
  const [joinRef, ref, topic, event, payload] = msg;
  const out = {
    joinRef: joinRef == null ? null : String(joinRef),
    ref: ref == null ? null : String(ref),
    topic: typeof topic === "string" ? topic : null,
    event: typeof event === "string" ? event : null,
  };
  // Reply status is the join/error signal. We read ONLY the status field —
  // never the response body, which carries rendered markup.
  if (payload && typeof payload === "object" && typeof payload.status === "string") {
    out.status = payload.status;
  }
  return out;
}

/**
 * Strip every query value from a socket URL. LiveView carries its signed
 * session token in the query string, so redaction is dropping the values
 * outright — not masking, which would still leak length.
 */
export function sanitizeSocketUrl(url) {
  if (typeof url !== "string" || !url) return null;
  try {
    const u = new URL(url);
    const keys = [...u.searchParams.keys()];
    u.search = keys.length ? `${keys.map((k) => `${k}=[redacted]`).join("&")}` : "";
    return u.toString();
  } catch {
    const q = url.indexOf("?");
    return q === -1 ? url : `${url.slice(0, q)}?[redacted]`;
  }
}

export const DEFAULTS = { maxFrames: 200, maxSockets: 10 };

/**
 * Attach to a page and accumulate socket evidence until `stop()`.
 *
 * Returns null from stop() when no socket was ever opened — honest "no
 * evidence" rather than an empty shell that reads as "collected, nothing here".
 */
export function attachWs(page, opts = {}) {
  const { maxFrames = DEFAULTS.maxFrames, maxSockets = DEFAULTS.maxSockets } = opts;
  const now = opts.now || (() => Date.now());
  const t0 = now();
  const sockets = [];
  let opens = 0;
  let closes = 0;
  let errors = 0;
  let framesDropped = 0;
  // Frame-level capture depends on the driver emitting framesent/framereceived.
  // Some Playwright/Chromium combinations emit the `websocket` event but never
  // any frame events. Zero frames must NOT be reported as "a quiet socket" — we
  // track whether ANY frame event was ever observed so the summary can say
  // "frame evidence unavailable" and fail closed under require_evidence.
  let frameEventsSeen = 0;

  const onWebSocket = (ws) => {
    opens += 1;
    if (sockets.length >= maxSockets) return;
    const rec = {
      url: sanitizeSocketUrl(ws.url?.() ?? ws.url),
      openedAtMs: now() - t0,
      closedAtMs: null,
      error: null,
      frames: [],
      counts: { sent: 0, received: 0 },
      liveview: { joins: 0, joinOk: 0, joinError: 0, topics: [] },
    };
    sockets.push(rec);

    const record = (direction, payload) => {
      const text = typeof payload === "string" ? payload : "";
      const size = typeof payload === "string" ? Buffer.byteLength(payload) : (payload?.length ?? 0);
      frameEventsSeen += 1;
      rec.counts[direction === "sent" ? "sent" : "received"] += 1;
      const phx = parsePhoenixFrame(text);
      if (phx) {
        if (phx.event === "phx_join") {
          rec.liveview.joins += 1;
          if (phx.topic && !rec.liveview.topics.includes(phx.topic)) {
            rec.liveview.topics.push(phx.topic);
          }
        }
        if (phx.event === "phx_reply" && phx.status === "ok") rec.liveview.joinOk += 1;
        if (phx.event === "phx_reply" && phx.status === "error") rec.liveview.joinError += 1;
      }
      if (rec.frames.length >= maxFrames) {
        framesDropped += 1;
        return;
      }
      // NOTE: no payload body is stored — only shape, size and timing.
      rec.frames.push({
        direction,
        atMs: now() - t0,
        type: typeof payload === "string" ? "text" : "binary",
        size,
        ...(phx ? { phx: { topic: phx.topic, event: phx.event, ...(phx.status ? { status: phx.status } : {}) } } : {}),
      });
    };

    ws.on?.("framesent", (f) => record("sent", f?.payload));
    ws.on?.("framereceived", (f) => record("received", f?.payload));
    ws.on?.("socketerror", (e) => {
      errors += 1;
      rec.error = String(e?.message || e || "socket error");
    });
    ws.on?.("close", () => {
      closes += 1;
      rec.closedAtMs = now() - t0;
    });
  };

  page.on?.("websocket", onWebSocket);

  return {
    stop() {
      page.off?.("websocket", onWebSocket);
      if (sockets.length === 0 && opens === 0) return null;
      return summarize({ sockets, opens, closes, errors, framesDropped, maxFrames, frameEventsSeen });
    },
  };
}

/**
 * Reconnect model: socket #1 opening after socket #0 closed is a reconnect
 * attempt; recovery latency is the gap between that close and the next
 * successful LiveView join (not merely the socket open — a socket that opens
 * but never re-joins has NOT recovered, and conflating them would report a
 * broken page as healthy).
 */
export function summarize({ sockets, opens, closes, errors, framesDropped, maxFrames, frameEventsSeen = 0 }) {
  const ordered = [...sockets].sort((a, b) => a.openedAtMs - b.openedAtMs);
  let reconnectAttempts = 0;
  let recoveredCount = 0;
  let recoveryLatencyMs = null;

  for (let i = 1; i < ordered.length; i++) {
    const prev = ordered[i - 1];
    const cur = ordered[i];
    if (prev.closedAtMs == null) continue;
    reconnectAttempts += 1;
    if (cur.liveview.joinOk > 0) {
      recoveredCount += 1;
      const latency = cur.openedAtMs - prev.closedAtMs;
      if (recoveryLatencyMs == null || latency < recoveryLatencyMs) recoveryLatencyMs = latency;
    }
  }

  const lv = ordered.reduce(
    (acc, s) => ({
      joins: acc.joins + s.liveview.joins,
      joinOk: acc.joinOk + s.liveview.joinOk,
      joinError: acc.joinError + s.liveview.joinError,
      topics: [...new Set([...acc.topics, ...s.liveview.topics])],
    }),
    { joins: 0, joinOk: 0, joinError: 0, topics: [] },
  );

  const framesObservable = frameEventsSeen > 0;
  return {
    capturedAt: new Date().toISOString(),
    counts: { opens, closes, errors, sockets: ordered.length },
    frames: {
      // observable:false means the driver never delivered a frame event, so
      // frame/LiveView evidence is UNAVAILABLE — not "empty". Consumers must
      // treat this as missing evidence, never as a healthy quiet socket.
      observable: frameEventsSeen > 0,
      captured: ordered.reduce((n, s) => n + s.frames.length, 0),
      dropped: framesDropped,
      cap: maxFrames,
      truncated: framesDropped > 0,
      payloadsRetained: false, // asserted by selftest — bodies are never stored
    },
    liveview: {
      ...lv,
      // LiveView state is derived from frames; without frame events it is
      // unknown, and `joined`/`healthy` must be null rather than false — false
      // would assert "did not join", which we cannot actually observe.
      observable: framesObservable,
      joined: framesObservable ? lv.joinOk > 0 : null,
      // A join that never succeeded is the signal a first-paint-only check misses.
      healthy: framesObservable ? lv.joinOk > 0 && lv.joinError === 0 : null,
    },
    reconnect: {
      disconnects: ordered.filter((s) => s.closedAtMs != null).length,
      attempts: reconnectAttempts,
      recovered: recoveredCount,
      recoveryLatencyMs,
    },
    sockets: ordered,
  };
}
