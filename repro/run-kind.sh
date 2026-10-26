#!/usr/bin/env bash
# Live-cluster run of the fair-sharing scenarios on kind + Kueue v0.20.3.
# Captures ClusterQueue status, weighted-share metrics, and which workloads
# are preempted. A short-lived ServiceAccount token is used to read metrics
# and is never written to disk.
#
# Usage, from this directory:
#   ./run-kind.sh
# Requires: kind, kubectl, docker, curl, python3. The node needs about 2 free CPUs.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/../cluster-logs/v0.20.3}
KUEUE_VERSION=${KUEUE_VERSION:-v0.20.3}
CLUSTER=${CLUSTER:-kueue-fs}
CTX=kind-$CLUSTER
mkdir -p "$OUT"
# shellcheck source=capture-header.sh
source "$HERE/capture-header.sh"

if ! docker info >/dev/null 2>&1; then
  echo "docker is not reachable. Start the daemon and give this user access to the socket." >&2
  exit 1
fi
for bin in kind kubectl curl python3; do
  command -v "$bin" >/dev/null || { echo "missing $bin" >&2; exit 1; }
done

# Retries cover the validating webhook. A fresh controller accepts connections
# a few seconds after the pod is Ready, and a kube-proxy that has not programmed
# ClusterIP yet fails the same way.
kubectl_apply() {
  local i
  for i in 1 2 3 4 5 6 7 8; do
    if kubectl apply "$@"; then
      return 0
    fi
    echo "kubectl apply failed (attempt $i): $*" >&2
    sleep 5
  done
  echo "kubectl apply failed: $*" >&2
  return 1
}

# iptables mode needs the xt_statistic match. On the machine used for these
# captures, ClusterIP was not programmed while kube-proxy was on iptables,
# likely because the kernel lacks xt_statistic. That was not confirmed.
# nftables does program ClusterIP here. A cluster created from kind-config.yaml
# is already on nftables; this repairs a cluster that was created earlier.
ensure_kube_proxy_nftables() {
  local mode
  mode=$(kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | awk '/^[[:space:]]*mode:/{print $2; exit}')
  echo "kube-proxy mode: ${mode:-unknown}"
  if [ "$mode" = "nftables" ]; then
    return 0
  fi
  echo "switching kube-proxy from ${mode:-unknown} to nftables"
  kubectl -n kube-system get cm kube-proxy -o yaml > /tmp/kube-proxy-cm.yaml
  python3 - <<'PY'
from pathlib import Path
p = Path("/tmp/kube-proxy-cm.yaml")
text = p.read_text()
old = "mode: iptables"
if old not in text:
    raise SystemExit("kube-proxy config has no mode: iptables line")
p.write_text(text.replace(old, "mode: nftables", 1))
PY
  kubectl apply -f /tmp/kube-proxy-cm.yaml
  rm -f /tmp/kube-proxy-cm.yaml
  kubectl -n kube-system delete pod -l k8s-app=kube-proxy --wait=true
  kubectl -n kube-system rollout status ds/kube-proxy --timeout=120s
}

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "reusing kind cluster $CLUSTER (delete it first for a cold start)"
else
  # Same file as README: repro/kind-config.yaml, invoked from the repo root.
  ( cd "$HERE/.." && kind create cluster --config repro/kind-config.yaml )
fi
kubectl config use-context "$CTX" >/dev/null
ensure_kube_proxy_nftables
refresh_header_versions
resolve_kueue_commit

# The kind node often cannot reach registry.k8s.io even when the host can
# (SNAT from the docker bridge is dropped). Pull on the host and import the
# tarball into the node's containerd. The bytes are the published release image.
preload_into_node() {
  local img=$1
  local node="${CLUSTER}-control-plane"
  local tar
  tar=$(mktemp /tmp/kind-preload.XXXXXX.tar)
  echo "preloading $img into $node"
  docker pull "$img" >/dev/null
  docker save "$img" -o "$tar"
  docker cp "$tar" "$node:/kind-preload.tar"
  docker exec "$node" ctr --namespace=k8s.io images import /kind-preload.tar
  docker exec "$node" rm -f /kind-preload.tar
  rm -f "$tar"
}
if [ "${1:-}" != "--checks-only" ]; then
preload_into_node "registry.k8s.io/kueue/kueue:${KUEUE_VERSION}"
preload_into_node "registry.k8s.io/pause:3.10"
# Shell image for the SIGTERM-ignoring grace measurement. pause exits on SIGTERM.
preload_into_node "registry.k8s.io/e2e-test-images/busybox:1.36.1-1"

refresh_header_versions
resolve_kueue_commit
run_cap "$OUT/node-image.txt" -- docker inspect "${CLUSTER}-control-plane" --format '{{.Config.Image}}'
run_cap "$OUT/kueue-image-labels.txt" -- docker inspect "registry.k8s.io/kueue/kueue:${KUEUE_VERSION}" --format '{{json .RepoDigests}} {{json .Config.Labels}}'
refresh_header_versions
ver_body=$(mktemp)
{
  echo "date $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "kueue $KUEUE_VERSION"
  echo "kind $(kind version)"
  echo "kubectl $(kubectl version --client=true --output=yaml | awk '/gitVersion:/{print $2; exit}')"
  docker version --format 'docker {{.Server.Version}}'
  echo "node-image ${HEADER_NODE_IMAGE}"
  echo "kueue-commit ${HEADER_KUEUE_COMMIT:-unknown}"
  echo "kueue-commit-source ${HEADER_KUEUE_COMMIT_SOURCE:-unknown}"
  if [ -n "${HEADER_KUEUE_COMMIT_LS_REMOTE:-}" ]; then
    echo "kueue-commit-ls-remote ${HEADER_KUEUE_COMMIT_LS_REMOTE}"
  fi
  echo "image-source host docker pull, imported into the kind node with ctr"
} | tee "$ver_body"
CAPTURE_FIRST_LINE='DERIVED (generated by repro/run-kind.sh from raw output)'
write_header "$OUT/versions.txt" "assembled by repro/run-kind.sh from kind version, kubectl version --client, docker version, docker inspect of the kind node image, and git ls-remote or the image revision label" "label: DERIVED"
unset CAPTURE_FIRST_LINE
cat "$ver_body" >> "$OUT/versions.txt"
rm -f "$ver_body"

echo "installing Kueue $KUEUE_VERSION"
kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/kueue/releases/download/${KUEUE_VERSION}/manifests.yaml"
# The release manifest sets imagePullPolicy=Always, which makes kubelet dial
# the registry even when the image is already on the node. IfNotPresent uses
# the imported image. args[1] is --zap-log-level=2; V(4) prints the skip line.
kubectl -n kueue-system create configmap kueue-manager-config \
  --from-file=controller_manager_config.yaml="$HERE/kueue-config-fairsharing.yaml" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n kueue-system patch deploy kueue-controller-manager --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"},{"op":"replace","path":"/spec/template/spec/containers/0/args/1","value":"--zap-log-level=4"}]'
kubectl -n kueue-system rollout status deploy/kueue-controller-manager --timeout=6m
run_cap "$OUT/kueue-deploy.txt" -- kubectl -n kueue-system get deploy kueue-controller-manager -o jsonpath='image={.spec.template.spec.containers[0].image}{"\n"}args={.spec.template.spec.containers[0].args}{"\n"}'

kubectl_apply -f "$HERE/01-queues.yaml"
kubectl wait --for=condition=Active clusterqueue/team-a --timeout=180s
kubectl wait --for=condition=Active clusterqueue/team-b --timeout=180s
run_cap "$OUT/nodes.txt" -- kubectl get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory
else
  echo "checks-only: reusing the cluster, the controller, and the scenario captures already in $OUT"
fi

# Metrics reader. The token is minted per scrape and not stored.
kubectl -n kueue-system create sa metrics-probe --dry-run=client -o yaml | kubectl apply -f -
kubectl create clusterrolebinding metrics-probe \
  --clusterrole=kueue-metrics-reader \
  --serviceaccount=kueue-system:metrics-probe \
  --dry-run=client -o yaml | kubectl apply -f -
write_header "$OUT/port-forward.log" "kubectl -n kueue-system port-forward svc/kueue-controller-manager-metrics-service 18443:8443"
kubectl -n kueue-system port-forward svc/kueue-controller-manager-metrics-service 18443:8443 \
  >> "$OUT/port-forward.log" 2>&1 &
PF=$!
cleanup() { kill "$PF" >/dev/null 2>&1 || true; }
trap cleanup EXIT
for _ in $(seq 1 30); do
  if curl -sk --max-time 2 https://127.0.0.1:18443/metrics >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

scrape_metrics() {
  local dest=$1 token i body
  body=$(mktemp)
  : > "$body"
  for i in 1 2 3 4 5 6 7 8; do
    token=$(kubectl -n kueue-system create token metrics-probe --duration=20m)
    if curl -sk --max-time 20 -H "Authorization: Bearer ${token}" https://127.0.0.1:18443/metrics \
        | grep -E 'kueue_(cluster_queue|cohort)_weighted_share' > "$body"; then
      unset token
      if [ -s "$body" ]; then
        write_header "$dest" "curl -sk --max-time 20 -H \"Authorization: Bearer \${token}\" https://127.0.0.1:18443/metrics | grep -E 'kueue_(cluster_queue|cohort)_weighted_share'" "note: token minted by kubectl -n kueue-system create token metrics-probe --duration=20m; the token value is not written to this file" "exit_code: 0"
        cat "$body" >> "$dest"
        rm -f "$body"
        return 0
      fi
    fi
    unset token
    sleep 2
  done
  write_header "$dest" "curl -sk --max-time 20 -H \"Authorization: Bearer \${token}\" https://127.0.0.1:18443/metrics | grep -E 'kueue_(cluster_queue|cohort)_weighted_share'" "note: token minted by kubectl -n kueue-system create token metrics-probe --duration=20m; the token value is not written to this file" "exit_code: 1"
  echo "(no weighted_share series)" >> "$dest"
  rm -f "$body"
}

# Full /metrics response. The token is not stored.
capture_metrics_curl() {
  local dest=$1 token body rc
  body=$(mktemp)
  token=$(kubectl -n kueue-system create token metrics-probe --duration=20m)
  set +e
  curl -sk --max-time 20 -H "Authorization: Bearer ${token}" https://127.0.0.1:18443/metrics >"$body" 2>&1
  rc=$?
  set -e
  unset token
  write_header "$dest" "curl -sk --max-time 20 -H \"Authorization: Bearer \${token}\" https://127.0.0.1:18443/metrics" "note: token minted by kubectl -n kueue-system create token metrics-probe --duration=20m; the token value is not written to this file" "exit_code: ${rc}"
  cat "$body" >> "$dest"
  rm -f "$body"
}

reset_work() {
  if ! kubectl get ns team-a >/dev/null 2>&1; then
    return 0
  fi
  kubectl delete jobs --all -n team-a --wait=true --timeout=90s --ignore-not-found
  kubectl delete jobs --all -n team-b --wait=true --timeout=90s --ignore-not-found
  kubectl delete events --all -n team-a --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete events --all -n team-b --ignore-not-found >/dev/null 2>&1 || true
  # Workloads are owned by the Jobs. If a finalizer holds one, drop it.
  local ns w
  for ns in team-a team-b; do
    for w in $(kubectl -n "$ns" get workloads -o name 2>/dev/null || true); do
      kubectl -n "$ns" delete "$w" --wait=false --ignore-not-found || true
      kubectl -n "$ns" patch "$w" --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true
    done
  done
  local i
  for i in $(seq 1 60); do
    local n
    n=$(kubectl get workloads -A --no-headers 2>/dev/null | wc -l)
    [ "$n" = "0" ] && return 0
    sleep 1
  done
  echo "workloads still present after reset" >&2
  kubectl get workloads -A >&2 || true
  return 1
}

# submit <ns> <job> [cpu] [priority-class]
# Prints the workload name. Does not wait for admission.
submit() {
  local ns=$1 name=$2 cpu=${3:-500m} pc=${4:-}
  "$HERE/job.sh" "$ns" "$name" "$cpu" ${pc:+"$pc"} | kubectl apply -f - >/dev/null
  local uid wl="" i
  uid=$(kubectl -n "$ns" get job "$name" -o jsonpath='{.metadata.uid}')
  for i in $(seq 1 60); do
    wl=$(kubectl get workloads -A -l "kueue.x-k8s.io/job-uid=${uid}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [ -n "$wl" ] && break
    sleep 1
  done
  if [ -z "$wl" ]; then
    echo "no workload for $ns/$name" >&2
    return 1
  fi
  echo "$wl"
}

quota_status() {
  local ns=$1 wl=$2
  kubectl -n "$ns" get workload "$wl" -o jsonpath='{.status.conditions[?(@.type=="QuotaReserved")].status}' 2>/dev/null || true
}

# Wait until QuotaReserved=True, then pause so the next admission falls in a later second.
# ClusterQueue condition times are RFC3339 (one-second resolution); CandidatesOrdering
# uses that timestamp, and an equal timestamp falls through to UID.
admit() {
  local ns=$1 name=$2 cpu=${3:-500m} pc=${4:-}
  local wl i st
  wl=$(submit "$ns" "$name" "$cpu" ${pc:+"$pc"})
  for i in $(seq 1 90); do
    st=$(quota_status "$ns" "$wl")
    if [ "$st" = "True" ]; then
      echo "admitted $ns/$name workload=$wl"
      sleep 3
      return 0
    fi
    sleep 1
  done
  echo "NOT admitted $ns/$name workload=$wl status=$(quota_status "$ns" "$wl")" >&2
  kubectl -n "$ns" get workload "$wl" -o yaml >&2 || true
  return 1
}

capture() {
  local dir=$1
  mkdir -p "$dir"
  run_cap "$dir/clusterqueues.txt" -- kubectl get clusterqueue team-a team-b -o custom-columns='NAME:.metadata.name,WEIGHT:.spec.fairSharing.weight,SHARE:.status.fairSharing.weightedShare,ADMITTED:.status.admittedWorkloads,PENDING:.status.pendingWorkloads'
  run_cap_sh "$dir/cohort.txt" "kubectl get cohort all -o jsonpath='cohort all weightedShare={.status.fairSharing.weightedShare}{\"\\n\"}' || true"
  run_cap "$dir/workloads.txt" -- kubectl get workloads -A -o custom-columns='NS:.metadata.namespace,WL:.metadata.name,JOB:.metadata.ownerReferences[0].name,RESERVED:.status.conditions[?(@.type=="QuotaReserved")].status,RESERVED_AT:.status.conditions[?(@.type=="QuotaReserved")].lastTransitionTime,EVICTED:.status.conditions[?(@.type=="Evicted")].reason,PREEMPTED:.status.conditions[?(@.type=="Preempted")].reason,REQUEUED:.status.conditions[?(@.type=="Requeued")].status'
  run_cap_sh "$dir/events-preempted.txt" "kubectl get events -A --field-selector reason=Preempted --sort-by=.lastTimestamp || true"
  scrape_metrics "$dir/metrics.txt"
  run_cap "$dir/workloads-raw.json" -- kubectl get workloads -A -o json
  run_cap "$dir/clusterqueues.json" -- kubectl get clusterqueue team-a team-b -o json
  run_cap_sh "$dir/events-preempted.json" "kubectl get events -A --field-selector reason=Preempted -o json || echo '{\"items\":[]}'"
  python3 - "$dir" "$HERE" <<'PY'
import json, pathlib, sys
sys.path.insert(0, sys.argv[2])
from capture_json import load_capture_json
d = pathlib.Path(sys.argv[1])
raw = load_capture_json(d / "workloads-raw.json")
for item in raw.get("items", []):
    item.get("metadata", {}).pop("managedFields", None)
    item.pop("spec", None)
(d / "workloads.json").write_text(json.dumps(raw, indent=2) + "\n")

def conds(item):
    out = []
    for c in item.get("status", {}).get("conditions", []):
        if c.get("type") in ("QuotaReserved", "Admitted", "Evicted", "Preempted", "Requeued"):
            out.append(c)
    return out

lines = []
for item in raw.get("items", []):
    meta = item["metadata"]
    job = ""
    for o in meta.get("ownerReferences") or []:
        job = o.get("name", "")
        break
    rs = item.get("status", {}).get("requeueState")
    lines.append(f"workload {meta.get('namespace')}/{meta.get('name')} job={job}")
    lines.append("requeueState: " + (json.dumps(rs, sort_keys=True) if rs else "<absent>"))
    for c in conds(item):
        lines.append("condition: " + json.dumps(c, sort_keys=True))
    lines.append("")
(d / "conditions.txt").write_text("\n".join(lines))

ev = load_capture_json(d / "events-preempted.json")
el = []
for e in ev.get("items", []):
    el.append("event: " + json.dumps({
        "namespace": e.get("metadata", {}).get("namespace") or e.get("involvedObject", {}).get("namespace"),
        "involvedObject": e.get("involvedObject", {}).get("name"),
        "involvedKind": e.get("involvedObject", {}).get("kind"),
        "reason": e.get("reason"),
        "count": e.get("count"),
        "eventTime": e.get("eventTime"),
        "firstTimestamp": e.get("firstTimestamp"),
        "lastTimestamp": e.get("lastTimestamp"),
        "creationTimestamp": e.get("metadata", {}).get("creationTimestamp"),
        "message": e.get("message"),
    }, sort_keys=True))
(d / "events-preempted-lines.txt").write_text(("\n".join(el) + "\n") if el else "(no Preempted events)\n")

cq = load_capture_json(d / "clusterqueues.json")
fs_lines = []
for item in cq.get("items", []):
    name = item["metadata"]["name"]
    fs = item.get("status", {}).get("fairSharing")
    fs_lines.append(f"{name} status.fairSharing={json.dumps(fs, sort_keys=True)}")
(d / "fairsharing-status.txt").write_text("\n".join(fs_lines) + "\n")
PY
  prepend_derived_header "$dir/workloads.json" "python3 in repro/run-kind.sh capture(): strip managedFields and spec from workloads-raw.json"
  prepend_derived_header "$dir/conditions.txt" "python3 in repro/run-kind.sh capture(): QuotaReserved/Admitted/Evicted/Preempted/Requeued conditions from workloads-raw.json"
  prepend_derived_header "$dir/events-preempted-lines.txt" "python3 in repro/run-kind.sh capture(): selected fields from events-preempted.json"
  prepend_derived_header "$dir/fairsharing-status.txt" "python3 in repro/run-kind.sh capture(): status.fairSharing from clusterqueues.json"
}

controller_excerpt() {
  local dir=$1 since=$2
  mkdir -p "$dir"
  run_cap_sh "$dir/controller-fairsharing.log" "kubectl -n kueue-system logs deploy/kueue-controller-manager --since-time=${since} | grep -E 'Skipping FairSharing|Evaluating FairSharing' | head -c 200000 || true"
}

# namespace and name of the Workload owned by a batch Job.
workload_ref_for_job() {
  local ns=$1 job=$2 uid
  uid=$(kubectl -n "$ns" get job "$job" -o jsonpath='{.metadata.uid}')
  kubectl get workloads -A -l "kueue.x-k8s.io/job-uid=${uid}" -o jsonpath='{.items[0].metadata.namespace}{" "}{.items[0].metadata.name}{"\n"}'
}

capture_job_workload_yaml() {
  local dir=$1 ns=$2 job=$3 tag=$4
  local ref wl_ns wl
  ref=$(workload_ref_for_job "$ns" "$job")
  wl_ns=${ref%% *}
  wl=${ref##* }
  if [ -z "${wl:-}" ] || [ -z "${wl_ns:-}" ] || [ "$wl_ns" = "$ref" ]; then
    CAPTURE_FIRST_LINE='DERIVED (generated by repro/run-kind.sh from raw output)'
    write_header "$dir/workload-${tag}-${job}.yaml" "kubectl get workload for ${ns}/${job}" "note: workload name was not found" "exit_code: 1"
    unset CAPTURE_FIRST_LINE
    echo "(no workload for ${ns}/${job})" >> "$dir/workload-${tag}-${job}.yaml"
    return 0
  fi
  run_cap "$dir/workload-${tag}-${wl}.yaml" -- kubectl -n "$wl_ns" get workload "$wl" -o yaml
  printf '%s %s\n' "$wl_ns" "$wl"
}

# Workload YAML, full event list, and controller lines that name each preempted workload.
capture_post_preemption() {
  local dir=$1 since=$2
  run_cap "$dir/workloads-after.txt" -- kubectl get workloads -A -o wide
  run_cap "$dir/events.txt" -- kubectl get events -A --sort-by=.lastTimestamp
  run_cap "$dir/clusterqueue-team-a.yaml" -- kubectl get clusterqueue team-a -o yaml
  capture_metrics_curl "$dir/metrics-curl.txt"
  run_cap "$dir/workloads-all.json" -- kubectl get workloads -A -o json
  local list ns name
  list=$(python3 - "$dir/workloads-all.json" "$HERE" <<'PY'
import sys
sys.path.insert(0, sys.argv[2])
from capture_json import load_capture_json
d = load_capture_json(sys.argv[1])
for item in d.get("items", []):
    for c in item.get("status", {}).get("conditions", []):
        if c.get("type") == "Preempted" and c.get("status") == "True":
            print(item["metadata"]["namespace"], item["metadata"]["name"])
            break
PY
)
  if [ -z "$list" ]; then
    CAPTURE_FIRST_LINE='DERIVED (generated by repro/run-kind.sh from raw output)'
    write_header "$dir/victim-workload.yaml" "kubectl get workload <none>: no workload had status Preempted=True" "note: no preempted workload at capture time" "exit_code: 0"
    unset CAPTURE_FIRST_LINE
    echo "(no preempted workload)" >> "$dir/victim-workload.yaml"
  fi
  while read -r ns name; do
    [ -n "${name:-}" ] || continue
    run_cap "$dir/victim-workload-${name}.yaml" -- kubectl -n "$ns" get workload "$name" -o yaml
    run_cap_sh "$dir/controller-target-${name}.log" "kubectl -n kueue-system logs deploy/kueue-controller-manager --since-time=$(printf '%q' "$since") | grep -F $(printf '%q' "$name") | head -n 2000 || true"
  done <<< "$list"
}

# After the preemptor is submitted, wait until a preemption is visible and the
# preemptor has quota, or until the deadline if nobody is preempted.
settle_preemptor() {
  local ns=$1 job=$2
  local wl start now elapsed preempted=0 st
  wl=$(submit "$ns" "$job" "${3:-500m}" ${4:-})
  echo "preemptor $ns/$job workload=$wl"
  start=$(date +%s)
  while true; do
    now=$(date +%s)
    elapsed=$((now - start))
    if kubectl get workloads -A -o json | python3 -c 'import json,sys
d=json.load(sys.stdin)
sys.exit(0 if any(c.get("type")=="Preempted" and c.get("status")=="True" for i in d.get("items",[]) for c in i.get("status",{}).get("conditions",[])) else 1)'; then
      preempted=1
    fi
    st=$(quota_status "$ns" "$wl")
    if [ "$preempted" = "1" ] && [ "$st" = "True" ]; then
      sleep 5
      echo "preemptor admitted after preemption (${elapsed}s)"
      return 0
    fi
    if [ "$preempted" = "0" ] && [ "$elapsed" -ge 45 ]; then
      echo "no preemption after ${elapsed}s; preemptor QuotaReserved=${st:-<none>}"
      return 0
    fi
    if [ "$elapsed" -ge 150 ]; then
      echo "giving up after ${elapsed}s; preemptor QuotaReserved=${st:-<none>} preempted=$preempted"
      return 0
    fi
    sleep 2
  done
}

run_scenario() {
  local name=$1
  shift
  local dir=$OUT/$name
  rm -rf "$dir"
  mkdir -p "$dir"
  echo "======== scenario $name ========"
  "$@"
  capture "$dir"
  echo "--- $name clusterqueues ---"
  cat "$dir/clusterqueues.txt"
  echo "--- $name workloads ---"
  cat "$dir/workloads.txt"
  echo "--- $name metrics ---"
  cat "$dir/metrics.txt"
}

apply_base() {
  reset_work
  kubectl_apply -f "$HERE/01-queues.yaml" >/dev/null
  kubectl wait --for=condition=Active clusterqueue/team-a --timeout=120s
  kubectl wait --for=condition=Active clusterqueue/team-b --timeout=120s
}

apply_ordering() {
  reset_work
  kubectl_apply -f "$HERE/01-queues.yaml" -f "$HERE/02-queues-ordering.yaml" >/dev/null
  kubectl wait --for=condition=Active clusterqueue/team-a --timeout=120s
  kubectl wait --for=condition=Active clusterqueue/team-b --timeout=120s
}

scenario_z() {
  apply_base
  admit team-a a1
  admit team-b b1
  admit team-b b2
  admit team-b b3
  local since
  since=$(date -u -d '2 seconds ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
  settle_preemptor team-a a2
  controller_excerpt "$OUT/Z" "$since"
  run_cap "$OUT/Z/clusterqueue-team-a.yaml" -- kubectl get clusterqueue team-a -o yaml
  capture_metrics_curl "$OUT/Z/metrics-curl.txt"
}

scenario_z2() {
  apply_base
  admit team-a a1
  admit team-a a2
  admit team-a a3
  admit team-a a4
  # Status while team-a is actually borrowing, before team-b reclaims.
  mkdir -p "$OUT/Z2"
  capture "$OUT/Z2/while-borrowing"
  run_cap "$OUT/Z2/workloads-before.txt" -- kubectl get workloads -A -o wide
  run_cap "$OUT/Z2/while-borrowing/clusterqueue-team-a.yaml" -- kubectl get clusterqueue team-a -o yaml
  capture_metrics_curl "$OUT/Z2/while-borrowing/metrics-curl.txt"
  local share
  share=$(kubectl get clusterqueue team-a -o jsonpath='{.status.fairSharing.weightedShare}')
  run_cap "$OUT/Z2/while-borrowing/weighted-share.txt" -- kubectl get clusterqueue team-a -o jsonpath='{.status.fairSharing.weightedShare}{"\n"}'
  CAPTURE_FIRST_LINE='DERIVED (generated by repro/run-kind.sh from raw output)'
  write_header "$OUT/Z2/while-borrowing/note.txt" "script echo of the weightedShare jsonpath, also stored raw in weighted-share.txt" "label: DERIVED" "exit_code: 0"
  unset CAPTURE_FIRST_LINE
  echo "team-a share while borrowing: ${share:-<empty>}" | tee -a "$OUT/Z2/while-borrowing/note.txt"
  if [ -z "$share" ]; then
    echo "fair sharing status was not set; the controller config did not take effect" >&2
    exit 1
  fi
  local since
  since=$(date -u -d '2 seconds ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
  settle_preemptor team-b b1
  controller_excerpt "$OUT/Z2" "$since"
  capture_post_preemption "$OUT/Z2" "$since"
}

scenario_zc() {
  apply_base
  kubectl patch clusterqueue team-a --type=merge -p '{"spec":{"fairSharing":{"weight":"1"}}}' >/dev/null
  kubectl wait --for=condition=Active clusterqueue/team-a --timeout=120s
  admit team-a a1
  admit team-b b1
  admit team-b b2
  admit team-b b3
  mkdir -p "$OUT/Zc"
  run_cap "$OUT/Zc/workloads-before.txt" -- kubectl get workloads -A -o wide
  # b3 YAML before preemption. The after-table RESERVED_AT is the eviction time.
  capture_job_workload_yaml "$OUT/Zc" team-b b3 before >/dev/null
  local since
  since=$(date -u -d '2 seconds ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
  settle_preemptor team-a a2
  controller_excerpt "$OUT/Zc" "$since"
  capture_post_preemption "$OUT/Zc" "$since"
}

scenario_o() {
  apply_ordering
  admit team-a a-low 500m low
  admit team-b b1 500m low
  admit team-b b2 500m low
  admit team-b b3 500m low
  local since
  since=$(date -u -d '2 seconds ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
  settle_preemptor team-a a-high 1 high
  controller_excerpt "$OUT/O" "$since"
}

scenario_o2() {
  apply_ordering
  admit team-a a-low 500m low
  admit team-b b1 500m low
  admit team-b b2 500m low
  admit team-b b3 500m low
  local since
  since=$(date -u -d '2 seconds ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
  settle_preemptor team-a a-high 500m high
  controller_excerpt "$OUT/O2" "$since"
}

# condition field. type is QuotaReserved, Admitted, Evicted, Preempted, or Requeued.
cond_status() {
  local ns=$1 wl=$2 type=$3
  kubectl -n "$ns" get workload "$wl" -o jsonpath="{.status.conditions[?(@.type==\"${type}\")].status}" 2>/dev/null || true
}

# Job whose container ignores SIGTERM. terminationGracePeriodSeconds is 30.
# Prints the workload name.
submit_ignore_term() {
  local ns=$1 name=$2 cpu=${3:-500m}
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    kueue.x-k8s.io/queue-name: lq
spec:
  suspend: true
  parallelism: 1
  completions: 1
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      terminationGracePeriodSeconds: 30
      containers:
      - name: sleep
        image: registry.k8s.io/e2e-test-images/busybox:1.36.1-1
        imagePullPolicy: IfNotPresent
        command: ["sh", "-c", "trap '' TERM; sleep 86400"]
        resources:
          requests:
            cpu: ${cpu}
YAML
  local uid wl="" i
  uid=$(kubectl -n "$ns" get job "$name" -o jsonpath='{.metadata.uid}')
  for i in $(seq 1 60); do
    wl=$(kubectl get workloads -A -l "kueue.x-k8s.io/job-uid=${uid}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [ -n "$wl" ] && break
    sleep 1
  done
  if [ -z "$wl" ]; then
    echo "no workload for $ns/$name" >&2
    return 1
  fi
  echo "$wl"
}

wait_pod_running() {
  local ns=$1 job=$2
  local i phase=""
  for i in $(seq 1 90); do
    phase=$(kubectl -n "$ns" get pods -l "job-name=${job}" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
    if [ "$phase" = "Running" ]; then
      echo "pod ${ns}/${job} Running"
      return 0
    fi
    sleep 1
  done
  echo "pod ${ns}/${job} not Running (phase=${phase:-none})" >&2
  kubectl -n "$ns" describe pods -l "job-name=${job}" >&2 || true
  return 1
}

# Three runs: time from Requeued=True to the next "Attempting to schedule workload"
# log line for that workload. Weight 1 on both queues so a2 preempts one team-b job.
measure_requeue_run() {
  local n=$1
  local dir=$OUT/requeue/run-$n
  rm -rf "$dir"
  mkdir -p "$dir"
  echo "======== requeue run $n ========"
  apply_base
  kubectl patch clusterqueue team-a --type=merge -p '{"spec":{"fairSharing":{"weight":"1"}}}' >/dev/null
  kubectl wait --for=condition=Active clusterqueue/team-a --timeout=120s
  admit team-a a1
  admit team-b b1
  admit team-b b2
  admit team-b b3
  local since
  since=$(date -u -d '3 seconds ago' +%Y-%m-%dT%H:%M:%SZ)
  run_cap "$dir/mark.txt" -- date -u +%Y-%m-%dT%H:%M:%SZ
  settle_preemptor team-a a2
  local i found=0
  for i in $(seq 1 40); do
    if kubectl get workloads -A -o json | python3 -c 'import json,sys
d=json.load(sys.stdin)
ok=any(c.get("type")=="Requeued" and c.get("status")=="True" for i in d.get("items",[]) for c in i.get("status",{}).get("conditions",[]))
sys.exit(0 if ok else 1)'; then
      found=1
      break
    fi
    sleep 1
  done
  CAPTURE_FIRST_LINE='DERIVED (generated by repro/run-kind.sh from raw output)'
  write_header "$dir/requeued-seen.txt" "script variable found, set when a workload condition Requeued=True was observed" "label: DERIVED" "exit_code: 0"
  unset CAPTURE_FIRST_LINE
  echo "requeued_seen=$found" >> "$dir/requeued-seen.txt"
  capture "$dir"
  run_cap_sh "$dir/controller.log" "kubectl -n kueue-system logs deploy/kueue-controller-manager --since-time=$(printf '%q' "$since") | head -c 20000000 || true"
  python3 - "$dir" "$HERE" <<'PY'
import datetime, json, pathlib, re, sys
sys.path.insert(0, sys.argv[2])
from capture_json import load_capture_json, load_capture_text
d = pathlib.Path(sys.argv[1])
raw = load_capture_json(d / "workloads.json")

def parse_ts(s):
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    return datetime.datetime.fromisoformat(s)

def cond(item, typ):
    for c in item.get("status", {}).get("conditions", []):
        if c.get("type") == typ:
            return c
    return None

victims = []
for item in raw.get("items", []):
    c = cond(item, "Requeued")
    if c and c.get("status") == "True":
        victims.append(item)
lines = ["source: live kind cluster, not a unit test"]
lines.append(f"requeued_workload_count: {len(victims)}")
log_lines = load_capture_text(d / "controller.log").splitlines() if (d / "controller.log").exists() else []
ts_re = re.compile(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2}))")
for item in victims:
    meta = item["metadata"]
    name = meta["name"]
    ns = meta["namespace"]
    job = ""
    for o in meta.get("ownerReferences") or []:
        job = o.get("name", "")
        break
    rq = cond(item, "Requeued")
    ev = cond(item, "Evicted")
    pr = cond(item, "Preempted")
    rs = item.get("status", {}).get("requeueState")
    lines.append(f"victim_namespace: {ns}")
    lines.append(f"victim_workload: {name}")
    lines.append(f"victim_job: {job}")
    lines.append("requeued_condition: " + json.dumps(rq, sort_keys=True))
    lines.append("evicted_condition: " + json.dumps(ev, sort_keys=True))
    lines.append("preempted_condition: " + json.dumps(pr, sort_keys=True))
    lines.append("requeueState: " + (json.dumps(rs, sort_keys=True) if rs else "<absent>"))
    rq_ts = parse_ts(rq["lastTransitionTime"])
    hits = []
    for line in log_lines:
        if "Attempting to schedule workload" not in line or name not in line:
            continue
        m = ts_re.search(line)
        if not m:
            continue
        ts = parse_ts(m.group(1))
        if ts >= rq_ts:
            hits.append((ts, line))
    hits.sort(key=lambda x: x[0])
    if not hits:
        lines.append("next_attempt_log: <not found>")
        lines.append("delta_seconds: <not found>")
        nearby = [ln for ln in log_lines if name in ln][:40]
        lines.append("log_lines_mentioning_workload:")
        lines.extend(nearby if nearby else ["<none>"])
    else:
        ts, line = hits[0]
        delta = (ts - rq_ts).total_seconds()
        lines.append(f"next_attempt_count_at_or_after_requeued: {len(hits)}")
        lines.append("next_attempt_log: " + line)
        lines.append("next_attempt_timestamp: " + ts.strftime("%Y-%m-%dT%H:%M:%S.%fZ"))
        lines.append(f"delta_seconds: {delta:.6f}")
        lines.append("delta_definition: next Attempting-to-schedule log timestamp minus Requeued lastTransitionTime. Condition time is RFC3339 (one-second resolution). Log time is the controller clock. Live kind cluster, not a unit test.")
(d / "report.txt").write_text("\n".join(lines) + "\n")
print((d / "report.txt").read_text())
PY
  prepend_derived_header "$dir/report.txt" "python3 in repro/run-kind.sh measure_requeue_run: Requeued lastTransitionTime versus the next Attempting-to-schedule log line"
  local ns name
  while read -r ns name; do
    [ -n "${name:-}" ] || continue
    run_cap "$dir/workload-${name}.yaml" -- kubectl -n "$ns" get workload "$name" -o yaml
    run_cap "$dir/requeued-condition-${name}.txt" -- kubectl -n "$ns" get workload "$name" -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.lastTransitionTime}{"\n"}{end}'
    run_cap "$dir/requeued-${name}.txt" -- kubectl -n "$ns" get workload "$name" -o jsonpath='{.status.conditions[?(@.type=="Requeued")]}{"\n"}'
    run_cap "$dir/admitted-${name}.txt" -- kubectl -n "$ns" get workload "$name" -o jsonpath='{.status.conditions[?(@.type=="Admitted")]}{"\n"}'
    run_cap_sh "$dir/attempting-${name}.log" "kubectl -n kueue-system logs deploy/kueue-controller-manager --since-time=$(printf '%q' "$since") | grep -F $(printf '%q' "$name") | grep -F 'Attempting to schedule workload' || true"
  done < <(python3 - "$dir/workloads.json" "$HERE" <<'PY'
import sys
sys.path.insert(0, sys.argv[2])
from capture_json import load_capture_json
raw = load_capture_json(sys.argv[1])
for item in raw.get("items", []):
    for c in item.get("status", {}).get("conditions", []):
        if c.get("type") == "Requeued" and c.get("status") == "True":
            print(item["metadata"]["namespace"], item["metadata"]["name"])
            break
PY
)
  capture_job_workload_yaml "$dir" team-a a2 preemptor >/dev/null
  local pref pns pname
  pref=$(workload_ref_for_job team-a a2 || true)
  pns=${pref%% *}
  pname=${pref##* }
  if [ -n "${pname:-}" ] && [ "${pns:-}" != "$pref" ]; then
    run_cap "$dir/admitted-${pname}.txt" -- kubectl -n "$pns" get workload "$pname" -o jsonpath='{.status.conditions[?(@.type=="Admitted")]}{"\n"}'
  fi
  run_cap_sh "$dir/attempting-schedule.log" "kubectl -n kueue-system logs deploy/kueue-controller-manager --since-time=$(printf '%q' "$since") | grep -F 'Attempting to schedule workload' || true"
}

# Full pod list, timestamped, about once a second until the victim pod is gone.
# POLL lines are date(1). The kubectl stdout that follows each one is unmodified.
watch_pods_until_victim_gone() {
  local dir=$1
  local dest=$dir/pods-all-watch.txt
  set +e
  write_header "$dest" "poll about every 1s until team-b job b3 has no pod, or 300 iterations: date -u +%Y-%m-%dT%H:%M:%S.%NZ; kubectl get pods -A -o wide; kubectl get pods -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,DELETION:.metadata.deletionTimestamp,GRACE:.metadata.deletionGracePeriodSeconds" "note: POLL, DELETION_POLL, VICTIM_POD_COUNT, and POD_GONE lines are written by this loop. kubectl stdout is copied as printed. The wide list includes the preemptor pod and the victim pod."
  write_header "$dest.stderr" "stderr from kubectl get pods -A -o wide in the pod-watch loop" "note: stdout and POLL lines are in pods-all-watch.txt"
  local seen=0 i n
  for i in $(seq 1 300); do
    echo "POLL $(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" >> "$dest"
    kubectl get pods -A -o wide >> "$dest" 2>>"$dest.stderr" || true
    echo "DELETION_POLL $(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" >> "$dest"
    kubectl get pods -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,DELETION:.metadata.deletionTimestamp,GRACE:.metadata.deletionGracePeriodSeconds' >> "$dest" 2>>"$dest.stderr" || true
    n=$(kubectl -n team-b get pods -l job-name=b3 --no-headers --ignore-not-found 2>/dev/null | wc -l | tr -d ' ')
    echo "VICTIM_POD_COUNT ${n}" >> "$dest"
    if [ "${n}" != "0" ]; then
      seen=1
    elif [ "$seen" = "1" ]; then
      echo "POD_GONE $(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" >> "$dest"
      echo "POLL $(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" >> "$dest"
      kubectl get pods -A -o wide >> "$dest" 2>>"$dest.stderr" || true
      set -e
      return 0
    fi
    sleep 1
  done
  echo "WATCH_TIMEOUT $(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" >> "$dest"
  set -e
  return 0
}

# Sleep until epoch+offset, then capture the full pod list.
capture_pods_at_offset() {
  local dest=$1 epoch=$2 offset=$3
  local now target wait_s
  now=$(date +%s)
  target=$((epoch + offset))
  wait_s=$((target - now))
  if [ "$wait_s" -gt 0 ]; then
    sleep "$wait_s"
  fi
  run_cap "$dest" -- kubectl get pods -A -o wide
}

# Three runs: victim ignores SIGTERM and has a 30s grace period.
# Delta is victim Evicted lastTransitionTime to preemptor Admitted lastTransitionTime.
# For a batch Job, IsActive is status.active != 0. That count drops when the
# pod is marked for deletion, so the delta can be 0s while the container is
# still inside terminationGracePeriodSeconds.
measure_grace_run() {
  local n=$1
  local dir=$OUT/grace/run-$n
  rm -rf "$dir"
  mkdir -p "$dir"
  echo "======== grace run $n ========"
  apply_base
  kubectl patch clusterqueue team-a --type=merge -p '{"spec":{"fairSharing":{"weight":"1"}}}' >/dev/null
  kubectl wait --for=condition=Active clusterqueue/team-a --timeout=120s
  admit team-a a1
  admit team-b b1
  admit team-b b2
  local b3 i st
  b3=$(submit_ignore_term team-b b3)
  echo "submitted team-b/b3 workload=$b3"
  for i in $(seq 1 90); do
    st=$(cond_status team-b "$b3" QuotaReserved)
    if [ "$st" = "True" ]; then
      echo "admitted team-b/b3 workload=$b3"
      sleep 3
      break
    fi
    sleep 1
  done
  [ "$(cond_status team-b "$b3" QuotaReserved)" = "True" ]
  wait_pod_running team-b b3
  run_cap "$dir/victim-pod-before.json" -- kubectl -n team-b get pod -l job-name=b3 -o json
  python3 - "$dir/victim-pod-before.json" "$HERE" <<'PY' | tee "$dir/pod-spec.txt"
import json, sys
sys.path.insert(0, sys.argv[2])
from capture_json import load_capture_json
p = load_capture_json(sys.argv[1])
items = p["items"] if "items" in p else [p]
pod = items[0]
spec = pod["spec"]
c = spec["containers"][0]
print(f"pod: {pod['metadata']['name']}")
print(f"terminationGracePeriodSeconds: {spec.get('terminationGracePeriodSeconds')}")
print(f"image: {c.get('image')}")
print("command: " + json.dumps(c.get("command")))
print(f"phase: {pod.get('status', {}).get('phase')}")
PY
  prepend_derived_header "$dir/pod-spec.txt" "python3 in repro/run-kind.sh measure_grace_run: selected fields from victim-pod-before.json"
  local since preemptor admitted=0 watch_pid evict_epoch=0
  since=$(date -u -d '3 seconds ago' +%Y-%m-%dT%H:%M:%SZ)
  watch_pods_until_victim_gone "$dir" &
  watch_pid=$!
  preemptor=$(submit team-a a2)
  echo "preemptor team-a/a2 workload=$preemptor"
  for i in $(seq 1 150); do
    st=$(cond_status team-b "$b3" Evicted)
    if [ "$st" = "True" ]; then
      evict_epoch=$(date +%s)
      run_cap "$dir/pods-at-eviction.txt" -- kubectl get pods -A -o wide
      run_cap "$dir/pods-at-eviction-deletion.txt" -- kubectl get pods -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,DELETION:.metadata.deletionTimestamp,GRACE:.metadata.deletionGracePeriodSeconds'
      break
    fi
    sleep 1
  done
  for i in $(seq 1 150); do
    st=$(cond_status team-a "$preemptor" Admitted)
    if [ "$st" = "True" ]; then
      admitted=1
      echo "preemptor Admitted after poll ${i}s"
      break
    fi
    sleep 1
  done
  if [ "$evict_epoch" != 0 ]; then
    capture_pods_at_offset "$dir/pods-at-about-10s.txt" "$evict_epoch" 10
    run_cap "$dir/pods-at-about-10s-deletion.txt" -- kubectl get pods -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,DELETION:.metadata.deletionTimestamp,GRACE:.metadata.deletionGracePeriodSeconds'
    capture_pods_at_offset "$dir/pods-at-about-28s.txt" "$evict_epoch" 28
    run_cap "$dir/pods-at-about-28s-deletion.txt" -- kubectl get pods -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,DELETION:.metadata.deletionTimestamp,GRACE:.metadata.deletionGracePeriodSeconds'
  fi
  CAPTURE_FIRST_LINE='DERIVED (generated by repro/run-kind.sh from raw output)'
  write_header "$dir/admitted-seen.txt" "script variable admitted, set when the preemptor Admitted condition became True" "label: DERIVED" "exit_code: 0"
  unset CAPTURE_FIRST_LINE
  echo "preemptor_admitted_poll=$admitted" >> "$dir/admitted-seen.txt"
  run_cap "$dir/victim-workload.yaml" -- kubectl -n team-b get workload "$b3" -o yaml
  run_cap "$dir/preemptor-workload.yaml" -- kubectl -n team-a get workload "$preemptor" -o yaml
  run_cap "$dir/victim-conditions.txt" -- kubectl -n team-b get workload "$b3" -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.lastTransitionTime}{"\n"}{end}'
  run_cap "$dir/preemptor-conditions.txt" -- kubectl -n team-a get workload "$preemptor" -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.lastTransitionTime}{"\n"}{end}'
  wait "$watch_pid" || true
  capture "$dir"
  run_cap_sh "$dir/controller.log" "kubectl -n kueue-system logs deploy/kueue-controller-manager --since-time=$(printf '%q' "$since") | head -c 20000000 || true"
  run_cap_sh "$dir/events-team-b.json" "kubectl -n team-b get events --sort-by=.lastTimestamp -o json || echo '{\"items\":[]}'"
  python3 - "$dir" "$b3" "$preemptor" "$HERE" <<'PY'
import datetime, json, pathlib, sys
sys.path.insert(0, sys.argv[4])
from capture_json import load_capture_json, load_capture_text
d = pathlib.Path(sys.argv[1])
victim_name, preemptor_name = sys.argv[2], sys.argv[3]
raw = load_capture_json(d / "workloads.json")

def parse_ts(s):
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    return datetime.datetime.fromisoformat(s)

def cond(item, typ):
    for c in item.get("status", {}).get("conditions", []):
        if c.get("type") == typ:
            return c
    return None

by = {i["metadata"]["name"]: i for i in raw.get("items", [])}
victim = by.get(victim_name)
pre = by.get(preemptor_name)
lines = ["source: live kind cluster, not a unit test"]
lines.append("label: DERIVED by repro/run-kind.sh from workload JSON and pod-spec.txt")
if (d / "pod-spec.txt").exists():
    lines.append(load_capture_text(d / "pod-spec.txt").rstrip())
if victim is None or pre is None:
    lines.append(f"missing workload victim_present={victim is not None} preemptor_present={pre is not None}")
else:
    ev = cond(victim, "Evicted")
    ad = cond(pre, "Admitted")
    qr = cond(pre, "QuotaReserved")
    lines.append(f"victim_workload: {victim_name}")
    lines.append(f"victim_job: b3")
    lines.append(f"preemptor_workload: {preemptor_name}")
    lines.append(f"preemptor_job: a2")
    lines.append("evicted_condition: " + json.dumps(ev, sort_keys=True))
    lines.append("preemptor_admitted_condition: " + json.dumps(ad, sort_keys=True))
    lines.append("preemptor_quota_reserved_condition: " + json.dumps(qr, sort_keys=True))
    if ev and ad and ev.get("lastTransitionTime") and ad.get("lastTransitionTime"):
        delta = (parse_ts(ad["lastTransitionTime"]) - parse_ts(ev["lastTransitionTime"])).total_seconds()
        lines.append(f"delta_evicted_to_admitted_seconds: {delta:.0f}")
        lines.append("delta_definition: preemptor Admitted lastTransitionTime minus victim Evicted lastTransitionTime. Both are Workload condition timestamps from the live kind cluster (RFC3339, one-second resolution), not a unit test.")
    else:
        lines.append("delta_evicted_to_admitted_seconds: <not found>")
evp = d / "events-team-b.json"
if evp.exists() and evp.stat().st_size:
    evs = load_capture_json(evp)
    for e in evs.get("items", []):
        msg = e.get("message") or ""
        reason = e.get("reason") or ""
        if reason in ("Killing", "Preempted", "SuccessfulDelete") or "grace" in msg.lower() or "signal" in msg.lower():
            lines.append("pod_event: " + json.dumps({
                "reason": reason,
                "involvedObject": e.get("involvedObject", {}).get("name"),
                "firstTimestamp": e.get("firstTimestamp"),
                "lastTimestamp": e.get("lastTimestamp"),
                "message": msg,
            }, sort_keys=True))
(d / "report.txt").write_text("\n".join(lines) + "\n")
print((d / "report.txt").read_text())
PY
  prepend_derived_header "$dir/report.txt" "python3 in repro/run-kind.sh measure_grace_run: Evicted and Admitted condition timestamps from workloads.json"
  python3 "$HERE/grace_timeline.py" "$dir" > "$dir/grace-timeline.body" || true
  if [ -s "$dir/grace-timeline.body" ]; then
    cat "$dir/grace-timeline.body" > "$dir/grace-timeline.txt"
    prepend_derived_header "$dir/grace-timeline.txt" "python3 repro/grace_timeline.py: reads victim-conditions.txt, preemptor-conditions.txt, and pods-all-watch.txt"
    rm -f "$dir/grace-timeline.body"
  fi
}

if [ "${1:-}" != "--checks-only" ]; then
run_scenario Z scenario_z
run_scenario Z2 scenario_z2
run_scenario Zc scenario_zc
run_scenario O scenario_o
run_scenario O2 scenario_o2
fi

measure_requeue_run 1
measure_requeue_run 2
measure_requeue_run 3
measure_grace_run 1
measure_grace_run 2
measure_grace_run 3

python3 - "$OUT" <<'PY'
import pathlib, sys
out = pathlib.Path(sys.argv[1])
lines = ["# ROLLUP generated by repro/run-kind.sh. Not raw kubectl output.", "# Cite the capture files under this directory. Numbers were read from the live kind cluster, not from a unit test.", ""]
lines.append((out / "versions.txt").read_text() if (out / "versions.txt").exists() else "")
lines.append((out / "kueue-deploy.txt").read_text() if (out / "kueue-deploy.txt").exists() else "")
lines.append((out / "nodes.txt").read_text() if (out / "nodes.txt").exists() else "")
for name in ["Z", "Z2", "Zc", "O", "O2"]:
    d = out / name
    lines.append(f"## {name}")
    if name == "Z2" and (d / "while-borrowing").is_dir():
        lines.append("### while borrowing, before the reclaim")
        for fn in ["note.txt", "clusterqueues.txt", "fairsharing-status.txt", "metrics.txt", "workloads.txt", "conditions.txt"]:
            p = d / "while-borrowing" / fn
            if p.exists():
                lines.append(f"#### {fn}")
                lines.append(p.read_text().rstrip())
                lines.append("")
    for fn in ["clusterqueues.txt", "fairsharing-status.txt", "cohort.txt", "workloads.txt", "conditions.txt", "metrics.txt", "events-preempted.txt", "events-preempted-lines.txt", "controller-fairsharing.log"]:
        p = d / fn
        lines.append(f"### {fn}")
        lines.append(p.read_text().rstrip() if p.exists() else "(missing)")
        lines.append("")
for kind in ("requeue", "grace"):
    lines.append(f"## {kind}")
    runs = sorted((out / kind).glob("run-*/report.txt"))
    if not runs:
        lines.append("(no runs)")
        lines.append("")
        continue
    for p in runs:
        lines.append(f"### {p.parent.name}")
        lines.append(p.read_text().rstrip())
        lines.append("")
(out / "SUMMARY.txt").write_text("\n".join(lines) + "\n")
print(f"wrote {out / 'SUMMARY.txt'}")
PY
prepend_derived_header "$OUT/SUMMARY.txt" "python3 in repro/run-kind.sh: rollup of the capture files in this directory. Not raw kubectl output."

echo "cluster logs in $OUT"
