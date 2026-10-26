#!/usr/bin/env bash
# Unit-level evidence for the fair-sharing preemption repro. No cluster.
# Needs git and Go >= 1.27 (Kueue v0.20.3's go.mod says 1.27.0; the 0.19
# tags say 1.26.0 and build with the same toolchain).
#
# Output goes to ../repro-logs/. Every log starts with a tag/commit header.
# Run from anywhere. The Kueue clone lives in ${WORK:-/tmp/kueue-article-a}
# and is not part of this repo.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LOGS=$HERE/../repro-logs
W=${WORK:-/tmp/kueue-article-a}
mkdir -p "$LOGS" "$W"
export GOFLAGS="${GOFLAGS:--p=2}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"

if [ ! -d "$W/kueue/.git" ]; then
  git clone --filter=blob:none https://github.com/kubernetes-sigs/kueue.git "$W/kueue"
fi

# wt <dirname> <rev> <label>
# Checks out <rev> detached. <label> is recorded in the log header (a tag
# name, or a short name for a PR commit that has no tag).
wt() {
  local name=$1 rev=$2 label=$3
  local want
  want=$(git -C "$W/kueue" rev-parse "${rev}^{commit}")
  if [ -d "$W/$name" ]; then
    local have
    have=$(git -C "$W/$name" rev-parse HEAD)
    if [ "$have" != "$want" ]; then
      git -C "$W/kueue" worktree remove --force "$W/$name" || rm -rf "$W/$name"
    fi
  fi
  if [ ! -d "$W/$name" ]; then
    git -C "$W/kueue" worktree add --detach "$W/$name" "$want"
  fi
  printf '%s\n' "$label" > "$W/$name/.repro-label"
  printf '%s\n' "$want" > "$W/$name/.repro-commit"
}

header() {
  local d=$1
  local label commit subject parents
  label=$(cat "$d/.repro-label")
  commit=$(git -C "$d" rev-parse HEAD)
  subject=$(git -C "$d" log -1 --format=%s)
  parents=$(git -C "$d" log -1 --format=%P)
  {
    echo "# label $label"
    echo "# commit $commit"
    echo "# subject $subject"
    echo "# parents $parents"
    echo "# go $(go env GOVERSION 2>/dev/null || go version | awk '{print $3}')"
    echo "# date $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  }
}

# run_logged <dirname> <logfile> <go test args...>
# Appends the test output to a log that already has a header. Records exit=.
# Does not abort the script: the cross-version CompareBool run is expected to fail.
run_logged() {
  local d=$1 out=$2
  shift 2
  local logfile=$LOGS/$out
  header "$W/$d" > "$logfile"
  set +e
  (cd "$W/$d" && go test -count=1 "$@") >> "$logfile" 2>&1
  local rc=$?
  set -e
  echo "exit=$rc" >> "$logfile"
  echo "wrote $out (exit=$rc)"
}

# run_filtered <dirname> <logfile> <grep-extended-regex> <go test args...>
run_filtered() {
  local d=$1 out=$2 pattern=$3
  shift 3
  local logfile=$LOGS/$out
  header "$W/$d" > "$logfile"
  set +e
  (cd "$W/$d" && go test -count=1 "$@") > "$logfile.raw" 2>&1
  local rc=$?
  set -e
  # Keep the summary. Always record the test process exit, even when grep matches nothing.
  grep -E "$pattern" "$logfile.raw" >> "$logfile" || true
  echo "exit=$rc" >> "$logfile"
  rm -f "$logfile.raw"
  echo "wrote $out (exit=$rc)"
}

echo "checking out Kueue tags and PR commits into $W"
wt v0.19.1 v0.19.1 v0.19.1
wt v0.19.2 v0.19.2 v0.19.2
wt v0.19.4 v0.19.4 v0.19.4
wt v0.20.3 v0.20.3 v0.20.3
wt pr14765  d7b9a364f6636f1a9d3ba2c949ebbcfba942f648 'pr14765-merge'
wt pr14765p 'd7b9a364f6636f1a9d3ba2c949ebbcfba942f648^' 'pr14765-parent'
wt pr15128  73ada9494a84e85bb60598852a5228f1c412cda0 'pr15128-merge'
wt pr15128p '73ada9494a84e85bb60598852a5228f1c412cda0^' 'pr15128-parent'

SUM='^(=== RUN   Test|--- |ok |FAIL)|^(    --- )|REPRO |SHARE |exit='
P='TestFairPreemptions|TestCandidatesOrdering|TestHierarchicalPreemptions|TestCompareBool|TestSortActivePods|TestSortInactivePods'

# #15128: CompareBool flip. Parent and merge should both pass, including the new pod-sort tests at the merge.
run_filtered pr15128p pr15128-parent.log "$SUM" -v ./pkg/util/cmp/ ./pkg/scheduler/preemption/ ./pkg/controller/jobs/pod/ -run "$P"
run_filtered pr15128  pr15128-merge.log  "$SUM" -v ./pkg/util/cmp/ ./pkg/scheduler/preemption/ ./pkg/controller/jobs/pod/ -run "$P"

# New pod-sort tests from #15128 copied onto the parent tree. Passing means the sort order was already that way.
cp "$W/pr15128/pkg/controller/jobs/pod/pod_controller_test.go" "$W/pr15128p/pkg/controller/jobs/pod/"
run_filtered pr15128p pr15128-newPodSortTests-on-parent-code.log "$SUM" -v ./pkg/controller/jobs/pod/ -run 'TestSortActivePods|TestSortInactivePods'
git -C "$W/pr15128p" checkout -- pkg/controller/jobs/pod/pod_controller_test.go

# #14765: ZeroWeightBorrows used by the +Inf early exit. Behavior-preserving.
P2='TestFairPreemptions|TestHierarchicalPreemptions|TestZeroWeightBorrows|TestDominantResourceShare'
run_filtered pr14765p pr14765-parent.log "$SUM" -v ./pkg/cache/scheduler/ ./pkg/scheduler/preemption/ -run "$P2"
run_filtered pr14765  pr14765-merge.log  "$SUM" -v ./pkg/cache/scheduler/ ./pkg/scheduler/preemption/ -run "$P2"

# v0.19.2's TestCompareBool expectations against v0.19.4's CompareBool.
# This is the one place the flip is visible: the old test fails on the new function.
cp "$W/v0.19.2/pkg/util/cmp/cmp_test.go" "$W/v0.19.4/pkg/util/cmp/cmp_test.go"
run_logged v0.19.4 cross-v0.19.2-cmp_test-on-v0.19.4-code.log -v ./pkg/util/cmp/ -run TestCompareBool
git -C "$W/v0.19.4" checkout -- pkg/util/cmp/cmp_test.go

# Release-tag upstream tests, so the before/after is not only the PR commits.
for v in v0.19.2 v0.19.4 v0.20.3; do
  run_filtered "$v" "$v-preemption.log" "$SUM" -v ./pkg/util/cmp/ ./pkg/scheduler/preemption/... ./pkg/controller/jobs/pod/ -run "$P"
  run_filtered "$v" "$v-cmp-drs.log" "$SUM" -v ./pkg/util/cmp/ ./pkg/cache/scheduler/ -run 'TestCompareBool|TestDominantResourceShare|TestZeroWeightBorrows'
done

# Article scenarios (Z, Zc, Z2, O, O2) through Preemptor.GetTargets / the
# v0.20 strategy iterator, and the share mapping, at each pin.
for v in v0.19.1 v0.19.2 v0.19.4 v0.20.3; do
  f=$W/$v/pkg/scheduler/preemption/zz_article_a_repro_test.go
  python3 "$HERE/mk_test.py" "$W/$v/pkg/scheduler/preemption/preemption_fair_test.go" "$HERE/article_a_cases.go.txt" "$f"
  # Drop imports the copied harness no longer references after the case swap.
  for i in 1 2 3 4 5 6 7; do
    m=$(cd "$W/$v" && go vet ./pkg/scheduler/preemption/ 2>&1 | grep -oP '"\K[^"]+(?=" imported (as \w+ )?and not used)' | head -1 || true)
    [ -z "$m" ] && break
    sed -i "\#^[[:space:]]*\\(\\w\\+ \\)\\?\"$m\"\$#d" "$f"
  done
  run_filtered "$v" "$v-article-a-scenarios.log" 'REPRO |^ok |^FAIL' -v ./pkg/scheduler/preemption/ -run TestArticleARepro
  # TEST_LOG_LEVEL is read by Kueue's test logger. -5 prints V(4) lines.
  header "$W/$v" > "$LOGS/$v-skip-log-lines-Z.log"
  set +e
  (cd "$W/$v" && TEST_LOG_LEVEL=-5 go test -count=1 -v ./pkg/scheduler/preemption/ -run 'TestArticleARepro/Z:') > "$LOGS/$v-skip-log-lines-Z.log.raw" 2>&1
  rc=$?
  set -e
  grep -E 'Skipping FairSharing|Evaluating FairSharing|^ok |^FAIL' "$LOGS/$v-skip-log-lines-Z.log.raw" >> "$LOGS/$v-skip-log-lines-Z.log" || true
  echo "exit=$rc" >> "$LOGS/$v-skip-log-lines-Z.log"
  rm -f "$LOGS/$v-skip-log-lines-Z.log.raw"
  echo "wrote $v-skip-log-lines-Z.log (exit=$rc)"

  if [ "$v" = "v0.20.3" ]; then
    cp "$HERE/zz_article_a_shares_test.go.v0.20.3" "$W/$v/pkg/cache/scheduler/zz_article_a_shares_test.go"
  else
    cp "$HERE/zz_article_a_shares_test.go" "$W/$v/pkg/cache/scheduler/zz_article_a_shares_test.go"
  fi
  run_filtered "$v" "$v-article-a-shares.log" 'SHARE |^ok |^FAIL' -v ./pkg/cache/scheduler/ -run TestArticleAShares

  if [ "$v" = "v0.20.3" ]; then
    cp "$HERE/zz_article_a_putback_test.go" "$W/$v/pkg/scheduler/preemption/zz_article_a_putback_test.go"
    run_logged "$v" "$v-putback-8-then-1.log" -count=1 -timeout 180s -v ./pkg/scheduler/preemption/ -run 'TestArticleAPutBack'
  fi
done

# One combined view of the Z log lines, in version order. Same bytes as the per-version files.
{
  for v in v0.19.1 v0.19.2 v0.19.4 v0.20.3; do
    echo "===== $v ====="
    cat "$LOGS/$v-skip-log-lines-Z.log"
    echo
  done
} > "$LOGS/skip-log-lines-Z.log"

echo "logs in $LOGS"
# Non-zero if any log other than the expected CompareBool cross-test failed.
fail=0
while IFS= read -r line; do
  file=${line%%:*}
  base=$(basename "$file")
  rc=${line##*exit=}
  if [ "$rc" != "0" ] && [ "$base" != "cross-v0.19.2-cmp_test-on-v0.19.4-code.log" ]; then
    echo "FAILED $base exit=$rc"
    fail=1
  fi
done < <(grep -H '^exit=' "$LOGS"/*.log || true)
if [ "$fail" != "0" ]; then
  exit 1
fi
echo "unit repro finished"
