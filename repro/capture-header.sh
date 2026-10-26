#!/usr/bin/env bash
# Header writer for live kind captures.
# Sourced by run-kind.sh and capture-rerun.sh. Not executed directly.
# Every capture file starts with these fields, then a body marker, then the
# command's own stdout/stderr. The body is not rewritten.

# Split point. Command output is everything after this line.
CAPTURE_BODY_MARK='===== capture body ====='

refresh_header_versions() {
  HEADER_KIND=$(kind version 2>&1 || true)
  HEADER_KUBECTL=$(kubectl version --client=true --output=yaml 2>/dev/null | awk '/gitVersion:/{print $2; exit}' || true)
  HEADER_NODE_IMAGE=$(docker inspect "${CLUSTER:-kueue-fs}-control-plane" --format '{{.Config.Image}}' 2>/dev/null || true)
  if [ -z "${HEADER_NODE_IMAGE}" ] || [ "${HEADER_NODE_IMAGE}" = "<no value>" ]; then
    HEADER_NODE_IMAGE=$(docker inspect "${CLUSTER:-kueue-fs}-control-plane" --format '{{.Config.Image}}' 2>/dev/null || true)
  fi
  local rev
  rev=$(docker inspect "registry.k8s.io/kueue/kueue:${KUEUE_VERSION:-v0.20.3}" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null || true)
  if [ -n "$rev" ] && [ "$rev" != "<no value>" ]; then
    HEADER_KUEUE_COMMIT=$rev
    HEADER_KUEUE_COMMIT_SOURCE=image-label
  fi
}

# Look up the release tag before any header is written. Does not write a
# capture file. write_header used to run first, so early files said
# kueue_commit: unknown.
lookup_kueue_commit() {
  if [ -n "${HEADER_KUEUE_COMMIT:-}" ]; then
    return 0
  fi
  if [ "${_IN_KUEUE_COMMIT_LOOKUP:-}" = 1 ]; then
    return 0
  fi
  _IN_KUEUE_COMMIT_LOOKUP=1
  local body rc line
  body=$(mktemp)
  set +e
  timeout 45 git ls-remote https://github.com/kubernetes-sigs/kueue.git "refs/tags/${KUEUE_VERSION}^{}" >"$body" 2>&1
  rc=$?
  set -e
  KUEUE_LS_REMOTE_BODY=$body
  KUEUE_LS_REMOTE_RC=$rc
  if [ "$rc" = "0" ]; then
    line=$(awk 'NF {print $1; exit}' "$body")
    if [ -n "$line" ]; then
      HEADER_KUEUE_COMMIT_LS_REMOTE=$line
      HEADER_KUEUE_COMMIT=$line
      HEADER_KUEUE_COMMIT_SOURCE=git-ls-remote
    fi
  fi
  _IN_KUEUE_COMMIT_LOOKUP=0
}

# Peel the release tag to a commit. The raw line is kept in a capture file.
# The commit variables are set before write_header, so this file's own header
# is not kueue_commit: unknown.
resolve_kueue_commit() {
  local dest=${OUT:-/tmp}/kueue-commit-ls-remote.txt
  local cmd="timeout 45 git ls-remote https://github.com/kubernetes-sigs/kueue.git refs/tags/${KUEUE_VERSION}^{}"
  lookup_kueue_commit
  local body rc
  body=${KUEUE_LS_REMOTE_BODY:-}
  rc=${KUEUE_LS_REMOTE_RC:-1}
  if [ -z "$body" ] || [ ! -f "$body" ]; then
    body=$(mktemp)
    set +e
    timeout 45 git ls-remote https://github.com/kubernetes-sigs/kueue.git "refs/tags/${KUEUE_VERSION}^{}" >"$body" 2>&1
    rc=$?
    set -e
  fi
  write_header "$dest" "$cmd" "exit_code: ${rc}" "source: live command, not a unit test"
  cat "$body" >>"$dest"
  rm -f "$body"
  unset KUEUE_LS_REMOTE_BODY KUEUE_LS_REMOTE_RC
}

write_header() {
  local dest=$1
  local cmd=$2
  shift 2
  if [ -z "${HEADER_KUEUE_COMMIT:-}" ]; then
    lookup_kueue_commit || true
  fi
  mkdir -p "$(dirname "$dest")"
  {
    if [ -n "${CAPTURE_FIRST_LINE:-}" ]; then
      echo "${CAPTURE_FIRST_LINE}"
    fi
    echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # kind, kubectl, and node_image are cluster tools. A unit-test capture
    # does not use them. Field order otherwise matches earlier captures.
    if [[ "${CAPTURE_SOURCE:-}" != *"unit test"* ]]; then
      echo "kind: ${HEADER_KIND:-unknown}"
      echo "kubectl: ${HEADER_KUBECTL:-unknown}"
    fi
    echo "kueue: ${KUEUE_VERSION:-unknown}"
    echo "kueue_commit: ${HEADER_KUEUE_COMMIT:-unknown}"
    echo "kueue_commit_source: ${HEADER_KUEUE_COMMIT_SOURCE:-unknown}"
    if [[ "${CAPTURE_SOURCE:-}" != *"unit test"* ]]; then
      echo "node_image: ${HEADER_NODE_IMAGE:-unknown}"
    fi
    echo "command: ${cmd}"
    echo "source: ${CAPTURE_SOURCE:-live kind cluster}"
    if [ "$#" -gt 0 ]; then
      printf '%s\n' "$@"
    fi
    echo "${CAPTURE_BODY_MARK}"
  } >"$dest"
}

# run_cap DEST -- cmd arg...
# Header records the shell-quoted command and its exit code. Body is the
# command's stdout and stderr, unmodified.
run_cap() {
  local dest=$1
  shift
  if [ "${1:-}" = "--" ]; then
    shift
  fi
  local q="" arg body rc
  for arg in "$@"; do
    q+=" $(printf '%q' "$arg")"
  done
  q=${q# }
  body=$(mktemp)
  local err
  err=$(mktemp)
  set +e
  "$@" >"$body" 2>"$err"
  rc=$?
  set -e
  write_header "$dest" "$q" "exit_code: ${rc}"
  cat "$body" >>"$dest"
  if [ -s "$err" ]; then
    write_header "$dest.stderr" "$q" "exit_code: ${rc}" "note: stderr only; stdout is in the paired file without the .stderr suffix"
    cat "$err" >>"$dest.stderr"
  fi
  rm -f "$body" "$err"
  return 0
}

# run_cap_sh DEST CMD [extra header lines...]
# CMD is a bash -o pipefail -c script. The header stores CMD as given.
run_cap_sh() {
  local dest=$1
  local cmd=$2
  shift 2
  local body rc
  body=$(mktemp)
  local err
  err=$(mktemp)
  set +e
  bash -o pipefail -c "$cmd" >"$body" 2>"$err"
  rc=$?
  set -e
  write_header "$dest" "$cmd" "exit_code: ${rc}" "$@"
  cat "$body" >>"$dest"
  if [ -s "$err" ]; then
    write_header "$dest.stderr" "$cmd" "exit_code: ${rc}" "note: stderr only; stdout is in the paired file without the .stderr suffix" "$@"
    cat "$err" >>"$dest.stderr"
  fi
  rm -f "$body" "$err"
  return 0
}

prepend_derived_header() {
  local dest=$1
  local cmd=$2
  shift 2
  local body
  body=$(mktemp)
  if [ -f "$dest" ]; then
    cat "$dest" >"$body"
  fi
  local script=repro/run-kind.sh
  case "$cmd" in
    *grace_timeline.py*) script=repro/grace_timeline.py ;;
    *capture-rerun.sh*) script=repro/capture-rerun.sh ;;
    *write-rerun-index*) script=repro/write-rerun-index.py ;;
  esac
  CAPTURE_FIRST_LINE="DERIVED (generated by ${script} from raw output)"
  write_header "$dest" "$cmd" "label: DERIVED" "exit_code: 0" "$@"
  unset CAPTURE_FIRST_LINE
  cat "$body" >>"$dest"
  rm -f "$body"
}
