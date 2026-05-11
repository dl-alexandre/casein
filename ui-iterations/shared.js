// DevIDE iterations — shared interactivity + identity layer.
//
// PRODUCT IDENTITY (frozen here so every surface inherits it):
//   The product is a CONTROL PLANE for durable AI-assisted software
//   execution across isolated workspaces.
//   - JX     = control plane (planner, scheduler, policy authority)
//   - DevIDE = execution runtime + operator surface
//   - Workspace = isolated, durable execution environment
//   - Agent     = leased worker operating inside a workspace
//   - Assignment = durable unit of work, replay-safe
//   - Lease     = ownership token, time-bounded
//   - Audit     = replay-safe event stream
//
// Non-goals (enforced visually on every page): not an IDE, not an LSP,
// not a terminal multiplexer (tmux is an impl detail), not an agent
// framework (agents are clients of the contract).
//
// Auto-binds against classes the iterations already use:
//   .ws        workspace card / row
//   .term      "live exec inspect" pane (NOT an editor)
//   .audit, .ev, .audit-row, table tr   audit log targets
//   .row       assignment-ledger row container
//   .clock     element whose text becomes the live clock
//
(() => {
  'use strict';

  const $$  = (sel, root=document) => Array.from(root.querySelectorAll(sel));
  const fmtClock = (d=new Date()) =>
    `${String(d.getHours()).padStart(2,'0')}:${String(d.getMinutes()).padStart(2,'0')}:${String(d.getSeconds()).padStart(2,'0')}`;

  // ---- Live clock --------------------------------------------------------
  const clockTargets = () => $$('.clock, [data-clock]');
  const tick = () => {
    const t = fmtClock();
    clockTargets().forEach(el => { el.textContent = t; });
    const hud = document.getElementById('op-clock');
    if (hud) hud.textContent = t;
    const rib = document.getElementById('cp-clock');
    if (rib) rib.textContent = t;
  };
  setInterval(tick, 1000);

  // ---- Audit log helpers -------------------------------------------------
  function findAuditList() {
    const buckets = new Map();
    $$('.audit, .ev, .audit-row').forEach(el => {
      const p = el.parentElement;
      buckets.set(p, (buckets.get(p) || 0) + 1);
    });
    let best = null, n = 0;
    buckets.forEach((c, p) => { if (c > n) { n = c; best = p; } });
    return best;
  }

  function makeAuditEl(verb, detail) {
    const list = findAuditList();
    if (!list) return null;
    const proto = list.querySelector('.audit, .ev, .audit-row');
    if (!proto) return null;
    const clone = proto.cloneNode(true);
    const cells = clone.children;
    if (cells.length >= 3) {
      cells[0].textContent = fmtClock();
      cells[1].textContent = verb;
      cells[1].classList.toggle('r', verb === 'DENY' || verb === 'deny');
      cells[1].classList.toggle('deny', verb === 'DENY' || verb === 'deny');
      cells[2].textContent = detail;
    } else {
      clone.textContent = `${fmtClock()}  ${verb}  ${detail}`;
    }
    clone.dataset.verb = verb.toUpperCase();
    clone.style.animation = 'op-flash 1.2s ease';
    list.insertBefore(clone, list.firstElementChild);
    return clone;
  }

  // ---- Assignment ledger helpers ----------------------------------------
  function findRunList() {
    const buckets = new Map();
    $$('.row').forEach(el => {
      const p = el.parentElement;
      buckets.set(p, (buckets.get(p) || 0) + 1);
    });
    let best = null, n = 0;
    buckets.forEach((c, p) => { if (c > n) { n = c; best = p; } });
    return best;
  }
  function appendAssignment(cmd, status, ok=true) {
    const list = findRunList();
    if (!list) return;
    const proto = list.querySelector('.row');
    if (!proto) return;
    const clone = proto.cloneNode(true);
    const spans = clone.querySelectorAll('span');
    if (spans.length >= 2) {
      spans[0].textContent = cmd;
      spans[1].textContent = status;
      spans[1].className = ok ? 'ok' : 'fail';
    }
    clone.style.animation = 'op-flash 1.2s ease';
    list.insertBefore(clone, list.firstElementChild);
  }

  // ---- Workspace selection ----------------------------------------------
  function bindWorkspaces() {
    $$('.ws').forEach(ws => {
      ws.style.cursor = 'pointer';
      ws.title = 'isolated execution environment — click to focus';
      ws.addEventListener('click', (e) => {
        if (e.target.closest('.md')) return;
        $$('.ws').forEach(w => {
          w.style.outline = '';
          w.style.outlineOffset = '';
        });
        ws.style.outline = '2px solid currentColor';
        ws.style.outlineOffset = '4px';
        const name = (ws.querySelector('.nm, .name')?.textContent || ws.textContent).trim().split('\n')[0];
        const chip = document.getElementById('op-selws');
        if (chip) chip.textContent = name.slice(0, 28);
        makeAuditEl('FOCUS', `operator focused workspace ${name.slice(0,32)}`);
      });
    });
  }

  // ---- Mode chip cycling (workspace mode = admission policy) ------------
  function bindModeChips() {
    const cycle = ['safe', 'review', 'write'];
    $$('.md').forEach(md => {
      md.style.cursor = 'pointer';
      md.title = 'workspace mode — admission policy. click to cycle.';
      md.addEventListener('click', (e) => {
        e.stopPropagation();
        const cur = md.textContent.trim().toLowerCase();
        const wasUpper = cur === cur.toUpperCase() && cur.length > 1;
        const next = cycle[(cycle.indexOf(cur) + 1) % cycle.length] || 'safe';
        md.textContent = wasUpper ? next.toUpperCase() : next;
        ['safe','review','write','w','r','s'].forEach(c => md.classList.remove(c));
        md.classList.add(next);
        if (next === 'write') md.classList.add('w','r');
        const wsName = md.closest('.ws')?.querySelector('.nm, .name')?.textContent.trim().split('\n')[0] || 'workspace';
        makeAuditEl('MODE', `${wsName} → ${next}`);
      });
    });
  }

  // ---- "Live exec inspect" pane -- read-only attach to a leased session.
  // (NOT an editor. NOT a shell. Just an inspection view onto agent output.)
  function bindTerminals() {
    $$('.term').forEach(term => {
      term.tabIndex = 0;
      term.style.cursor = 'text';
      let buf = '';
      const promptStr = 'inspect> ';
      const cursor = '█';
      const cursorEl = document.createElement('span');
      cursorEl.textContent = cursor;
      cursorEl.style.animation = 'op-blink 1s steps(2) infinite';
      const inputEl = document.createElement('span');
      const lineEl = document.createElement('div');
      lineEl.append(document.createTextNode(promptStr), inputEl, cursorEl);
      term.append(lineEl);
      term.addEventListener('click', () => term.focus());
      term.addEventListener('keydown', (e) => {
        if (e.key === 'Backspace') { buf = buf.slice(0, -1); }
        else if (e.key === 'Enter') {
          const cmd = buf.trim();
          buf = '';
          if (cmd) executeFakeCmd(cmd, term, lineEl, inputEl, cursorEl, promptStr);
          else { lineEl.before(makeLine(promptStr)); }
        }
        else if (e.key.length === 1) { buf += e.key; }
        else { return; }
        e.preventDefault();
        inputEl.textContent = buf;
      });
    });
  }
  function makeLine(text) {
    const d = document.createElement('div');
    d.textContent = text;
    return d;
  }
  function executeFakeCmd(cmd, term, lineEl, inputEl, cursorEl, promptStr) {
    const finished = makeLine(promptStr + cmd);
    lineEl.before(finished);
    inputEl.textContent = '';
    let outputs = [];
    const lower = cmd.toLowerCase();
    if (lower.startsWith('rm -rf') || lower.startsWith('git push --force')) {
      outputs = ['admission.deny: argv not in allowlist', 'audit event recorded'];
      makeAuditEl('DENY', cmd.slice(0, 60));
    } else if (lower.startsWith('assign ') || lower.startsWith('mix test')) {
      outputs = ['assignment queued · awaiting agent claim', 'agent claude@host-1 claimed lease 28s', 'report: compile ok', 'report: tests run, 1 failure', 'assignment terminal: failed'];
      makeAuditEl('ASSIGN', cmd);
      appendAssignment(cmd, '▶ leased');
    } else if (lower.startsWith('lease')) {
      outputs = ['lease a4b2 → claude@host-1 · 28s remaining', 'lease b733 → unleased (queued)', 'lease c901 → unleased (queued)', 'lease 9c11 → expired, reclaimed at 13:59'];
    } else if (lower.startsWith('agents') || lower === 'fleet') {
      outputs = ['claude@host-1   leased a4b2   28s', 'codex@host-2    idle           heartbeat 3s', 'opencode@host-3 idle           heartbeat 5s'];
    } else if (lower.startsWith('replay')) {
      outputs = ['replaying audit log...', '47 events, 0 mutations applied (idempotent)', 'state: consistent'];
      makeAuditEl('REPLAY', '47 events absorbed · idempotent');
    } else if (lower.startsWith('mode ')) {
      const m = lower.split(' ')[1];
      outputs = [`workspace mode → ${m}`, 'admission policy updated'];
      makeAuditEl('MODE', `cli → ${m}`);
    } else if (lower === 'help' || lower === '?') {
      outputs = ['CONTROL PLANE INSPECT — read-only attach',
                 'commands:',
                 '  assign <cmd>   queue an assignment',
                 '  lease          show lease state',
                 '  agents         list fleet',
                 '  replay         replay audit log (idempotent)',
                 '  mode <m>       cycle workspace mode',
                 '  rm -rf priv/   (will be denied)',
                 'note: this is not a shell. not an editor. inspection only.'];
    } else if (lower === 'clear') {
      Array.from(term.children).forEach(c => { if (c !== lineEl) c.remove(); });
      return;
    } else {
      outputs = [`devide: ${cmd}: unknown (try "help")`];
    }
    outputs.forEach(o => lineEl.before(makeLine(o)));
    term.scrollTop = term.scrollHeight;
  }

  // ---- Identity ribbon (top) + Non-goals strip (bottom) -----------------
  // These appear on EVERY page so the product identity is enforced
  // visually even where individual designs forgot to say it.
  function buildIdentity() {
    const css = `
      #cp-ribbon {
        position: fixed; top: 0; left: 0; right: 0; z-index: 9998;
        font-family: 'JetBrains Mono', ui-monospace, monospace;
        font-size: 10px; letter-spacing: .25em; text-transform: uppercase;
        background: linear-gradient(90deg, rgba(0,0,0,.85), rgba(0,0,0,.7));
        color: #ffea00; padding: 4px 14px;
        border-bottom: 1px solid rgba(255,234,0,.4);
        display: flex; justify-content: space-between; gap: 14px;
        backdrop-filter: blur(6px);
      }
      #cp-ribbon b { color: #f5f5fa; font-weight: 400; }
      #cp-ribbon .dim { color: #888; }
      body { padding-top: 22px; }
      #cp-nongoals {
        position: fixed; left: 14px; bottom: 14px; z-index: 9997;
        font-family: 'JetBrains Mono', ui-monospace, monospace;
        font-size: 9px; letter-spacing: .15em; text-transform: uppercase;
        background: rgba(10,10,18,.85); color: #aaa;
        backdrop-filter: blur(8px);
        border: 1px solid rgba(255,255,255,.1);
        border-radius: 6px; padding: 6px 10px; line-height: 1.5;
        max-width: 280px;
      }
      #cp-nongoals b { color: #e94560; font-weight: 700; }
      #cp-nongoals .strike { text-decoration: line-through; color: #777; }
    `;
    const style = document.createElement('style');
    style.textContent = css;
    document.head.appendChild(style);

    const ribbon = document.createElement('div');
    ribbon.id = 'cp-ribbon';
    ribbon.innerHTML = `
      <span><b>CONTROL PLANE</b> · durable AI-assisted software execution</span>
      <span class="dim">JX = scheduler · DevIDE = runtime · workspace = pod · agent = worker</span>
      <span id="cp-clock">--:--:--</span>
    `;
    document.body.appendChild(ribbon);

    const non = document.createElement('div');
    non.id = 'cp-nongoals';
    non.innerHTML = `
      <b>NON-GOALS</b><br>
      <span class="strike">code editor · LSP host · terminal multiplexer · agent framework</span>
    `;
    document.body.appendChild(non);
  }

  // ---- Operator console (floating, bottom-right) ------------------------
  function buildConsole() {
    const css = `
      @keyframes op-flash { 0% { background: rgba(255,234,0,.5); } 100% { background: transparent; } }
      @keyframes op-blink { 50% { opacity: 0; } }
      #op-console {
        position: fixed; right: 14px; bottom: 14px; z-index: 9999;
        font-family: 'JetBrains Mono', 'IBM Plex Mono', ui-monospace, monospace;
        font-size: 11px; line-height: 1.4; color: #f5f5fa;
        background: rgba(10,10,18,.92); backdrop-filter: blur(10px);
        border: 1px solid rgba(255,234,0,.4);
        border-radius: 10px; padding: 10px 12px; min-width: 280px;
        box-shadow: 0 8px 32px rgba(0,0,0,.5), 0 0 0 1px rgba(255,255,255,.04) inset;
        text-transform: none; letter-spacing: 0; text-shadow: none;
      }
      #op-console.hidden .op-body { display: none; }
      #op-console h4 {
        font-size: 9px; letter-spacing: .25em; text-transform: uppercase;
        color: #ffea00; margin-bottom: 6px; display: flex; justify-content: space-between;
        cursor: pointer; user-select: none;
      }
      #op-console h4 b { color: #f5f5fa; font-weight: 400; }
      #op-console .op-row { display: flex; gap: 6px; margin-top: 8px; flex-wrap: wrap; }
      #op-console button {
        font: inherit; color: #f5f5fa; background: rgba(255,255,255,.06);
        border: 1px solid rgba(255,255,255,.18); padding: 4px 8px; border-radius: 5px;
        cursor: pointer; font-size: 10px; letter-spacing: .05em;
      }
      #op-console button:hover { background: rgba(255,234,0,.15); border-color: #ffea00; color: #ffea00; }
      #op-console button.deny:hover { background: rgba(233,69,96,.2); border-color: #e94560; color: #e94560; }
      #op-console .op-meta { color: #aaa; font-size: 10px; margin-top: 6px; display: grid; gap: 2px; }
      #op-console .op-meta span b { color: #f5f5fa; font-weight: 400; }
      #op-console .op-fleet {
        font-size: 10px; color: #aaa; margin-top: 6px; padding-top: 6px;
        border-top: 1px dashed rgba(255,255,255,.1);
      }
      #op-console .op-fleet b { color: #a8eb12; font-weight: 400; }
      #op-console .op-chips { display: flex; gap: 4px; margin-top: 6px; flex-wrap: wrap; }
      #op-console .op-chips span {
        font-size: 9px; letter-spacing: .15em; padding: 2px 6px; border-radius: 4px;
        background: rgba(255,255,255,.06); cursor: pointer; user-select: none;
      }
      #op-console .op-chips span.active { background: #ffea00; color: #0a0a12; }
      .op-filtered { display: none !important; }
    `;
    const style = document.createElement('style');
    style.textContent = css;
    document.head.appendChild(style);

    const root = document.createElement('div');
    root.id = 'op-console';
    root.innerHTML = `
      <h4 onclick="this.parentElement.classList.toggle('hidden')">
        ◆ OPERATOR · CONTROL PLANE <b id="op-clock">--:--:--</b>
      </h4>
      <div class="op-body">
        <div class="op-meta">
          <span>focus: <b id="op-selws">— click a workspace —</b></span>
          <span>assignments: <b id="op-runs">0</b> · denies: <b id="op-denies">0</b> · events: <b id="op-evts">0</b></span>
        </div>
        <div class="op-row">
          <button data-act="assign">▶ queue assignment</button>
          <button data-act="lease">renew lease</button>
          <button data-act="replay">replay audit</button>
          <button data-act="deny" class="deny">try denied argv</button>
          <button data-act="cycle">cycle γ mode</button>
        </div>
        <div class="op-fleet">
          fleet: <b>claude@host-1</b> leased a4b2 · <b>codex@host-2</b> idle · <b>opencode@host-3</b> idle
        </div>
        <div class="op-chips">
          <span data-filter="all" class="active">ALL</span>
          <span data-filter="ALLOW">ALLOW</span>
          <span data-filter="DENY">DENY</span>
          <span data-filter="ASSIGN">ASSIGN</span>
          <span data-filter="LEASE">LEASE</span>
          <span data-filter="MODE">MODE</span>
          <span data-filter="REPLAY">REPLAY</span>
        </div>
      </div>
    `;
    document.body.appendChild(root);

    let runs = 0, denies = 0, evts = 0;
    const bump = (k) => {
      if (k === 'run') runs++; if (k === 'deny') denies++; evts++;
      document.getElementById('op-runs').textContent = runs;
      document.getElementById('op-denies').textContent = denies;
      document.getElementById('op-evts').textContent = evts;
    };

    root.querySelectorAll('button').forEach(b => {
      b.addEventListener('click', () => {
        const act = b.dataset.act;
        if (act === 'assign') {
          makeAuditEl('ASSIGN', 'mix test → γ-billing · queued');
          appendAssignment('mix test → γ-billing', '▶ queued');
          bump('run');
        }
        if (act === 'lease') {
          makeAuditEl('LEASE', 'a4b2 → claude@host-1 · renewed 30s');
          bump('lease');
        }
        if (act === 'replay') {
          makeAuditEl('REPLAY', '47 events absorbed · 0 mutations · idempotent');
          bump('replay');
        }
        if (act === 'deny')   { makeAuditEl('DENY',  'rm -rf priv/ · admission denied'); bump('deny'); }
        if (act === 'cycle')  {
          const g = $$('.ws').find(w => /γ|gamma/i.test(w.textContent));
          g?.querySelector('.md')?.click();
          bump('mode');
        }
      });
    });

    root.querySelectorAll('.op-chips span').forEach(chip => {
      chip.addEventListener('click', () => {
        root.querySelectorAll('.op-chips span').forEach(s => s.classList.remove('active'));
        chip.classList.add('active');
        const f = chip.dataset.filter;
        $$('.audit, .ev, .audit-row').forEach(row => {
          if (f === 'all') row.classList.remove('op-filtered');
          else {
            const txt = (row.dataset.verb || row.textContent).toUpperCase();
            row.classList.toggle('op-filtered', !txt.includes(f));
          }
        });
      });
    });
  }

  // ---- Boot --------------------------------------------------------------
  document.addEventListener('DOMContentLoaded', () => {
    tick();
    bindWorkspaces();
    bindModeChips();
    bindTerminals();
    buildIdentity();
    buildConsole();
  });
})();
