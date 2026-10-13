#!/usr/bin/env bash
# MinIO vs RustFS, test 1: speed on one node. One contender at a time, always:
# in my lab every volume sits on the same physical SSD, so two servers under
# load would measure each other. Both servers run on the same node (role label
# sut-a), each on its own volume there, so the node is not a variable.
#
#   case <size> <op> [contender...]   one ramp per contender, back to back
#                                     size 4k|1m|100m   op put|get|mixed (70% GET)
#   (the full matrix, three runs per case, unattended: ./queue.sh)
#   warp <size> <op> [contender...]   cross-check with warp (closed loop, CONC clients)
#   fio [contender...]                disk baseline on the contender's own PVC
#   wipe [contender...]               empty the data volume (between object sizes)
#   check                             fairness rules: QoS, budgets, who is running
#   stop                              everything to 0
#   cleanup                           delete the PVCs and their volumes
#
# Env overrides for a case: KEYS WORKERS RATE_START RATE_STEP RATE_MAX STEP_SECONDS,
# LOADGEN_ENV="NAME=value ..." for any other loadgen setting (HOLD_STEPS, STOP_BELOW, ...),
# WIPE=1 (empty the volume first), SINGLE_PUT=1 (100 MiB as one PUT instead of multipart),
# SUSTAIN=10 (1m and 100m put and mixed: 10 minutes of closed-loop load instead of a ramp),
# RUSTFS_MODE=relaxed|none (RUSTFS_DURABILITY_MODE for this case only; default strict).
# Env for warp: CONC (default = WORKERS of that size) DURATION (1m) OBJECTS (KEYS).
# Cluster settings: TOOLS_IMAGE (warp + fio, built from images/tools) and PROM_PROXY
# (API server proxy path of your Prometheus or VictoriaMetrics service).
# Results: the loadgen's STEP and DONE lines, appended to runs.log with UTC boundaries.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
ns=benchmark
tools=${TOOLS_IMAGE:-your-registry.example.com/s3-bench-tools:warp-1.8.2} # build it from images/tools (README)
# Where the CPU and memory numbers of a case come from. Prometheus and VictoriaMetrics both answer /api/v1/query.
prom=${PROM_PROXY:-/api/v1/namespaces/monitoring/services/prometheus-server:80/proxy}
declare -A NODE=([minio]=sut-a [rustfs]=sut-a)
k() { kubectl -n "$ns" "$@"; }
now() { date -u +%FT%TZ; }
log() { echo "$*" | tee -a "$here/runs.log"; }

# Per object size and op: bytes, key space (the GET data set), workers, rate start/step/max per second.
# Rates were placed with warp's closed-loop numbers on my disk so that a ramp
# reaches the slower contender's knee after 5 or more steps and the faster one's within about 25.
params() {
  case "$1" in
    # 500k keys: a 4 KiB object costs 12 KiB and 2 inodes on disk on both servers, so this is 6 GiB,
    # twice the 3 GiB pod limit. A 30 GiB ext4 volume has 1.97M inodes: 1M such objects do not fit.
    4k)   size=4096;      keys=500000;  workers=64; stepsec=30 ;;
    1m)   size=1048576;   keys=20000;   workers=32; stepsec=30 ;;
    100m) size=104857600; keys=200;     workers=8;  stepsec=60 ;; # few operations per second: longer steps, more samples
    *) echo "size: 4k|1m|100m"; exit 1 ;;
  esac
  case "$1:${2:-put}" in
    # 4 KiB writes: 60 s steps. The volume stalls for 10 to 40 s after every few GiB written; with 30 s
    # steps one stall made the two low steps that end a ramp. (Runs before 2026-10-13 09:00 UTC: 30 s, half the step.)
    4k:put)     start=50;  step=50;  max=2000; stepsec=60 ;;   # bound by fsync on this disk
    4k:get)     start=500; step=500; max=20000 ;;
    4k:mixed)   start=200; step=200; max=6000; stepsec=60 ;;
    1m:put)     start=10;  step=10;  max=400 ;;
    1m:get)     start=50;  step=50;  max=2000 ;;
    1m:mixed)   start=25;  step=25;  max=1500 ;;
    100m:put)   start=0.5; step=0.5; max=10 ;;
    100m:get)   start=1;   step=1;   max=30 ;;
    100m:mixed) start=1;   step=1;   max=30 ;;
    *) echo "op: put|get|mixed"; exit 1 ;;
  esac
  # SUSTAIN=<minutes>: no ramp. A fixed rate far above what either server takes (so every worker is
  # always busy: closed loop) for that long, 30 s steps; the result is the mean over the whole run,
  # stalls included. For large-object writes, where a stall comes every 70 to 110 s and no ramp survives.
  # Smaller key spaces: the run overwrites them several times and replaced data must fit beside them.
  hold=""
  if [ -n "${SUSTAIN:-}" ]; then
    case "$1:${2:-put}" in
      1m:put)     start=400;  keys=10000 ;;
      1m:mixed)   start=1500; keys=10000 ;;
      100m:put)   start=10;   keys=50 ;;
      100m:mixed) start=30;   keys=50 ;;
      *) echo "SUSTAIN is for 1m and 100m put and mixed"; exit 1 ;;
    esac
    step=0; max=$start; stepsec=30; hold="STOP_BELOW=0 HOLD_STEPS=$(( SUSTAIN * 2 ))"
  fi
  keys=${KEYS:-$keys}; workers=${WORKERS:-$workers}
  start=${RATE_START:-$start}; step=${RATE_STEP:-$step}; max=${RATE_MAX:-$max}; stepsec=${STEP_SECONDS:-$stepsec}
}

# Instant query against the metrics store through the API server proxy. $1 PromQL, $2 time.
vm() {
  kubectl get --raw "$prom/api/v1/query?time=$2&query=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$1")" 2>/dev/null |
    python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print("%.2f" % float(r[0]["value"][1]) if r else "nan")' 2>/dev/null || echo nan
}

# Demo credentials for this benchmark only: random, created once in the cluster, never printed or written to disk.
creds() {
  k get secret s3-bench-creds >/dev/null 2>&1 ||
    k create secret generic s3-bench-creds --from-literal=access-key="bench$(openssl rand -hex 6)" \
      --from-literal=secret-key="$(openssl rand -hex 20)" >/dev/null
}

down() {
  k scale sts minio rustfs --replicas=0 >/dev/null
  k scale deploy loadgen-minio loadgen-rustfs --replicas=0 >/dev/null
  k delete job -l bench=minio-vs-rustfs --ignore-not-found >/dev/null
  k wait --for=delete pod -l 'app in (minio,rustfs,loadgen-minio,loadgen-rustfs)' --timeout=120s >/dev/null
}

up() { # $1 contender: the only server running
  creds
  # Durability knob: unset = the image default (strict). Changing it restarts the server.
  if [ -n "${RUSTFS_MODE:-}" ]; then k set env sts/rustfs RUSTFS_DURABILITY_MODE="$RUSTFS_MODE" >/dev/null
  else k set env sts/rustfs RUSTFS_DURABILITY_MODE- >/dev/null; fi
  for other in minio rustfs; do [ "$other" = "$1" ] || k scale sts "$other" --replicas=0 >/dev/null; done
  k delete job -l bench=minio-vs-rustfs --ignore-not-found >/dev/null # no leftover jobs next to a server
  k wait --for=delete pod -l "app in (minio,rustfs),app!=$1" --timeout=120s >/dev/null
  k scale sts "$1" --replicas=1 >/dev/null
  k rollout status "sts/$1" --timeout=300s >/dev/null
}

# $1 contender, $2 job name, $3 mounts the contender's PVC (yes|no), rest: container command.
# Runs a one-off Job with the same budget as a server (fio) or a loadgen (warp) and prints its log.
job() {
  local db=$1 name=$2 pvc=$3 role=clients mem=1Gi cpu=${JOB_CPU:-3} vol=""; shift 3
  if [ "$pvc" = yes ]; then
    role=${NODE[$db]}; mem=${JOB_MEM:-3Gi}
    vol=", \"volumeMounts\": [{\"name\": \"data\", \"mountPath\": \"/data\"}]"
  fi
  k delete job "$name" --ignore-not-found >/dev/null
  cat <<EOF | k apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata: { name: $name, labels: { bench: minio-vs-rustfs } }
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      nodeSelector: { bench-role: $role }
      securityContext: { runAsUser: 10001, runAsGroup: 10001, fsGroup: 10001, fsGroupChangePolicy: OnRootMismatch }
      containers:
        - { name: tool, image: $tools, command: $(printf '%s\0' "$@" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().split("\0")[:-1]))'),
            env: [{ name: HOME, value: /tmp },
                  { name: WARP_HOST, value: "$db-0.$db.$ns.svc.cluster.local:9000" },
                  { name: WARP_ACCESS_KEY, valueFrom: { secretKeyRef: { name: s3-bench-creds, key: access-key } } },
                  { name: WARP_SECRET_KEY, valueFrom: { secretKeyRef: { name: s3-bench-creds, key: secret-key } } }],
            resources: { requests: { cpu: "$cpu", memory: $mem }, limits: { cpu: "$cpu", memory: $mem } }$vol }
      volumes: [{ name: data, $([ "$pvc" = yes ] && echo "persistentVolumeClaim: { claimName: data-$db-0 }" || echo "emptyDir: {}") }]
EOF
  [ -z "${NOWAIT:-}" ] || return 0
  until k get job "$name" -o jsonpath='{.status.conditions[?(@.status=="True")].type}' | grep -qE 'Complete|Failed'; do sleep 5; done
  k logs "job/$name"
}

# Pod logs die with the pod, so every case keeps them: server log, loadgen log, probe log,
# `describe` of the server pod, `top` at the end, and the tool's output for warp and fio.
# .queue/ is git-ignored: the files are large and contain your node names.
save() { # $1 contender, $2 label, stdin: tool output if any
  local d="$here/.queue/artifacts/${CASE_ID:+$CASE_ID-}$2-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$d"
  [ -t 0 ] || cat >"$d/tool-output.txt"; [ -s "$d/tool-output.txt" ] || rm -f "$d/tool-output.txt"
  k logs "$1-0" >"$d/server.log" 2>&1 || true
  k logs "deploy/loadgen-$1" >"$d/loadgen.log" 2>&1 || true
  k logs "job/probe-$1" >"$d/probe.log" 2>&1 || true
  k describe pod "$1-0" >"$d/server-describe.txt" 2>&1 || true
  k top pod --no-headers >"$d/top.txt" 2>&1 || true
  log "  artifacts: ${d#"$here"/}"
}

# The PVC is created by the StatefulSet on first start; fio and wipe need it with the server down.
pvc_only() {
  creds
  k get pvc "data-$1-0" >/dev/null 2>&1 || { k scale sts "$1" --replicas=1 >/dev/null; k rollout status "sts/$1" --timeout=300s >/dev/null; }
  k scale sts minio rustfs --replicas=0 >/dev/null
  k wait --for=delete pod -l 'app in (minio,rustfs)' --timeout=120s >/dev/null
}

# Block device counters of the contender's volume, every 10 s, from a tiny pod next to the
# server (a second pod on the same node may mount a ReadWriteOnce volume). /sys/block/<dev>/stat:
# field 5 is writes completed, field 16 flush requests. This virtual disk reports no volatile
# write cache (queue/write_cache = "write through"), so the guest sends no flush commands and
# field 16 stays 0: here a sync costs its journal and data writes, counted as writes per operation.
probe() {
  JOB_CPU=10m JOB_MEM=32Mi NOWAIT=1 job "$1" "probe-$1" yes sh -c '
    dev=$(basename "$(df /data | tail -1 | cut -d" " -f1)")
    echo "PROBEINFO device $dev, write_cache: $(cat /sys/block/$dev/queue/write_cache), fs: $(awk "\$2==\"/data\"{print \$3, \$4}" /proc/mounts)"
    while :; do echo "PROBE $(date +%s) $(cat /sys/block/$dev/stat) $(awk "/^Cached:/{print \$2}" /proc/meminfo)"; sleep 10; done'
}

ramp() { # $1 contender $2 size $3 op
  local db=$1 op=$3 t0 t1 dur servers maxservers=0 prefill=false part=0 pod peak w
  params "$2" "$op"; [ "$op" = put ] || prefill=true
  [ "$2" != 100m ] || [ -n "${SINGLE_PUT:-}" ] || part=16777216
  [ -z "${WIPE:-}" ] || "$0" wipe "$db" >/dev/null
  up "$db"; probe "$db"
  # `kubectl set env` is sticky: drop the optional settings of an earlier case first.
  k set env "deploy/loadgen-$db" MAX_LAG_SECONDS- STOP_BELOW- HOLD_STEPS- KEYS_PER_PREFIX- GET_SHARE- PREFILL_WORKERS- MULTIPART_CONCURRENCY- >/dev/null
  k set env "deploy/loadgen-$db" OP="$op" OBJECT_SIZE="$size" KEYS="$keys" WORKERS="$workers" PREFILL="$prefill" \
    RATE_START="$start" RATE_STEP="$step" RATE_MAX="$max" STEP_SECONDS="$stepsec" MULTIPART_PART_SIZE="$part" \
    OP_TIMEOUT_SECONDS="$([ "$2" = 100m ] && echo 300 || echo 60)" $hold ${LOADGEN_ENV:-} >/dev/null
  k scale deploy "loadgen-$db" --replicas=1 >/dev/null
  k rollout status "deploy/loadgen-$db" --timeout=300s >/dev/null
  pod=$(k get pod -l "app=loadgen-$db" -o jsonpath='{.items[0].metadata.name}')
  t0=$(now); echo "$db $2 $op: started $t0 (keys $keys, workers $workers, $start..$max per second, part size $part, ${stepsec} s steps${SUSTAIN:+, sustained $SUSTAIN min}${RUSTFS_MODE:+, rustfs $RUSTFS_MODE}${LOADGEN_ENV:+, $LOADGEN_ENV})"
  until k logs "deploy/loadgen-$db" 2>/dev/null | grep -c ' DONE ' >/dev/null; do # -c, not -q: an early exit breaks the pipe and pipefail
    sleep 15
    [ "$(k get pod -l "app=loadgen-$db" -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')" = 0 ] ||
      { k logs "deploy/loadgen-$db" --previous | tail -5; echo "loadgen-$db crashed"; exit 1; }
    servers=$(k get pods -l 'app in (minio,rustfs)' --no-headers 2>/dev/null | wc -l); [ "$servers" -le "$maxservers" ] || maxservers=$servers
  done
  t1=$(now); dur=$(( $(date -d "$t1" +%s) - $(date -d "$t0" +%s) ))
  # One line per case with everything the honesty rules ask for. CPU from cAdvisor (5 s scrape), for
  # this case's own pods, averaged over the best step (a ramp) or over the whole run (sustained).
  # (Until 2026-10-13 09:00 UTC this was the maximum of a 20 s rate over every loadgen pod: it leaked the
  # previous case's pod and showed values above the limit.)
  if [ -n "${SUSTAIN:-}" ]; then peak=$t1; w=$(( SUSTAIN * 60 ))
  else peak=$(k logs "deploy/loadgen-$db" | python3 -c '
import re, sys
best = max((float(m.group(2)), m.group(1)) for m in (re.match(r"(\S+ \S+) STEP target=\S+ ok/s=(\S+)", l) for l in sys.stdin) if m)
print(best[1].replace("/", "-").replace(" ", "T") + "Z")'); w=$stepsec; fi
  log "$db $2 $op${SUSTAIN:+ sustained}${RUSTFS_MODE:+ rustfs=$RUSTFS_MODE}${SINGLE_PUT:+ single-put}${LOADGEN_ENV:+ [$LOADGEN_ENV]}: $t0 -> $t1," \
    "loadgen CPU at peak $(vm "sum(rate(container_cpu_usage_seconds_total{job=\"cadvisor-benchmark\",namespace=\"$ns\",pod=\"$pod\",container=\"loadgen\"}[${w}s]))" "$peak") of 3.4," \
    "server CPU at peak $(vm "sum(rate(container_cpu_usage_seconds_total{job=\"cadvisor-benchmark\",namespace=\"$ns\",pod=\"$db-0\",container=\"$db\"}[${w}s]))" "$peak") of 3," \
    "server memory max MiB $(vm "max_over_time(sum(container_memory_working_set_bytes{job=\"cadvisor-benchmark\",namespace=\"$ns\",pod=\"$db-0\",container=\"$db\"})[${dur}s:5s])/1048576" "$t1")," \
    "of it page cache MiB $(vm "max_over_time(sum(container_memory_cache{job=\"cadvisor-benchmark\",namespace=\"$ns\",pod=\"$db-0\",container=\"$db\"})[${dur}s:5s])/1048576" "$t1")," \
    "server restarts $(k get pod "$db-0" -o jsonpath='{.status.containerStatuses[0].restartCount}'), servers up at once $maxservers"
  { k logs "deploy/loadgen-$db" | grep -E 'PREFILL|STEP|DONE'; k logs "job/probe-$db" 2>/dev/null | grep '^PROBE' || true; } |
    python3 "$here/diskstat.py" "$stepsec" ${SUSTAIN:+sustained} | sed "s/^/  /" | tee -a "$here/runs.log"
  save "$db" "$db-$2-$op" </dev/null
  k scale deploy "loadgen-$db" --replicas=0 >/dev/null
}

contenders() { if [ $# -gt 0 ]; then echo "$@"; else echo minio rustfs; fi; }

case "${1:-}" in
  case)
    for db in $(contenders "${@:4}"); do ramp "$db" "$2" "$3"; done; down ;;
  warp)
    params "$2" "$3"
    for db in $(contenders "${@:4}"); do
      up "$db"
      common=(--obj.size "$size" --concurrent "${CONC:-$workers}" --duration "${DURATION:-1m}" --no-color --benchdata /tmp/warp)
      case "$3" in
        put)   cmd=(warp put "${common[@]}") ;;
        get)   cmd=(warp get "${common[@]}" --objects "${OBJECTS:-$keys}") ;;
        mixed) cmd=(warp mixed "${common[@]}" --objects "${OBJECTS:-$keys}" --get-distrib 70 --put-distrib 30 --stat-distrib 0 --delete-distrib 0) ;;
        *) echo "op: put|get|mixed"; exit 1 ;;
      esac
      t0=$(now); out=$(job "$db" "warp-$db" no "${cmd[@]}")
      log "$db $2 $3 warp (${CONC:-$workers} clients): $t0 -> $(now)"
      echo "$out" | grep -vE '^\s*$' | tail -25 | sed "s/^/  /" | tee -a "$here/runs.log"
      echo "$out" | save "$db" "$db-$2-$3-warp"
    done; down ;;
  fio)
    for db in $(contenders "${@:2}"); do
      pvc_only "$db"
      # O_DIRECT, so this is the volume and not the page cache. 4k sync writes are
      # what a strict-fsync object store pays per small PUT.
      t0=$(now); out=$(job "$db" "fio-$db" yes sh -c '
        f="--filename=/data/.fio-baseline --size=4G --direct=1 --ioengine=libaio --runtime=30 --time_based --group_reporting"
        fio $f --name=seqwrite-1m --rw=write --bs=1M --iodepth=16 | grep -E "^ *(write|read):"
        fio $f --name=seqread-1m --rw=read --bs=1M --iodepth=16 | grep -E "^ *(write|read):"
        fio $f --name=randread-4k --rw=randread --bs=4k --iodepth=32 | grep -E "^ *(write|read):"
        fio $f --name=randwrite-4k --rw=randwrite --bs=4k --iodepth=32 | grep -E "^ *(write|read):"
        fio $f --name=syncwrite-4k --rw=randwrite --bs=4k --iodepth=1 --fsync=1 | grep -E "^ *(write|read):"
        fio $f --name=syncwrite-4k-64 --rw=randwrite --bs=4k --iodepth=1 --fsync=1 --numjobs=64 | grep -E "^ *(write|read):"
        rm -f /data/.fio-baseline')
      log "$db fio on data-$db-0 (${NODE[$db]}): $t0 -> $(now); order: seq write 1M, seq read 1M, rand read 4k, rand write 4k, 4k write + fsync (1 writer), 4k write + fsync (64 writers)"
      echo "$out" | sed "s/^/  /" | tee -a "$here/runs.log"
      echo "$out" | save "$db" "$db-fio"
    done; down ;;
  wipe)
    for db in $(contenders "${@:2}"); do
      pvc_only "$db"
      job "$db" "wipe-$db" yes sh -c 'find /data -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf {} + ; df -h /data | tail -1'
    done; down ;;
  check)
    echo "running pods (one contender at most, plus its loadgen):"
    k get pods -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,QOS:.status.qosClass,CPU:.spec.containers[0].resources.limits.cpu,MEM:.spec.containers[0].resources.limits.memory,RESTARTS:.status.containerStatuses[0].restartCount' --no-headers
    echo "budgets in the manifests:"
    k get sts minio rustfs -o custom-columns='STS:.metadata.name,REQ:.spec.template.spec.containers[0].resources.requests,LIM:.spec.template.spec.containers[0].resources.limits,IMAGE:.spec.template.spec.containers[0].image' --no-headers
    k top pod --no-headers 2>/dev/null || true ;;
  stop) down; echo stopped ;;
  cleanup)
    # A StorageClass with reclaim policy Retain keeps the volume when its PVC is deleted, so the
    # PV is switched to Delete first. Only this benchmark's own claims are touched.
    down
    for db in minio rustfs; do
      pv=$(k get pvc "data-$db-0" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
      [ -n "$pv" ] || continue
      kubectl patch pv "$pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' >/dev/null
      k delete pvc "data-$db-0" >/dev/null
      echo "data-$db-0: deleted, volume $pv handed back to the CSI driver"
    done ;;
  *) sed -n 2,25p "$0"; exit 1 ;;
esac
