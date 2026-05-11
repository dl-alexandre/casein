// v3 — terminal-native remote workspace operating environment.
//
// Visible primary story: attach to a workspace from anywhere.
// Hidden depth (lease/audit/replay) surfaces only on demand.
//
// Three deployment modes the same UI adapts to:
//   local   - browser → DevIDE on localhost → local tmux
//   remote  - browser → remote DevIDE → persistent remote workspaces
//   fleet   - browser → JX control plane → DevIDE authorities → runner fleet
//
(() => {
  'use strict';
  const $$ = (s, r=document) => Array.from(r.querySelectorAll(s));
  const fmt = (d=new Date()) => `${String(d.getHours()).padStart(2,'0')}:${String(d.getMinutes()).padStart(2,'0')}:${String(d.getSeconds()).padStart(2,'0')}`;
  setInterval(() => $$('.clock').forEach(el => el.textContent = fmt()), 1000);

  // Host registry — same UI attaches to any of these.
  window.HOSTS = {
    localhost:    { mode: 'local',  label: 'localhost',     hint: 'this machine',           latency: '0ms'   },
    'lan-mbp':    { mode: 'local',  label: 'lan-mbp.local', hint: 'over LAN',               latency: '2ms'   },
    'cloud-1':    { mode: 'remote', label: 'cloud-1.dev',   hint: 'persistent remote',      latency: '38ms'  },
    'prod-runner':{ mode: 'fleet',  label: 'prod-runner-2', hint: 'fleet · governed',       latency: '64ms'  },
    'jx-east':    { mode: 'fleet',  label: 'jx-east-3',     hint: 'fleet · jx-managed',     latency: '71ms'  },
  };

  // Per-workspace scripted sessions.
  const SCRIPTS = {
    alpha: [
      ['in', 'mix format --check'], ['out', '✓ all files formatted'],
      ['in', 'mix test --only fast'], ['out', '....'], ['out', '4 tests · 0 failures · 0.4s'],
      ['in', ''],
    ],
    beta: [
      ['in', 'git status'],
      ['out', 'On branch feat/ingest-v2'],
      ['out', '  modified:  lib/ingest.ex'],
      ['out', '  modified:  lib/ingest/parser.ex'],
      ['in', ''],
    ],
    gamma: [
      ['in', 'mix test'],
      ['out', 'Compiling 47 files (.ex)'],
      ['out', '....F....'],
      ['err', '1) ** (Ecto.ConstraintError) check failed · lib/billing.ex:84'],
      ['in', 'rm -rf priv/'],
      ['err', 'devide: refused — argv not in allowlist'],
      ['err', '        (audit event recorded · policy.deny)'],
      ['in', ''],
    ],
    delta: [
      ['in', 'mix deps.get'], ['out', '✓ resolved 142 deps · 8.1s'],
      ['in', ''],
    ],
    home: [
      ['out', '# attached to ~/code/myapp on localhost'],
      ['in', 'ls'], ['out', 'lib/  test/  mix.exs  README.md'],
      ['in', ''],
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
      div.className = kind === 'in' ? 'tin' : kind === 'err' ? 'terr' : 'tout';
      div.textContent = kind === 'in' ? promptStr + text : text;
      if (kind === 'err' && /refused|deny/i.test(text)) flashDeny(term);
      term.appendChild(div);
      term.scrollTop = term.scrollHeight;
      setTimeout(step, kind === 'in' ? 700 : 280);
    }
    setTimeout(step, 200);
  }

  function flashDeny(term) {
    const root = term.closest('[data-deny-host]') || term.parentElement;
    if (!root) return;
    let pill = root.querySelector('.deny-pill');
    if (!pill) {
      pill = document.createElement('div');
      pill.className = 'deny-pill';
      pill.textContent = '● 1 refused';
      Object.assign(pill.style, {
        position: 'absolute', top: '8px', right: '8px',
        background: '#e94560', color: 'white', padding: '3px 8px',
        fontSize: '10px', fontFamily: 'JetBrains Mono, monospace',
        letterSpacing: '.1em', borderRadius: '3px', zIndex: '5',
        boxShadow: '0 0 12px rgba(233,69,96,.6)',
      });
      if (getComputedStyle(root).position === 'static') root.style.position = 'relative';
      root.appendChild(pill);
    } else {
      const n = parseInt(pill.textContent.match(/\d+/)?.[0] || '0', 10) + 1;
      pill.textContent = `● ${n} refused`;
    }
  }

  function bindTerminals() {
    $$('.term').forEach(t => runScript(t, t.dataset.ws || 'alpha'));
  }

  function bindSwitchers() {
    $$('[data-switch]').forEach(btn => {
      btn.style.cursor = 'pointer';
      btn.addEventListener('click', () => {
        const ws = btn.dataset.switch;
        const group = btn.parentElement;
        group?.querySelectorAll('[data-switch]').forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        const term = document.querySelector('.term[data-ws]');
        if (term) { term.dataset.ws = ws; runScript(term, ws); }
        $$('[data-current-ws]').forEach(el => el.textContent = btn.dataset.label || ws);
      });
    });
    // Host switchers (mode badge)
    $$('[data-host]').forEach(btn => {
      btn.style.cursor = 'pointer';
      btn.addEventListener('click', () => {
        const id = btn.dataset.host;
        const h = window.HOSTS[id]; if (!h) return;
        $$('[data-host]').forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        $$('[data-current-host]').forEach(el => el.textContent = h.label);
        $$('[data-current-mode]').forEach(el => {
          el.textContent = h.mode;
          el.dataset.mode = h.mode;
        });
        $$('[data-current-latency]').forEach(el => el.textContent = h.latency);
      });
    });
  }

  document.addEventListener('DOMContentLoaded', () => {
    bindTerminals();
    bindSwitchers();
  });
})();
