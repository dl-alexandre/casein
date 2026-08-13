#!/usr/bin/env bash
#
# Public-surface / portable-defaults policy (#248).
#
# Fails when MILC operator identity, domains, or workstation paths leak into the
# *portable product surface* (lib/ + config/) as unconditional defaults a fresh
# clone would inherit.
#
# Allowlist (keep small; every entry needs a one-line reason):
#   - config/runtime.exs  — ON_DEVBOX-gated overlay defaults only
#   - lib/casein/origin.ex — legacy origin rewrite table (retired hosts only)
#
# Not scanned: docs/, shell host-ops under scripts/*.sh, test fixtures (except
# when this script is driven against a planted temp tree). Host-ops shell and
# AGENTS.md remain private-overlay debt. Shipped JS tooling under scripts/*
# *is* scanned (rule 7) — absolute operator imports break fresh clones.
# Rules 8–10: /Users/milc in lib+config, /opt/casein/deploy-build product
# fallbacks, and hardcoded tmux -L casein in lib/ (use TmuxServer.args/0).
# HostMode `/data/workspaces` is an on-host gate — do not scan it here.
#
# Exit 0 = clean. Exit 1 = violation (printed).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}" || exit 1

violations=0

fail() {
  printf '>>> check-portable-defaults-guard: %s\n' "$*" >&2
  violations=$((violations + 1))
}

# Allowlisted product files that may still mention milcgroup under a documented
# gate. Everything else under lib/ + config/ is denied.
allowlisted_milc() {
  case "$1" in
    # ON_DEVBOX-only canonical host / preview domain / forward-auth domain.
    config/runtime.exs) return 0 ;;
    # Retired-host rewrite table consumed only when canonical_public_origin is set.
    lib/casein/origin.ex) return 0 ;;
    *) return 1 ;;
  esac
}

# --- 1. Quoted /home/devbox product fallbacks ---------------------------------
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  fail "host-specific home fallback: ${hit}"
done < <(
  grep -RIn --include='*.ex' --include='*.exs' \
    -E '["'\'']/home/devbox["'\'']' lib config 2>/dev/null || true
)

# --- 2. Fixed operator checkout path as a product default ---------------------
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  fail "operator checkout path as product default: ${hit}"
done < <(
  grep -RIn --include='*.ex' --include='*.exs' \
    -E '/data/workspaces/dalexandre' lib config 2>/dev/null || true
)

# --- 3. Agent worktree root hard-coded as a product default -------------------
# Generic "/data/casein-agent-worktrees" comments are fine; a quoted path used as
# a fallback/default is not.
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  fail "agent worktree root as product default: ${hit}"
done < <(
  grep -RIn --include='*.ex' --include='*.exs' \
    -E '["'\'']/data/casein-agent-worktrees[^"'\'']*["'\'']' lib config 2>/dev/null || true
)

# --- 4. milcgroup / devbox.milc domains outside the allowlist -----------------
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  file="${hit%%:*}"
  if allowlisted_milc "$file"; then
    continue
  fi
  fail "MILC domain outside allowlist: ${hit}"
done < <(
  grep -RIn --include='*.ex' --include='*.exs' \
    -E 'milcgroup\.com|devbox\.milc' lib config 2>/dev/null || true
)

# --- 5. runtime.exs must keep milcgroup behind on_devbox? ---------------------
if grep -nE 'milcgroup\.com|devbox\.milc' config/runtime.exs >/dev/null 2>&1; then
  if ! grep -q 'on_devbox' config/runtime.exs; then
    fail "config/runtime.exs references milcgroup without an on_devbox gate"
  fi

  # Portable preview_own_origin must not use a milcgroup System.get_env/2 default.
  if grep -nE 'System\.get_env\("CASEIN_PREVIEW_DOMAIN",[[:space:]]*"devbox\.milcgroup\.com"\)' \
    config/runtime.exs >/dev/null 2>&1; then
    fail 'CASEIN_PREVIEW_DOMAIN still defaults to devbox.milcgroup.com for every profile'
  fi

  # forward_auth_email_domain milcgroup default must sit inside an on_devbox? block.
  # Cheap structural check: the assignment line must appear after an `if on_devbox?`.
  if grep -n 'forward_auth_email_domain.*"milcgroup\.com"' config/runtime.exs >/dev/null 2>&1; then
    if ! awk '
      /if on_devbox\?/ { gated=1 }
      /forward_auth_email_domain.*"milcgroup\.com"/ {
        if (!gated) { exit 1 }
      }
      END { exit 0 }
    ' config/runtime.exs; then
      fail 'forward_auth_email_domain milcgroup default is not inside an on_devbox? branch'
    fi
  fi
fi

# --- 6. origin.ex legacy table must stay a closed allowlist -------------------
if [ -f lib/casein/origin.ex ]; then
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    case "$hit" in
      *devide.devbox.milcgroup.com*) continue ;;
      *local.dalexandre-devide.devbox.milcgroup.com*) continue ;;
      *)
        fail "origin.ex milcgroup entry outside legacy rewrite table: ${hit}"
        ;;
    esac
  done < <(
    grep -nE 'milcgroup\.com|devbox\.milc' lib/casein/origin.ex 2>/dev/null || true
  )
fi

# --- 7. scripts/* tool imports must not pin an operator checkout --------------
# Node tooling under scripts/ ships with the repo. Absolute imports of
# /data/workspaces/… (or other host roots) break every fresh clone and every
# non-MILC host — same class as #846 cold-tree npm ci.
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  fail "operator path in shipped script tooling: ${hit}"
done < <(
  grep -RIn --include='*.mjs' --include='*.js' --include='*.cjs' --include='*.ts' \
    -E '/data/workspaces/|/data/casein-agent-worktrees|["'\'']/home/devbox["'\'']|["'\'']/Users/milc' \
    scripts 2>/dev/null || true
)

# --- 8. /Users/milc product fallbacks in lib/ + config/ -----------------------
# Same class as /home/devbox: a Mac operator home must not be a product default.
# HostMode /data/workspaces is an on-host gate (fenced) — do not add it here.
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  fail "host-specific home fallback: ${hit}"
done < <(
  grep -RIn --include='*.ex' --include='*.exs' \
    -E '["'\'']/Users/milc["'\'']' lib config 2>/dev/null || true
)

# --- 9. /opt/casein/deploy-build is overlay builder layout, not a product default
# Release code may look under CASEIN_SCRIPTS / CASEIN_CHECKOUT / cwd-relative
# scripts/. The MILC deploy-build worktree is host overlay only (#248).
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  fail "deploy-build path as product default: ${hit}"
done < <(
  grep -RIn --include='*.ex' --include='*.exs' \
    -E '["'\'']/opt/casein/deploy-build' lib config 2>/dev/null || true
)

# --- 10. lib/ must not hard-code tmux -L casein ------------------------------
# Labels come from :tmux_server_label via TmuxServer.args/0. A literal
# `-L casein` in product code ignores the configured label (and the test
# sandbox). Comments and config :tmux_server_label assignments are fine.
# casein_dev / casein_test suffixes are not this rule.
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  fail "hardcoded tmux -L casein (use TmuxServer.args/0): ${hit}"
done < <(
  grep -RIn --include='*.ex' \
    -E '["'\'']-L["'\''],[[:space:]]*["'\'']casein["'\'']|tmux -L casein([^_a-zA-Z0-9]|$)' \
    lib 2>/dev/null \
    | grep -v ':[[:space:]]*#' \
    || true
)

if [ "$violations" -gt 0 ]; then
  printf '\n>>> check-portable-defaults-guard: %s violation(s). See issue #248.\n' "$violations" >&2
  exit 1
fi

echo ">>> check-portable-defaults-guard: public product surface is host-agnostic."
exit 0
