// v2 — humble framing. The app is: browser terminal attached to a remote
// workspace, with a policy gate quietly in front. No mission control.
//
// Auto-binds:
//   .term[data-ws]   terminal pane attached to a workspace
//   [data-switch]    click to switch active workspace
//   .clock           updated every second
//
(() => {
  'use strict';
  const $$ = (s, r=document) => Array.from(r.querySelectorAll(s));
  const fmt = (d=new Date()) => `${String(d.getHours()).padStart(2,'0')}:${String(d.getMinutes()).padStart(2,'0')}:${String(d.getSeconds()).padStart(2,'0')}`;

  setInterval(() => $$('.clock').forEach(el => el.textContent = fmt()), 1000);

  // A short scripted session per workspace. Each entry: ["in"|"out"|"err", text, delayMs].
  const SCRIPTS = {
    alpha: [
      ['in',  'mix format --check'],
      ['out', '✓ all files formatted'],
      ['in',  'mix test --only fast'],
      ['out', '....'],
      ['out', '4 tests, 0 failures · 0.4s'],
      ['in',  ''],
    ],
    beta: [
      ['in',  'git status'],
      ['out', 'On branch feat/ingest-v2'],
      ['out', '  modified:  lib/ingest.ex'],
      ['out', '  modified:  lib/ingest/parser.ex'],
      ['out', '  modified:  test/ingest_test.exs'],
      ['in',  ''],
    ],
    gamma: [
      ['in',  'mix test'],
      ['out', 'Compiling 47 files (.ex)'],
      ['out', '....F....'],
      ['err', '1) test creates invoice (BillingTest)'],
      ['err', '   ** (Ecto.ConstraintError) check failed'],
      ['err', '   lib/billing.ex:84'],
      ['in',  'rm -rf priv/'],
      ['err', 'devide: refused — argv not in allowlist'],
      ['err', '        (audit event recorded · policy.deny)'],
      ['in',  ''],
    ],
    delta: [
      ['in',  'mix deps.get'],
      ['out', '✓ resolved 142 deps · 8.1s'],
      ['in',  ''],
    ],
  };

  function runScript(term, ws) {
    term.innerHTML = '';
    const lines = SCRIPTS[ws] || SCRIPTS.alpha;
    let i = 0;
    const promptStr = term.dataset.prompt || '$ ';
    function step() {
      if (i >= lines.length) return;
      const [kind, text] = lines[i++];
      const div = document.createElement('div');
      if (kind === 'in') {
        div.textContent = promptStr + text;
        div.className = 'tin';
      } else if (kind === 'err') {
        div.textContent = text;
        div.className = 'terr';
        if (/refused|deny/i.test(text)) flashDeny(term);
      } else {
        div.textContent = text;
        div.className = 'tout';
      }
      term.appendChild(div);
      term.scrollTop = term.scrollHeight;
      setTimeout(step, kind === 'in' ? 700 : 280);
    }
    setTimeout(step, 200);
  }

  function flashDeny(term) {
    // Visible side-effect: a quiet pill or banner near the terminal.
    const root = term.closest('[data-deny-host]') || term.parentElement;
    if (!root) return;
    let pill = root.querySelector('.deny-pill');
    if (!pill) {
      pill = document.createElement('div');
      pill.className = 'deny-pill';
      pill.textContent = '● policy refused 1';
      Object.assign(pill.style, {
        position: 'absolute', top: '8px', right: '8px',
        background: '#e94560', color: 'white', padding: '3px 8px',
        fontSize: '10px', fontFamily: 'JetBrains Mono, monospace',
        letterSpacing: '.1em', borderRadius: '3px', zIndex: '5',
        boxShadow: '0 0 12px rgba(233,69,96,.6)', transition: 'opacity .3s'
      });
      if (getComputedStyle(root).position === 'static') root.style.position = 'relative';
      root.appendChild(pill);
    } else {
      const n = parseInt(pill.textContent.match(/\d+/)?.[0] || '0', 10) + 1;
      pill.textContent = `● policy refused ${n}`;
    }
    pill.style.opacity = '1';
  }

  function bindTerminals() {
    $$('.term').forEach(t => {
      const ws = t.dataset.ws || 'alpha';
      runScript(t, ws);
    });
  }

  function bindSwitchers() {
    $$('[data-switch]').forEach(btn => {
      btn.style.cursor = 'pointer';
      btn.addEventListener('click', () => {
        const ws = btn.dataset.switch;
        // Mark active
        const group = btn.parentElement;
        group?.querySelectorAll('[data-switch]').forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        // Find the matching terminal (single-terminal layouts)
        const term = document.querySelector('.term[data-ws]');
        if (term) {
          term.dataset.ws = ws;
          runScript(term, ws);
        }
        // Update any banner/label elements
        $$('[data-current-ws]').forEach(el => el.textContent = btn.dataset.label || ws);
      });
    });
  }

  document.addEventListener('DOMContentLoaded', () => {
    bindTerminals();
    bindSwitchers();
  });
})();
