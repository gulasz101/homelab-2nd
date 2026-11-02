#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SOPS config gate (GUL-784).
#
# WHY THIS EXISTS: sops finds its config by walking UP from the directory you
# RUN IT IN — nearest file wins. It never looks at the file it is encrypting.
# So a second .sops.yaml in a subdirectory silently shadows the repo-root one,
# and `sops updatekeys` run from inside that subdirectory REMOVES every
# recipient the nested file does not list, exiting 0. The secret stays valid
# for whoever is left and unreadable for everyone else, and nobody finds out
# until a host that lost its key tries to decrypt. That already cost a
# Telegram hand-off (GUL-758, riff_radar ops/.sops.yaml, PR #9).
#
# WHAT IT ASSERTS, per repo:
#   1. at most ONE .sops.yaml, and it is at the repo root;
#   2. every creation rule names BOTH age recipients (the current paperclip /
#      flux identity AND the pre-rotation homelab identity), so a re-key never
#      drops a host that still has to read the files;
#   3. a repo that carries encrypted files carries a .sops.yaml at all
#      (riff_radar had a secret and no config — nothing said which key it wanted).
#
# WHAT IT DOES NOT DO: never calls sops, never decrypts, never prints anything
# but public age recipients and paths. Safe in CI and on a public repo.
#
# RUNNING IT OUTSIDE homelab-2nd: this file is plain bash + yq + git, so copy
# or reference it from any checkout:
#     bash ~/Projects/homelab-2nd/scripts/tests/sops-config-check.sh ~/Projects/arr-stack
#     bash scripts/tests/sops-config-check.sh /path/repo-a /path/repo-b
# With no argument it checks the git top-level of the current directory.
#
# Usage:  bash scripts/tests/sops-config-check.sh [repo ...]
# Exit:   0 = every repo passed, 1 = at least one failed.
# ---------------------------------------------------------------------------
set -uo pipefail

# The two identities every creation rule must name. Public keys only; the
# private halves are in the password manager / ~/.keys on the owner's Mac.
#   current  = the paperclip Air identity, also what flux-system/sops-age holds
#   previous = the homelab key rotated out on 16 Oct 2026, still deployed on
#              boxes that have not been re-keyed yet
EXPECTED_AGE=(
  "age195fednlfd8q35tvyvf7umlseu4ez37k2m2d0wjawmje6nr9kzgyquhau9s"  # current: paperclip Air + flux
  "age1mt6y86q9lhrmky0c0j7xwvacfzpep3w6e7z8zsrr22jj2u49gs6s59h7w2"  # previous: homelab key, pre-16-Oct
)

fail=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }
note() { printf '  note  %s\n' "$1"; }
head1() { printf '\n== %s\n' "$1"; }

# Repo path -> absolute path. Prints nothing, returns 1 on a missing dir.
resolve_repo() {
  local p="$1"
  [ -d "$p" ] || return 1
  (cd "$p" && pwd -P)
}

is_git_repo() { git -C "$1" rev-parse --git-dir >/dev/null 2>&1; }

# Every path in the repo that matches a regex: tracked OR untracked-but-not-
# ignored, as repo-relative paths, and only where the file really exists on
# disk (which is what sops walks). Untracked matters — the whole point is to
# catch the mistake before it is committed, and before anyone runs sops from
# inside the new directory.
list_files() { # $1 = repo, $2 = extended regex
  local repo="$1" re="$2" p
  if is_git_repo "$repo"; then
    { git -C "$repo" ls-files
      git -C "$repo" ls-files --others --exclude-standard
    } | grep -E "$re" | sort -u | while IFS= read -r p; do
      [ -f "$repo/$p" ] && printf '%s\n' "$p"
    done
  else
    (cd "$repo" && find . -type f 2>/dev/null \
      | sed 's|^\./||' | grep -v -E '(^|/)(\.git|node_modules)/' | grep -E "$re" | sort -u)
  fi
}

# Every .sops.yaml in the repo.
list_configs() { list_files "$1" '(^|/)\.sops\.ya?ml$'; }

# Encrypted files, by the house naming convention, that would need a config.
# .sops.yaml itself is the config, not an encrypted file — exclude it.
list_encrypted() { list_files "$1" '\.sops(\.ya?ml)?$' | grep -vE '(^|/)\.sops\.ya?ml$' || true; }

# Comma/space separated age recipients of creation rule $2, one per line.
rule_recipients() { # $1 = config, $2 = rule index
  local cfg="$1" i="$2" shorthand groups
  shorthand=$(yq eval ".creation_rules[$i].age // \"\"" "$cfg" 2>/dev/null) || return 1
  groups=$(yq eval "[.creation_rules[$i].key_groups[]?.age[]?] | join(\",\")" "$cfg" 2>/dev/null) || return 1
  printf '%s,%s\n' "$shorthand" "$groups" | tr ',\n' '\n\n' | sed 's/[[:space:]]//g' | grep -E '^age1' || true
}

check_rule() { # $1 = config, $2 = rule index
  local cfg="$1" i="$2" got e missing=0 present=0
  got=$(rule_recipients "$cfg" "$i") || { bad "$cfg: yq cannot read creation_rules[$i]"; return; }
  for e in "${EXPECTED_AGE[@]}"; do
    if printf '%s\n' "$got" | grep -qx "$e"; then
      present=$((present + 1))
    else
      missing=$((missing + 1))
    fi
  done
  if [ "$missing" -eq 0 ]; then
    ok "$cfg: creation_rules[$i] names both recipients"
  else
    bad "$cfg: creation_rules[$i] names $present of ${#EXPECTED_AGE[@]} expected recipients (got: $(printf '%s' "${got:-none}" | tr '\n' ' '))"
  fi
}

check_config() { # $1 = repo, $2 = config path
  local repo="$1" cfg="$2" n i
  if ! command -v yq >/dev/null 2>&1; then
    bad "yq is not installed — cannot read $cfg"
    return
  fi
  n=$(yq eval '.creation_rules // [] | length' "$cfg" 2>/dev/null) || {
    bad "$cfg: not parseable YAML"; return; }
  if [ "${n:-0}" -eq 0 ]; then
    bad "$cfg: has no creation_rules — sops would refuse every file in this repo"
    return
  fi
  for ((i = 0; i < n; i++)); do check_rule "$cfg" "$i"; done
}

check_repo() { # $1 = path
  local repo cfgs cfg rel encrypted root_cfg=""
  repo=$(resolve_repo "$1") || { bad "'$1' is not a directory"; return; }
  head1 "$repo"
  cfgs=$(list_configs "$repo")
  if [ -z "$cfgs" ]; then
    encrypted=$(list_encrypted "$repo")
    if [ -n "$encrypted" ]; then
      bad "encrypted files but no .sops.yaml at the root — nothing records the recipient (first: $(printf '%s' "$encrypted" | head -1))"
    else
      ok "no .sops.yaml and no encrypted files — nothing to check"
    fi
    return
  fi
  while IFS= read -r cfg; do
    [ -n "$cfg" ] || continue
    # A config that only exists in the index (deleted on disk) is not something
    # sops can find; report what is actually on disk, which is what sops walks.
    [ -f "$repo/$cfg" ] || continue
    if [ "$cfg" != ".sops.yaml" ] && [ "$cfg" != ".sops.yml" ]; then
      bad "$cfg: config outside the repo root — sops run from $(dirname "$cfg")/ would match it and drop every recipient it does not list"
    else
      root_cfg="$repo/$cfg"
    fi
  done <<< "$cfgs"
  if [ -n "$root_cfg" ]; then
    check_config "$repo" "$root_cfg"
  else
    bad "no .sops.yaml at the repo root (found: $(printf '%s' "$cfgs" | tr '\n' ' '))"
  fi
  note "encrypted files: $(list_encrypted "$repo" | wc -l | tr -d ' ')"
}

if [ "$#" -eq 0 ]; then
  top=$(git rev-parse --show-toplevel 2>/dev/null) || top=$(pwd -P)
  set -- "$top"
fi

for target in "$@"; do check_repo "$target"; done

printf '\n'
if [ "$fail" -eq 0 ]; then
  printf 'sops-config-check: PASS\n'
  exit 0
fi
printf 'sops-config-check: FAIL\n'
exit 1
