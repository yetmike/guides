#!/usr/bin/env bash
# Test 4: resource use, small objects only. Per contender, on a fresh volume:
#   start time (empty volume, then three restarts), 10 minutes idle,
#   100 PUT/s for 5 minutes, 1,000 GET/s for 5 minutes (4 KiB, 5,000 keys).
# CPU and memory from cAdvisor (5 s scrape) through PROM_PROXY (see run.sh). Output: .queue/test4.log
# Stops and scales everything to 0 if a control plane component restarts while it runs.
# It starts with `run.sh cleanup`: the benchmark volumes are deleted.
#   setsid nohup ./test4.sh >/dev/null 2>&1 &        about 50 minutes per contender
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); ns=benchmark; log=$here/.queue/test4.log; mkdir -p "$here/.queue"
prom=${PROM_PROXY:-/api/v1/namespaces/monitoring/services/prometheus-server:80/proxy}
k() { kubectl -n "$ns" "$@"; }
say() { echo "$(date -u +%FT%TZ) $*" | tee -a "$log"; }
vm() {
  kubectl get --raw "$prom/api/v1/query?time=$2&query=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$1")" 2>/dev/null |
    python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print("%.3f" % float(r[0]["value"][1]) if r else "nan")' 2>/dev/null || echo nan
}
cp_restarts() { kubectl -n kube-system get pods -o json | python3 -c 'import json,sys; print(sum(c["restartCount"] for p in json.load(sys.stdin)["items"] if any(x in p["metadata"]["name"] for x in ("apiserver","controller-manager","scheduler")) for c in p["status"].get("containerStatuses",[])))'; }
restore() { "$here/run.sh" stop >/dev/null 2>&1; say "END, everything scaled to 0"; }
trap restore EXIT; trap 'exit 143' TERM INT HUP
base=$(cp_restarts)
guard() { local now; now=$(cp_restarts); [ "$now" = "$base" ] || { say "control plane restart count went from $base to $now: stopping"; exit 1; }; }
usage() { # $1 contender $2 label $3 window seconds, ending now
  local t; t=$(date -u +%FT%TZ)
  say "$1 $2: CPU avg $(vm "sum(rate(container_cpu_usage_seconds_total{job=\"cadvisor-benchmark\",namespace=\"$ns\",pod=\"$1-0\",container=\"$1\"}[${3}s]))" "$t") cores," \
    "memory working set max $(vm "max_over_time(sum(container_memory_working_set_bytes{job=\"cadvisor-benchmark\",namespace=\"$ns\",pod=\"$1-0\",container=\"$1\"})[${3}s:5s])/1048576" "$t") MiB," \
    "RSS max $(vm "max_over_time(sum(container_memory_rss{job=\"cadvisor-benchmark\",namespace=\"$ns\",pod=\"$1-0\",container=\"$1\"})[${3}s:5s])/1048576" "$t") MiB (window ${3} s)"
}
start() { # $1 contender $2 label: scale up and time it
  k scale sts "$1" --replicas=1 >/dev/null; k rollout status "sts/$1" --timeout=300s >/dev/null
  say "$1 start ($2): $(k get pod "$1-0" -o json | python3 -c '
import json,sys,datetime as d
p=json.load(sys.stdin); f=lambda s: d.datetime.strptime(s,"%Y-%m-%dT%H:%M:%SZ")
c=p["status"]["containerStatuses"][0]["state"]["running"]["startedAt"]
r=[x["lastTransitionTime"] for x in p["status"]["conditions"] if x["type"]=="Ready"][0]
print("container start to Ready %d s, pod created to Ready %d s (1 s clock, 2 s probe period)" % ((f(r)-f(c)).seconds, (f(r)-f(p["metadata"]["creationTimestamp"])).seconds))')"
}
stop() { k scale sts "$1" --replicas=0 >/dev/null; k wait --for=delete "pod/$1-0" --timeout=120s >/dev/null; }

say "test 4 started, control plane restart count $base"
for db in ${1:-minio rustfs}; do
  "$here/run.sh" cleanup >/dev/null
  until [ "$(kubectl get pv --no-headers 2>/dev/null | grep -c benchmark)" = 0 ]; do sleep 5; done
  start "$db" "empty new volume"
  sleep 600; usage "$db" "idle, empty, last 5 of 10 minutes" 300; guard
  stop "$db"
  out=$(LOADGEN_ENV="HOLD_STEPS=5 STOP_BELOW=0" RATE_START=100 RATE_STEP=0 RATE_MAX=100 "$here/run.sh" case 4k put "$db" 2>&1)
  say "$db 100 PUT/s for 5 min: $(echo "$out" | grep -o 'SUSTAINED.*\|DONE.*' | tail -1) | $(echo "$out" | grep -o 'loadgen CPU at peak.*page cache MiB [0-9.]*' | head -1) | errors $(echo "$out" | grep -o 'errors=[0-9]*' | cut -d= -f2 | paste -sd+ | bc)"
  t1=$(echo "$out" | grep -o -- '-> 20[0-9][0-9]-[^,]*' | head -1 | cut -c4-)
  say "$db 100 PUT/s: server CPU avg over the last 300 s $(vm "sum(rate(container_cpu_usage_seconds_total{job=\"cadvisor-benchmark\",namespace=\"$ns\",container=\"$db\"}[300s]))" "$t1") cores"
  guard
  out=$(KEYS=5000 LOADGEN_ENV="HOLD_STEPS=10 STOP_BELOW=0" RATE_START=1000 RATE_STEP=0 RATE_MAX=1000 "$here/run.sh" case 4k get "$db" 2>&1)
  say "$db 1000 GET/s for 5 min: $(echo "$out" | grep -o 'DONE.*' | tail -1) | $(echo "$out" | grep -o 'loadgen CPU at peak.*page cache MiB [0-9.]*' | head -1) | errors $(echo "$out" | grep -o 'errors=[0-9]*' | cut -d= -f2 | paste -sd+ | bc)"
  t1=$(echo "$out" | grep -o -- '-> 20[0-9][0-9]-[^,]*' | head -1 | cut -c4-)
  say "$db 1000 GET/s: server CPU avg over the last 300 s $(vm "sum(rate(container_cpu_usage_seconds_total{job=\"cadvisor-benchmark\",namespace=\"$ns\",container=\"$db\"}[300s]))" "$t1") cores"
  guard
  for i in 1 2 3; do start "$db" "restart $i, about 35,000 small objects on the volume"; stop "$db"; done
  start "$db" "for the idle measurement with data"; sleep 300; usage "$db" "idle with about 35,000 small objects, last 4 of 5 minutes" 240; guard; stop "$db"
done
