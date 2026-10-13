#!/usr/bin/env bash
# Test 2, small: three pods (one per node, two 5 GiB drives each) of one contender, a node "dies".
#   test2.sh up <minio|rustfs>      deploy and wait until all three pods are ready
#   test2.sh rate <minio|rustfs>    60 s of the steady load at RATE: does the cluster hold it (no dropped slot)?
#   test2.sh run <minio|rustfs>     verify-write 2,000 objects (SHA-256 by seed), steady light load
#                                   (RATE requests/s of 4 KiB, 80% GET; default 100), after 2 min cordon one
#                                   node and delete its pod, write 500 more objects into a second bucket
#                                   while it is gone, 3 min later uncordon, watch those 500 appear on the
#                                   returned pod's own drives (healing), then verify every object of both sets
#   test2.sh smoke <minio|rustfs>   20 objects written and read back
#   test2.sh down <minio|rustfs>    remove everything, volumes included
# RATE=250 was my first run: more than three-pod RustFS takes on my disk (RESULTS.md). Check with `rate` first.
# NODE is the node to lose. It must not be the clients node (the verify jobs start there while NODE is
# cordoned). Default: the first node that does not carry bench-role=clients.
# STORAGE_CLASS pins the StorageClass of the drives (default: your cluster's default class).
# TOOLS_IMAGE is the warp + fio image built from images/tools (the healing probe only needs its shell).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); ns=benchmark; db=${2:?contender: minio or rustfs}; rate=${RATE:-100}
node=${NODE:-$(kubectl get nodes -l 'bench-role!=clients' -o jsonpath='{.items[0].metadata.name}')}
sc=${STORAGE_CLASS:+storageClassName: $STORAGE_CLASS, }
tools=${TOOLS_IMAGE:-your-registry.example.com/s3-bench-tools:warp-1.8.2}
lg=$(awk '$1 == "image:" { print $2; exit }' "$here/manifests/loadgen.yaml")
k() { kubectl -n "$ns" "$@"; }
now() { date -u +%FT%TZ; }
log() { echo "$*" | tee -a "$here/runs.log"; }
dns="$db-dist-{0...2}.$db-dist.$ns.svc.cluster.local:9000"
cred() { echo "{ name: $1, valueFrom: { secretKeyRef: { name: s3-bench-creds, key: $2 } } }"; }
if [ "$db" = minio ]; then
  image=$(awk '$1 == "image:" { print $2; exit }' "$here/manifests/minio.yaml")
  spec="args: [server, 'http://$dns/data{0...1}', --address, ':9000']
          env: [$(cred MINIO_ROOT_USER access-key), $(cred MINIO_ROOT_PASSWORD secret-key), { name: MINIO_UPDATE, value: 'off' }]
          readinessProbe: { httpGet: { path: /minio/health/live, port: 9000 }, periodSeconds: 2 }
          volumeMounts: [{ name: data0, mountPath: /data0 }, { name: data1, mountPath: /data1 }]"
else
  image=$(awk '$1 == "image:" { print $2; exit }' "$here/manifests/rustfs.yaml")
  spec="env: [$(cred RUSTFS_ACCESS_KEY access-key), $(cred RUSTFS_SECRET_KEY secret-key), { name: RUSTFS_ADDRESS, value: ':9000' }, { name: RUSTFS_VOLUMES, value: 'http://$dns/data/rustfs{0...1}' }]
          readinessProbe: { httpGet: { path: /health/ready, port: 9000 }, periodSeconds: 2 }
          volumeMounts: [{ name: data0, mountPath: /data/rustfs0 }, { name: data1, mountPath: /data/rustfs1 }, { name: logs, mountPath: /logs }]"
fi
client() { # $1 kind (Deployment|Job) $2 name, rest NAME=value env for the loadgen
  local kind=$1 name=$2 envs; shift 2
  envs=$(printf '{ name: %s, value: "%s" }, ' $(printf '%s\n' "$@" | sed 's/=/ /'))
  cat <<Y | k apply -f - >/dev/null
apiVersion: $([ "$kind" = Job ] && echo batch/v1 || echo apps/v1)
kind: $kind
metadata: { name: $name, labels: { bench: test2 } }
spec:
  $([ "$kind" = Job ] && echo "backoffLimit: 0" || echo "selector: { matchLabels: { app: $name } }")
  template:
    metadata: { labels: { app: $name, bench: test2 } }
    spec:
      restartPolicy: $([ "$kind" = Job ] && echo Never || echo Always)
      nodeSelector: { bench-role: clients }
      containers:
        - name: loadgen
          image: $lg
          env: [$envs { name: DB, value: $db }, { name: ENDPOINT, value: "http://$db-dist-lb.$ns.svc.cluster.local:9000" }, $(cred ACCESS_KEY access-key), $(cred SECRET_KEY secret-key)]
          ports: [{ name: metrics, containerPort: 9090 }]
          resources: { requests: { cpu: 500m, memory: 512Mi }, limits: { cpu: 500m, memory: 512Mi } }
Y
}
case "$1" in
  up)
    k get secret s3-bench-creds >/dev/null 2>&1 || k create secret generic s3-bench-creds --from-literal=access-key="bench$(openssl rand -hex 6)" --from-literal=secret-key="$(openssl rand -hex 20)" >/dev/null
    cat <<Y | k apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata: { name: $db-dist, labels: { bench: test2 } }
spec: { clusterIP: None, publishNotReadyAddresses: true, selector: { app: $db-dist }, ports: [{ name: s3, port: 9000 }] }
---
apiVersion: v1
kind: Service
metadata: { name: $db-dist-lb, labels: { bench: test2 } }
spec: { selector: { app: $db-dist }, ports: [{ name: s3, port: 9000 }] }
---
apiVersion: apps/v1
kind: StatefulSet
metadata: { name: $db-dist, labels: { bench: test2 } }
spec:
  serviceName: $db-dist
  replicas: 3
  podManagementPolicy: Parallel
  selector: { matchLabels: { app: $db-dist } }
  template:
    metadata: { labels: { app: $db-dist, bench: test2 } }
    spec:
      affinity: { podAntiAffinity: { requiredDuringSchedulingIgnoredDuringExecution: [{ topologyKey: kubernetes.io/hostname, labelSelector: { matchLabels: { app: $db-dist } } }] } }
      securityContext: { runAsUser: 10001, runAsGroup: 10001, fsGroup: 10001, fsGroupChangePolicy: OnRootMismatch }
      containers:
        - name: $db
          image: $image
          ports: [{ name: s3, containerPort: 9000 }]
          resources: { requests: { cpu: "1", memory: 1Gi }, limits: { cpu: "1", memory: 1Gi } }
          $spec
      volumes: [{ name: logs, emptyDir: {} }]
  volumeClaimTemplates:
    - { metadata: { name: data0 }, spec: { accessModes: [ReadWriteOnce], ${sc}resources: { requests: { storage: 5Gi } } } }
    - { metadata: { name: data1 }, spec: { accessModes: [ReadWriteOnce], ${sc}resources: { requests: { storage: 5Gi } } } }
Y
    k rollout status "sts/$db-dist" --timeout=420s | tail -1
    k get pods -l "app=$db-dist" -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,QOS:.status.qosClass' --no-headers ;;
  rate)
    k delete deploy loadgen-t2 --ignore-not-found >/dev/null; k wait --for=delete pod -l app=loadgen-t2 --timeout=60s >/dev/null 2>&1 || true
    client Deployment loadgen-t2 OP=mixed GET_SHARE=0.8 OBJECT_SIZE=4096 KEYS=2000 PREFILL=true WORKERS=32 RATE_START="$rate" RATE_STEP=0 RATE_MAX="$rate" STEP_SECONDS=10 HOLD_STEPS=6 STOP_BELOW=0 OP_TIMEOUT_SECONDS=30
    k rollout status deploy/loadgen-t2 --timeout=180s >/dev/null
    until k logs deploy/loadgen-t2 2>/dev/null | grep -c ' DONE ' >/dev/null; do sleep 5; done
    log "test2 rate check $db at $rate requests/s (60 s, all three pods up):"
    k logs deploy/loadgen-t2 | grep -E 'PREFILL|STEP' | sed 's/^/  /' | tee -a "$here/runs.log"
    k delete deploy loadgen-t2 >/dev/null ;;
  run)
    art="$here/.queue/artifacts/test2-$db-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$art"
    victim=$(k get pods -l "app=$db-dist" --field-selector "spec.nodeName=$node" -o jsonpath='{.items[0].metadata.name}')
    log "test2 $db at $rate requests/s: started $(now); 3 pods x 2 drives, node to lose: the one running $victim"
    k delete job t2-verify-write t2-verify-check t2-heal-write t2-heal-check t2-heal-probe --ignore-not-found >/dev/null
    k delete deploy loadgen-t2 --ignore-not-found >/dev/null; k wait --for=delete pod -l app=loadgen-t2 --timeout=60s >/dev/null 2>&1 || true
    vjob() { # $1 job name, rest env: run a verify job to its end and log its result line
      local name=$1; shift; client Job "$name" "$@" WORKERS=16
      until k get job "$name" -o jsonpath='{.status.conditions[?(@.status=="True")].type}' | grep -qE 'Complete|Failed'; do sleep 3; done
      log "  $name: $(k logs "job/$name" | grep -E 'VERIFY|BAD' | sed 's/^[0-9/]* [0-9:]* //' | tail -3 | paste -sd'|')"
      k logs "job/$name" > "$art/$name.log" 2>&1 || true
    }
    vjob t2-verify-write OP=verify-write KEYS=2000 VERIFY_SIZES=4096,65536,262144,1048576
    # Healing probe: a pod on the same node with the two drives of the pod that will be lost. Every 5 s it
    # counts the objects of the second set (bucket "heal", written while the pod is gone) on each drive.
    cat <<Y | k apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata: { name: t2-heal-probe, labels: { bench: test2 } }
spec:
  backoffLimit: 0
  template:
    metadata: { labels: { bench: test2 } }
    spec:
      restartPolicy: Never
      nodeName: $node
      securityContext: { runAsUser: 10001, runAsGroup: 10001, fsGroup: 10001, fsGroupChangePolicy: OnRootMismatch }
      containers:
        - name: tool
          image: $tools
          command: [sh, -c, 'i=0; while [ \$i -lt 200 ]; do echo "HEAL \$(date +%s) \$(ls /d0/heal/verify 2>/dev/null | wc -l) \$(ls /d1/heal/verify 2>/dev/null | wc -l)"; sleep 5; i=\$((i+1)); done']
          resources: { requests: { cpu: 10m, memory: 32Mi }, limits: { cpu: 100m, memory: 64Mi } }
          volumeMounts: [{ name: d0, mountPath: /d0, readOnly: true }, { name: d1, mountPath: /d1, readOnly: true }]
      volumes: [{ name: d0, persistentVolumeClaim: { claimName: data0-$victim } }, { name: d1, persistentVolumeClaim: { claimName: data1-$victim } }]
Y
    # 9 minutes at the steady rate in 10 s steps: 2 min before, 3 min without the pod, 4 min after
    client Deployment loadgen-t2 OP=mixed GET_SHARE=0.8 OBJECT_SIZE=4096 KEYS=2000 PREFILL=true WORKERS=32 RATE_START="$rate" RATE_STEP=0 RATE_MAX="$rate" STEP_SECONDS=10 HOLD_STEPS=54 STOP_BELOW=0 OP_TIMEOUT_SECONDS=30
    k rollout status deploy/loadgen-t2 --timeout=180s >/dev/null
    until k logs deploy/loadgen-t2 2>/dev/null | grep -c ' STEP ' >/dev/null; do sleep 2; done
    sleep 110
    kubectl cordon "$node" >/dev/null; k delete pod "$victim" --wait=false >/dev/null; tk=$(now); log "  $tk node cordoned, pod $victim deleted"
    sleep 30
    vjob t2-heal-write OP=verify-write BUCKET=heal KEYS=500 VERIFY_SIZES=4096,65536,262144
    sleep $(( 180 - ($(date +%s) - $(date -d "$tk" +%s)) ))
    kubectl uncordon "$node" >/dev/null; tu=$(now); log "  $tu node uncordoned"
    k wait --for=condition=Ready "pod/$victim" --timeout=300s >/dev/null && tr=$(now) && log "  $tr pod $victim Ready again, $(( $(date -d "$tr" +%s) - $(date -d "$tu" +%s) )) s after the uncordon"
    until k logs deploy/loadgen-t2 2>/dev/null | grep -c ' DONE ' >/dev/null; do sleep 10; done
    k logs deploy/loadgen-t2 > "$art/loadgen.log"
    grep -E 'PREFILL|STEP|DONE' "$art/loadgen.log" | sed 's/^/  /' >> "$here/runs.log"
    python3 - "$art/loadgen.log" "$tk" "$tu" <<'PY' | tee -a "$here/runs.log"
import calendar, re, sys, time
ts = lambda s, f: calendar.timegm(time.strptime(s, f))
kill, unc = (ts(x, "%Y-%m-%dT%H:%M:%SZ") for x in sys.argv[2:4])
rows = [(ts(m.group(1), "%Y/%m/%d %H:%M:%S"), float(m.group(2)), int(m.group(3)), int(m.group(4)), float(m.group(5)), float(m.group(6)))
        for m in re.finditer(r"(\S+ \S+) STEP target=\S+ ok/s=(\S+) MiB/s=\S+ errors=(\d+) dropped=(\d+) p50=(\S+)ms p99=(\S+)ms", open(sys.argv[1]).read())]
def part(name, a, b):
    r = [x for x in rows if a < x[0] <= b]
    if r: print("  %-22s %3d s: ok/s mean %.0f, errors %d, dropped %d, median p50 %.0f ms, worst p99 %.0f ms" % (name, 10 * len(r), sum(x[1] for x in r) / len(r), sum(x[2] for x in r), sum(x[3] for x in r), sorted(x[4] for x in r)[len(r) // 2], max(x[5] for x in r)))
part("before the kill", 0, kill); part("pod gone", kill, unc + 9); part("after the uncordon", unc + 9, 9e12)
bad = [x for x in rows if x[2] or x[3] or x[5] > 1000]
print("  steps with errors, drops or p99 over 1 s: %s" % (", ".join("%+d s (%d errors, %d dropped, p99 %.0f ms)" % (x[0] - kill, x[2], x[3], x[5]) for x in bad) or "none"), "(seconds after the kill, 10 s steps)")
PY
    heal() { # the probe's log against the uncordon time
      k logs job/t2-heal-probe > "$art/heal-probe.log" 2>&1 || true
      python3 - "$art/heal-probe.log" "$tu" "$1" <<'PY' | tee -a "$here/runs.log"
import calendar, sys, time
unc = calendar.timegm(time.strptime(sys.argv[2], "%Y-%m-%dT%H:%M:%SZ"))
rows = [tuple(int(x) for x in l.split()[1:4]) for l in open(sys.argv[1]) if l.startswith("HEAL ")]
if not rows: print("  healing: the probe has no samples"); sys.exit()
full = [t for t, a, b in rows if a >= 500 and b >= 500]
at = lambda s: min(rows, key=lambda r: abs(r[0] - unc - s))
print("  healing (%s): objects of the 500 written during the outage on the returned pod's drives: at the uncordon %d and %d, +30 s %d and %d, +60 s %d and %d, +120 s %d and %d, last sample (+%d s) %d and %d; %s"
      % (sys.argv[3], *at(0)[1:], *at(30)[1:], *at(60)[1:], *at(120)[1:], rows[-1][0] - unc, *rows[-1][1:],
         "all 500 on both drives %d s after the uncordon" % (full[0] - unc) if full else "NOT complete in this window"))
PY
    }
    heal "under load, before any verify read"
    for p in 0 1 2; do k logs "$db-dist-$p" > "$art/server-$p.log" 2>&1 || true; done
    k scale deploy loadgen-t2 --replicas=0 >/dev/null
    vjob t2-verify-check OP=verify-check KEYS=2000 VERIFY_SIZES=4096,65536,262144,1048576
    vjob t2-heal-check OP=verify-check BUCKET=heal KEYS=500 VERIFY_SIZES=4096,65536,262144
    sleep 20; heal "after every object was read once"
    log "  test2 $db ended $(now); artifacts: ${art#"$here"/}" ;;
  smoke) # 20 objects written and read back: does the cluster take writes at all
    for m in write check; do
      k delete job "t2-verify-$m" --ignore-not-found >/dev/null
      client Job "t2-verify-$m" "OP=verify-$m" KEYS=20 VERIFY_SIZES=4096,1048576 WORKERS=4
      until k get job "t2-verify-$m" -o jsonpath='{.status.conditions[?(@.status=="True")].type}' | grep -qE 'Complete|Failed'; do sleep 3; done
      k logs "job/t2-verify-$m" | grep -E 'VERIFY|BAD|waiting' | tail -2
    done; k delete job t2-verify-write t2-verify-check >/dev/null ;;
  down)
    kubectl uncordon "$node" >/dev/null 2>&1 || true
    k delete deploy,job,sts,svc -l bench=test2 --ignore-not-found >/dev/null
    k wait --for=delete pod -l bench=test2 --timeout=180s >/dev/null 2>&1 || true
    for pvc in $(k get pvc -o name | grep -E "data[01]-$db-dist-" || true); do
      pv=$(k get "$pvc" -o jsonpath='{.spec.volumeName}'); [ -z "$pv" ] || kubectl patch pv "$pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' >/dev/null
      k delete "$pvc" >/dev/null
    done
    echo "test2 $db removed" ;;
esac
