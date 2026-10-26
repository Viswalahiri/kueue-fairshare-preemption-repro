#!/usr/bin/env bash
# Usage: ./job.sh <namespace> <name> [cpu=500m] [priority-class]
# Prints a suspended batch/v1 Job that Kueue manages via the LocalQueue "lq".
set -euo pipefail
ns=$1; name=$2; cpu=${3:-500m}; pc=${4:-}
cat <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    kueue.x-k8s.io/queue-name: lq
$( [ -n "$pc" ] && echo "    kueue.x-k8s.io/priority-class: ${pc}" )
spec:
  suspend: true
  parallelism: 1
  completions: 1
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: sleep
        image: registry.k8s.io/pause:3.10
        resources:
          requests:
            cpu: ${cpu}
YAML
