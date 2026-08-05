#!/usr/bin/env bash
# Stage Casein-infra agent skills into a provider config home.
#
# The skill files live in the casein repo under .claude/skills, so they only
# travel with casein checkouts. But Casein agents frequently run in OTHER
# product-repo worktrees (e.g. an audit of OneBackend-v3) that do not carry the
# casein skills — so an orchestrator there cannot invoke delegate-to-worker even
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
# gh-stack (vendored from github/gh-stack) is likewise repo-agnostic: it teaches
# the non-interactive `gh stack` invocations for stacked PRs, which agents need
# in every checkout, not just casein.
: "${CASEIN_GLOBAL_AGENT_SKILLS:=delegate-to-worker preview-ui-walk workspace-agent-pair gh-stack}"

# Skill names Casein used to stage and has since renamed or dropped. Staging is
# a copy, so dropping a name from the allowlist alone leaves the old directory
# behind forever — every agent then sees the retired skill *and* its replacement,
# and the stale copy is the one carrying the wrong instructions. Copies staged
# from here on carry a marker file and are pruned automatically once they leave
# the allowlist; this list exists to reach the un-markered copies staged before
# that, and can be trimmed once those have aged out. Space-separated.
: "${CASEIN_RETIRED_AGENT_SKILLS:=delegate-to-grok}"

# Marks a directory as a Casein-staged copy, so pruning can tell our copies from
# a skill the user authored or installed themselves under the same name.
CASEIN_AGENT_SKILL_MARKER=".casein-staged"

# agent_skills_install <source-skills-dir> <dest-config-dir>
#
# Copies each allow-listed skill from <source-skills-dir>/<name> into
# <dest-config-dir>/skills/<name>, refreshing only when the tree differs so the
# copy tracks the canonical source without needless churn, then prunes staged
# copies that have left the allowlist. Returns 0 in every degraded case so a
# launch never fails on skill staging.
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

    # Already current — leave user/runtime state (and mtimes) untouched. The
    # marker is ours, not the canonical source's, so it must not count as drift.
    if [[ -d "$dst" ]] &&
      diff -rq -x "${CASEIN_AGENT_SKILL_MARKER}" "$src" "$dst" >/dev/null 2>&1; then
      continue
    fi

    mkdir -p "$dst_root" 2>/dev/null || return 0
    rm -rf "$dst" 2>/dev/null || true
    cp -R "$src" "$dst" 2>/dev/null || true
    [[ -d "$dst" ]] && : >"${dst}/${CASEIN_AGENT_SKILL_MARKER}" 2>/dev/null || true
  done

  agent_skills_prune "$dst_root" "${skills[@]}"
}

# agent_skills_prune <dest-skills-dir> [allowlisted-name...]
#
# Removes staged skill copies that are no longer allow-listed. A directory is
# only ever removed when Casein can prove it staged it: either it carries the
# marker file, or its name is on the retired list. A skill the user dropped in
# themselves has neither and is left alone.
agent_skills_prune() {
  local dst_root="$1"
  shift
  [[ -n "$dst_root" && -d "$dst_root" ]] || return 0

  local -A keep=()
  local name
  for name in "$@"; do
    [[ -n "$name" ]] && keep["$name"]=1
  done

  local -A retired=()
  local -a retired_names=()
  # `read` reports 1 on empty input; callers run under `set -e`, and an empty
  # retired list must not take the launch down with it.
  read -r -a retired_names <<<"${CASEIN_RETIRED_AGENT_SKILLS:-}" || true
  for name in "${retired_names[@]+"${retired_names[@]}"}"; do
    [[ -n "$name" ]] && retired["$name"]=1
  done

  local dir
  for dir in "$dst_root"/*/; do
    [[ -d "$dir" ]] || continue
    name="$(basename "$dir")"
    [[ -n "${keep[$name]:-}" ]] && continue

    if [[ -n "${retired[$name]:-}" || -f "${dir}${CASEIN_AGENT_SKILL_MARKER}" ]]; then
      rm -rf "$dir" 2>/dev/null || true
    fi
  done
}
