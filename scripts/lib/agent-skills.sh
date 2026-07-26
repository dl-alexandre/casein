#!/usr/bin/env bash
# Stage Casein-infra agent skills into a provider config home.
#
# The skill files live in the casein repo under .claude/skills, so they only
# travel with casein checkouts. But Casein agents frequently run in OTHER
# product-repo worktrees (e.g. an audit of OneBackend-v3) that do not carry the
# casein skills — so an orchestrator there cannot invoke delegate-to-grok even
# though the capability is host infrastructure, not app code.
#
# Used by launch-casein-agent.sh for:
#   - Claude → $CLAUDE_CONFIG_DIR or ~/.claude  (skills/<name>/SKILL.md)
#   - OpenCode → ~/.config/opencode and project .opencode
#     (skills/<name>/SKILL.md; OpenCode also auto-loads ~/.claude/skills)
#
# Copies are idempotent, opt-out via CASEIN_AGENT_SKILLS=0, best-effort
# (never fail the launch).

# Skills that are Casein host infrastructure (they drive Casein MCP / the
# spawn-agent-worker helper) and therefore belong in every agent's config home
# regardless of the checked-out repo. Project-specific skills (e.g. `verify`,
# which runs the casein dev server from the current checkout) are intentionally
# excluded: they only make sense inside the casein checkout, where the project
# .claude/skills copy already provides them. Space-separated; override to extend.
# preview-ui-walk is host infrastructure for product-repo agents (OneBackend-v3
# etc.): it drives Casein preview/artifact MCP, not the casein checkout itself.
: "${CASEIN_GLOBAL_AGENT_SKILLS:=delegate-to-grok preview-ui-walk workspace-agent-pair}"

# agent_skills_install <source-skills-dir> <dest-config-dir>
#
# Copies each allow-listed skill from <source-skills-dir>/<name> into
# <dest-config-dir>/skills/<name>, refreshing only when the tree differs so the
# copy tracks the canonical source without needless churn. Returns 0 in every
# degraded case so a launch never fails on skill staging.
agent_skills_install() {
  local src_root="$1"
  local config_dir="$2"

  [[ "${CASEIN_AGENT_SKILLS:-1}" != "0" ]] || return 0
  [[ -n "$src_root" && -d "$src_root" ]] || return 0
  [[ -n "$config_dir" ]] || return 0

  local dst_root="${config_dir}/skills"
  local -a skills
  read -r -a skills <<<"${CASEIN_GLOBAL_AGENT_SKILLS}"

  local name src dst
  for name in "${skills[@]}"; do
    [[ -n "$name" ]] || continue
    src="${src_root}/${name}"
    dst="${dst_root}/${name}"
    [[ -d "$src" ]] || continue

    # Already current — leave user/runtime state (and mtimes) untouched.
    if [[ -d "$dst" ]] && diff -rq "$src" "$dst" >/dev/null 2>&1; then
      continue
    fi

    mkdir -p "$dst_root" 2>/dev/null || return 0
    rm -rf "$dst" 2>/dev/null || true
    cp -R "$src" "$dst" 2>/dev/null || true
  done
}
