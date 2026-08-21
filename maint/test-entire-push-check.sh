#!/usr/bin/env bash
# Tests for entire-push-check's probe and dedupe.
#
# Builds REAL git repos with REAL linked worktrees, because the bug being
# guarded is worktree-specific: linked worktrees share one object store, so the
# same unpushed ref is visible from every one of them. A fixture of canned probe
# output would have happily passed while the real check reported 15 findings for
# 3 refs (iv-foundry-stage2, 2026-08-21).
#
# The check itself is not runnable here -- it calls job_require_mini and pings
# healthchecks.io -- so the two testable units are lifted out of it by sed, the
# same way iv-provision's test-provision.sh exercises keeps_quarto. That keeps
# the test honest about WHICH code it ran: if the probe or record() is renamed
# or restructured, extraction fails loudly rather than passing vacuously.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/.local/bin/entire-push-check"
[[ -f "$SCRIPT" ]] || { echo "cannot find entire-push-check at $SCRIPT" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fails=0
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }
ok()   { echo "  ok: $1"; }

# --- extract the probe -------------------------------------------------------
sed -n "/^read -r -d '' PROBE <<'EOS'$/,/^EOS$/p" "$SCRIPT" \
  | sed '1d;$d' > "$TMP/probe.sh"
[[ -s "$TMP/probe.sh" ]] || { echo "could not extract PROBE from $SCRIPT" >&2; exit 1; }
grep -q 'git-common-dir' "$TMP/probe.sh" || {
  echo "PROBE no longer reports the shared object store; dedupe cannot work" >&2; exit 1; }

# --- extract index_of + record ------------------------------------------------
{
  sed -n '/^index_of() {/,/^}/p' "$SCRIPT"
  sed -n '/^record() {/,/^}/p'   "$SCRIPT"
} > "$TMP/record.sh"
grep -q '^record() {'   "$TMP/record.sh" || { echo "could not extract record()" >&2; exit 1; }
grep -q '^index_of() {' "$TMP/record.sh" || { echo "could not extract index_of()" >&2; exit 1; }
# in_list is a dependency of record(); take the real one rather than a stub, so
# a change to exclusion matching is exercised here too.
sed -n '/^in_list() {/p' "$SCRIPT" >> "$TMP/record.sh"
grep -q '^in_list() {' "$TMP/record.sh" || { echo "could not extract in_list()" >&2; exit 1; }

# --- fixture ------------------------------------------------------------------
# origin: a bare remote. repo `shared` has a main worktree + 3 linked worktrees,
# all sharing one object store and one unpushed checkpoint ref. repo `solo` has
# a main worktree only, also unpushed. repo `clean` is fully pushed and must not
# be reported at all.
export HOME="$TMP/home"
mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
git config --global user.email t@example.com
git config --global user.name  test
git config --global init.defaultBranch main
git config --global protocol.file.allow always

mk_repo() {  # mk_repo <name>
  local n=$1
  git init -q --bare "$TMP/origin-$n.git"
  git init -q "$HOME/$n"
  git -C "$HOME/$n" remote add origin "$TMP/origin-$n.git"
  echo hello > "$HOME/$n/f"
  git -C "$HOME/$n" add f
  git -C "$HOME/$n" commit -qm init
  git -C "$HOME/$n" push -q origin main
}
# An unpushed Entire-style checkpoint ref: a commit on refs/heads/entire/** that
# exists on no remote. That is exactly what the check looks for.
add_unpushed_ref() {  # add_unpushed_ref <repo> <ref>
  local n=$1 ref=$2
  git -C "$HOME/$n" branch -q "$ref" main
  git -C "$HOME/$n" commit -q --allow-empty -m "Checkpoint: deadbeef" \
    --no-verify >/dev/null 2>&1
  local sha; sha=$(git -C "$HOME/$n" rev-parse HEAD)
  git -C "$HOME/$n" update-ref "refs/heads/$ref" "$sha"
  git -C "$HOME/$n" reset -q --hard HEAD~1
}

mk_repo shared
add_unpushed_ref shared entire/checkpoints/v1
for w in wt-a wt-b wt-c; do
  git -C "$HOME/shared" worktree add -q -b "branch-$w" "$HOME/$w" main
done

mk_repo solo
add_unpushed_ref solo entire/checkpoints/v1

mk_repo clean
git -C "$HOME/clean" branch -q entire/checkpoints/v1 main
git -C "$HOME/clean" push -q origin entire/checkpoints/v1

# --- run the probe ------------------------------------------------------------
out=$(bash -c "$(cat "$TMP/probe.sh")" 2>/dev/null)

# The probe is deliberately NOT deduped: it reports per worktree, and dedupe is
# record()'s job. Assert the raw shape first so a regression in either layer is
# attributable to that layer.
raw_shared=$(awk -F'|' '$1=="shared" || $1 ~ /^wt-/' <<<"$out" | wc -l | tr -d ' ')
[[ "$raw_shared" == "4" ]] \
  && ok "probe sees the shared ref from all 4 worktrees (pre-dedupe)" \
  || fail "expected 4 raw findings for the shared repo, got $raw_shared"

awk -F'|' 'NF!=4 {exit 1}' <<<"$out" \
  && ok "probe emits repo|common-dir|ref|n" \
  || fail "probe output is not 4 pipe-separated fields: $out"

grep -q '^clean|' <<<"$out" \
  && fail "a fully pushed checkpoint ref was reported" \
  || ok "a pushed ref is not reported"

# All four shared worktrees must resolve to ONE common dir -- the grouping key.
n_common=$(awk -F'|' '$1=="shared" || $1 ~ /^wt-/ {print $2}' <<<"$out" | sort -u | wc -l | tr -d ' ')
[[ "$n_common" == "1" ]] \
  && ok "all 4 shared worktrees resolve to one object store" \
  || fail "shared worktrees resolved to $n_common object stores, expected 1"

# --- run record() -------------------------------------------------------------
result=$(
  set -uo pipefail
  DRY_RUN=0
  EXCLUDED=()
  findings=() excused_n=0 SEEN=() SEEN_EXTRA=() dup_n=0
  # shellcheck disable=SC1090
  . "$TMP/record.sh"
  record testhost "$out"
  printf 'findings=%s\n' "${#findings[@]}"
  printf 'dup=%s\n' "$dup_n"
  for f in ${findings[@]+"${findings[@]}"}; do printf 'F=%s\n' "$f"; done
  i=0
  for f in ${findings[@]+"${findings[@]}"}; do
    printf 'EXTRA=%s:%s\n' "$f" "${SEEN_EXTRA[$i]}"; i=$((i+1))
  done
)

got_findings=$(sed -n 's/^findings=//p' <<<"$result")
got_dup=$(sed -n 's/^dup=//p' <<<"$result")

# THE regression: 2 real refs, not 5 worktree-shaped copies of them.
[[ "$got_findings" == "2" ]] \
  && ok "5 worktree findings collapse to 2 distinct refs" \
  || { fail "expected 2 deduped findings, got $got_findings"; sed -n 's/^F=/  had: /p' <<<"$result" >&2; }

[[ "$got_dup" == "3" ]] \
  && ok "3 duplicate worktree findings counted and collapsed" \
  || fail "expected dup_n=3, got $got_dup"

grep -q '^EXTRA=testhost:.*|entire/checkpoints/v1|1:3$' <<<"$result" \
  && ok "the shared finding records its 3 extra worktrees" \
  || { fail "shared finding did not record 3 extra worktrees"; sed -n 's/^EXTRA=/  had: /p' <<<"$result" >&2; }

grep -q '^F=testhost:solo|entire/checkpoints/v1|1$' <<<"$result" \
  && ok "the standalone repo is still reported" \
  || fail "the standalone repo's unpushed ref was lost"

# --- exclusions still apply per worktree path, before dedupe ------------------
# An exclusion names a worktree, not an object store. Excusing the MAIN worktree
# of a shared repo must NOT excuse its linked worktrees -- the record still
# exists and still needs pushing; it should surface under a surviving worktree.
result2=$(
  set -uo pipefail
  DRY_RUN=0
  EXCLUDED=("testhost:shared")
  findings=() excused_n=0 SEEN=() SEEN_EXTRA=() dup_n=0
  # shellcheck disable=SC1090
  . "$TMP/record.sh"
  record testhost "$out"
  printf 'findings=%s\n' "${#findings[@]}"
  printf 'excused=%s\n' "$excused_n"
  for f in ${findings[@]+"${findings[@]}"}; do printf 'F=%s\n' "$f"; done
)
[[ "$(sed -n 's/^excused=//p' <<<"$result2")" == "1" ]] \
  && ok "excluding one worktree excuses exactly that worktree" \
  || fail "expected 1 excused, got $(sed -n 's/^excused=//p' <<<"$result2")"
[[ "$(sed -n 's/^findings=//p' <<<"$result2")" == "2" ]] \
  && ok "excusing the main worktree does not hide the shared ref" \
  || { fail "expected the shared ref to survive via a linked worktree"
       sed -n 's/^F=/  had: /p' <<<"$result2" >&2; }

# Excluding every worktree of a shared repo does silence it -- that is the
# operator explicitly excusing all of them, which the exclude file's own
# documentation treats as a deliberate act.
result3=$(
  set -uo pipefail
  DRY_RUN=0
  EXCLUDED=("testhost:shared" "testhost:wt-a" "testhost:wt-b" "testhost:wt-c")
  findings=() excused_n=0 SEEN=() SEEN_EXTRA=() dup_n=0
  # shellcheck disable=SC1090
  . "$TMP/record.sh"
  record testhost "$out"
  printf 'findings=%s\n' "${#findings[@]}"
)
[[ "$(sed -n 's/^findings=//p' <<<"$result3")" == "1" ]] \
  && ok "excusing every worktree of a repo silences it (solo remains)" \
  || fail "expected only the solo finding, got $(sed -n 's/^findings=//p' <<<"$result3")"

echo ""
if [[ $fails -gt 0 ]]; then
  echo "entire-push-check: $fails test(s) failed"
  exit 1
fi
echo "entire-push-check tests passed"
