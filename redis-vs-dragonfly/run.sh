#!/usr/bin/env bash
# Redis vs Dragonfly. Tests:
#   test1  Redis 1 CPU              vs Dragonfly 1 thread / 1 CPU
#   test2  Redis Cluster 3 x 950m   vs Dragonfly 3 threads / 2850m
#   test3  Redis io-threads 3 2850m vs Dragonfly 3 threads / 2850m
#   restart  new ramp against whatever is up      stop  everything to 0
# ONLY=redis|dragonfly runs a single load generator: at PIPELINE=16 both
# together saturate the client node's kernel networking before either DB, so
# depth-16 tests run the contenders back to back.
# Each test: 512 B values, 100k keys, 20 s TTL, SET then GET, rate +2000 it/s
# every 30 s from RATE_START. PIPELINE=1 (default) is one round trip per op,
# capped near 35k rps by the lab's cross-VM path; PIPELINE=16 reaches server
# saturation. The published numbers: each test at both depths, depth 16 twice
# (median, see README.md).
set -euo pipefail
ns=benchmark
k() { kubectl -n "$ns" "$@"; }
ready() { k rollout status "$1" --timeout=180s >/dev/null; }
down() { k scale sts redis redis-cluster redis-iothreads dragonfly --replicas=0 >/dev/null; k scale deploy loadgen-redis loadgen-dragonfly --replicas=0 >/dev/null; }

# $1 DB label, $2 addrs, $3 rate start, $4 rate max
load() {
  p=${PIPELINE:-1}; start=$3; max=$(( $4 * p )); stepr=$(( 2000 * (p > 1 ? p / 4 : 1) ))
  k set env deploy/loadgen-redis DB="$1" ADDRS="$2" PIPELINE="$p" RATE_START="$start" RATE_STEP="$stepr" RATE_MAX="$max" WORKERS=256 >/dev/null
  k set env deploy/loadgen-dragonfly PIPELINE="$p" RATE_START="$start" RATE_STEP="$stepr" RATE_MAX="$max" WORKERS=256 >/dev/null
  case "${ONLY:-both}" in
    redis)     k scale deploy loadgen-redis --replicas=1 >/dev/null; k scale deploy loadgen-dragonfly --replicas=0 >/dev/null ;;
    dragonfly) k scale deploy loadgen-dragonfly --replicas=1 >/dev/null; k scale deploy loadgen-redis --replicas=0 >/dev/null ;;
    *)         k scale deploy loadgen-redis loadgen-dragonfly --replicas=1 >/dev/null ;;
  esac
  echo "ramp started $(date -u +%FT%TZ): ${ONLY:-$1 vs dragonfly}, pipeline $p, $start -> $max it/s"
}
# $1 threads, $2 cpu. Dragonfly wants 256 MiB maxmemory per thread.
dragonfly() {
  mm=$(( $1 * 256 )); ml=$(( mm + 256 ))
  k patch sts dragonfly --type=json -p "[
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/0\",\"value\":\"--proactor_threads=$1\"},
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/1\",\"value\":\"--maxmemory=${mm}mb\"},
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources\",\"value\":{\"requests\":{\"cpu\":\"$2\",\"memory\":\"${ml}Mi\"},\"limits\":{\"cpu\":\"$2\",\"memory\":\"${ml}Mi\"}}}]" >/dev/null
  k scale sts dragonfly --replicas=1 >/dev/null; ready sts/dragonfly
  k logs dragonfly-0 | grep -E 'io threads|epoll' | tail -2
}

case "${1:-}" in
  test1)
    down; k scale sts redis --replicas=1 >/dev/null; ready sts/redis; dragonfly 1 1
    load redis redis-0.redis.$ns.svc.cluster.local:6379 10000 150000 ;;
  test2)
    down; k scale sts redis-cluster --replicas=3 >/dev/null; ready sts/redis-cluster
    hosts=""; for i in 0 1 2; do hosts+="redis-cluster-$i.redis-cluster.$ns.svc.cluster.local:6379 "; done
    k exec redis-cluster-0 -- sh -c "redis-cli cluster info | grep -q cluster_state:ok || redis-cli --cluster create $hosts --cluster-replicas 0 --cluster-yes" >/dev/null
    dragonfly 3 2850m; hosts=${hosts% }
    load redis-cluster "${hosts// /,}" 20000 400000 ;;
  test3)
    down; k scale sts redis-iothreads --replicas=1 >/dev/null; ready sts/redis-iothreads; dragonfly 3 2850m
    load redis-iothreads redis-iothreads-0.redis-iothreads.$ns.svc.cluster.local:6379 20000 400000 ;;
  restart) k rollout restart deploy loadgen-redis loadgen-dragonfly >/dev/null; echo "ramp restarted $(date -Is)" ;;
  stop) down; echo stopped ;;
  *) sed -n 2,6p "$0"; exit 1 ;;
esac
