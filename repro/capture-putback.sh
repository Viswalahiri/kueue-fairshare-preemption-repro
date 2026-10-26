#!/usr/bin/env bash
# Re-run TestArticleAPutBack on Kueue v0.20.3 (commit 66ff2111) using the
# test file currently in this repo. Output is a unit test, not a kind cluster.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
OUT=${OUT:-$ROOT/cluster-logs/v0.20.3-rerun/unit}
W=${WORK:-/tmp/kueue-article-a}
REV=66ff21115867ef4a80ced2a662d3665d86cb0d78
export PATH="/usr/local/go1.27.3/bin:${PATH}"
export GOTOOLCHAIN=local
export KUEUE_VERSION=${KUEUE_VERSION:-v0.20.3}
export CAPTURE_SOURCE="unit test, not a live kind cluster"
# shellcheck source=capture-header.sh
source "$HERE/capture-header.sh"
mkdir -p "$OUT" "$W"
refresh_header_versions || true

if [ ! -d "$W/kueue/.git" ]; then
  git clone --filter=blob:none https://github.com/kubernetes-sigs/kueue.git "$W/kueue"
fi
want=$(git -C "$W/kueue" rev-parse "${REV}^{commit}")
if [ ! -d "$W/v0.20.3" ] || [ "$(git -C "$W/v0.20.3" rev-parse HEAD)" != "$want" ]; then
  git -C "$W/kueue" worktree remove --force "$W/v0.20.3" 2>/dev/null || rm -rf "$W/v0.20.3"
  git -C "$W/kueue" worktree add --detach "$W/v0.20.3" "$want"
fi
cp "$HERE/zz_article_a_putback_test.go" "$W/v0.20.3/pkg/scheduler/preemption/zz_article_a_putback_test.go"
# rev-parse before any unit header. write_header used to run while
# HEADER_KUEUE_COMMIT was still empty.
HEADER_KUEUE_COMMIT=$(git -C "$W/v0.20.3" rev-parse HEAD)
HEADER_KUEUE_COMMIT_SOURCE="git rev-parse HEAD of the worktree"
cd "$ROOT"
run_cap "$OUT/go-version.txt" -- go version
run_cap "$OUT/kueue-rev-parse.txt" -- git -C "$W/v0.20.3" rev-parse HEAD
run_cap "$OUT/kueue-log.txt" -- git -C "$W/v0.20.3" log -1 --format='%H%n%s%n%P'
run_cap "$OUT/putback-test-sha256.txt" -- sha256sum repro/zz_article_a_putback_test.go "$W/v0.20.3/pkg/scheduler/preemption/zz_article_a_putback_test.go"
go_ver=$(go version)
run_cap_sh "$OUT/TestArticleAPutBack.log" "cd $(printf '%q' "$W/v0.20.3") && go test -count=1 -timeout 180s -v ./pkg/scheduler/preemption/ -run TestArticleAPutBack" "go: ${go_ver}"
echo "putback log in $OUT/TestArticleAPutBack.log"
