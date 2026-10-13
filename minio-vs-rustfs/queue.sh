#!/usr/bin/env bash
# Unattended, resumable runner for the test 1 matrix. Start it detached:
#
#   setsid nohup ./queue.sh run >/dev/null 2>&1 &
#   tail -f .queue/queue.log          progress (one line per case)
#   ./queue.sh list                   the plan, with the state of each case
#   touch .queue/STOP                 stop after the current case (then it scales everything to 0)
#   ./queue.sh stop                   stop now, also the running case (it still scales everything to 0)
#   DEADLINE="14:00 UTC" ...          cases that cannot finish by then are DEFERRED, not started
#
# Each case runs through run.sh, is checked against the validity rules, and ends
# as .queue/<id>.ok or .queue/<id>.invalid (with the reason on its first line).
# Re-running skips every .ok case; invalid ones are tried again, twice at most
# per start. A failed case never stops the queue. On every exit, wanted or
# not, it scales everything to 0. If a node is NotReady it waits five minutes,
# then gives up instead of benchmarking a sick cluster.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
q=$here/.queue; mkdir -p "$q"
say() { echo "$(date -u +%FT%TZ) $*" | tee -a "$q/queue.log"; }

# id|timeout|estimated minutes|ENV=... run.sh args.
# Every case in its final method (RESULTS.md, "Disk stalls"): 4 KiB writes ramp in 60 s steps, GET cases
# ramp in 30 s steps (60 s at 100 MiB), 1 MiB writes run 10 minutes of sustained closed-loop load instead
# of a ramp. The order reuses data sets: a GET case prefills its key space once, the mixed case reads it.
# My own runs were spread over three earlier versions of this plan; this merged one was not run as a whole.
# With DEADLINE set, a case that cannot finish in time is DEFERRED, not started.
plan() {
  local r db
  for db in minio rustfs; do echo "fio-$db|30m|4|fio $db"; done
  for db in minio rustfs; do
    # r1 prefills 500,000 keys: about 15 minutes for MinIO and 55 for RustFS on my disk
    for r in 1 2 3; do echo "4k-get-$db-r$r|3h|$([ $r = 1 ] && echo 70 || echo 12)|$([ $r = 1 ] && echo WIPE=1) case 4k get $db"; done
    for r in 1 2 3; do echo "4k-mixed-$db-s60-r$r|2h|12|case 4k mixed $db"; done
    echo "4k-get-hot20k-$db-r1|1h|9|KEYS=20000 case 4k get $db"
    for r in 1 2 3; do echo "4k-put-$db-s60-r$r|2h|19|WIPE=1 case 4k put $db"; done
  done
  # Durability: RustFS strict (the default, the runs above) against relaxed.
  for r in 1 2 3; do echo "4k-put-rustfs-relaxed-s60-r$r|2h|10|WIPE=1 RUSTFS_MODE=relaxed RATE_START=200 RATE_STEP=200 RATE_MAX=10000 case 4k put rustfs"; done
  # One flat prefix: a fixed overload for 12 min (MinIO) and 35 min (RustFS), about 400,000 objects each.
  echo "4k-put-flat-minio-r1|2h|22|WIPE=1 RATE_START=1500 RATE_STEP=1 RATE_MAX=100000 LOADGEN_ENV=KEYS_PER_PREFIX=0,STOP_BELOW=0,HOLD_STEPS=1 STEPS=24 case 4k put minio"
  echo "4k-put-flat-rustfs-r1|2h|44|WIPE=1 RATE_START=500 RATE_STEP=1 RATE_MAX=100000 LOADGEN_ENV=KEYS_PER_PREFIX=0,STOP_BELOW=0,HOLD_STEPS=1 STEPS=70 case 4k put rustfs"
  # Large reads: r1 wipes and prefills 20 GiB.
  for db in minio rustfs; do for r in 1 2 3; do echo "1m-get-$db-r$r|3h|$([ $r = 1 ] && echo 20 || echo 11)|$([ $r = 1 ] && echo WIPE=1) case 1m get $db"; done; done
  for db in minio rustfs; do for r in 1 2 3; do echo "100m-get-$db-r$r|3h|$([ $r = 1 ] && echo 20 || echo 14)|$([ $r = 1 ] && echo WIPE=1) case 100m get $db"; done; done
  # Large writes, sustained. I have one run each of 1m put and none of 1m mixed (RESULTS.md says why).
  # These write tens of GiB: read "Before you run it" in the README first. 100 MiB works the same way
  # (SUSTAIN=10 ./run.sh case 100m put) and is not in the plan.
  for r in 1 2 3; do for db in minio rustfs; do echo "1m-put-sustained-$db-r$r|1h|13|WIPE=1 SUSTAIN=10 case 1m put $db"; done; done
  for r in 1 2 3; do for db in minio rustfs; do echo "1m-mixed-sustained-$db-r$r|1h|$([ $r = 1 ] && echo 17 || echo 13)|$([ $r = 1 ] && echo WIPE=1) SUSTAIN=10 case 1m mixed $db"; done; done
  for db in minio rustfs; do echo "wipe-$db|30m|6|wipe $db"; done
}

healthy() { ! kubectl get nodes --no-headers 2>/dev/null | awk '$2!="Ready"{bad=1} END{exit !(bad||NR<3)}'; }

# Validity rules (RESULTS.md), from the case's own log. Prints the reason and fails if the run does not count.
validate() { # $1 id $2 log $3 exit code
  [ "$3" = 0 ] || { echo "run.sh exit code $3"; return 1; }
  case "$1" in fio-*|wipe-*) [ -s "$2" ] || { echo "no output"; return 1; }; return 0 ;; esac
  python3 - "$2" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
def bad(why): print(why); sys.exit(1)
if " DONE " not in t: bad("no DONE line")
m = re.search(r"loadgen CPU at peak (\S+) of 3.4, .*server restarts (\d+), servers up at once (\d+)", t)
if not m: bad("no summary line")
cpu, restarts, servers = m.groups()
if cpu == "nan": bad("loadgen CPU unknown (metrics query failed)")
if float(cpu) > 0.9 * 3.4: bad("loadgen CPU %s of 3.4 at the peak: client-bound" % cpu)
if restarts != "0": bad("server restarted %s times" % restarts)
if servers != "1": bad("%s servers were up at once" % servers)
if re.search(r"PREFILL .*errors=[1-9]", t): bad("prefill errors")
if "STALL-INVALID" in t: bad("disk stall decided the end of the ramp")
if " sustained:" in t:
    # closed loop on purpose: there is no knee, so every request must succeed and the summary must be there
    if "SUSTAINED mean" not in t: bad("no SUSTAINED line")
    errs = sum(int(e) for e in re.findall(r"STEP .*?errors=(\d+)", t))
    if errs: bad("%d request errors in a sustained run" % errs)
for target, ok, errors in re.findall(r"STEP target=(\S+) ok/s=(\S+) .*?errors=(\d+)", t):
    # past the knee a ramp to failure may time out; below it every request must succeed
    if float(ok) >= 0.9 * float(target) and int(errors): bad("%s errors at target %s, below the knee" % (errors, target))
PY
}

run_case() { # $1 id $2 timeout $3 "ENV=.. run.sh args"
  local id=$1 rc why t0 envs=() args=() w
  for w in $3; do
    case "$w" in
      LOADGEN_ENV=*) envs+=("LOADGEN_ENV=$(echo "${w#LOADGEN_ENV=}" | tr , ' ')") ;;
      STEPS=*) envs+=("RATE_MAX=$(( ${w#STEPS=} - 1 + $(echo "$3" | grep -o 'RATE_START=[0-9]*' | cut -d= -f2) ))") ;; # N steps of +1/s: a fixed rate for N steps
      *=*) envs+=("$w") ;;
      *) args+=("$w") ;;
    esac
  done
  t0=$(date +%s); say "START $id"
  env "${envs[@]}" CASE_ID="$id" timeout "$2" "$here/run.sh" "${args[@]}" >"$q/$id.log" 2>&1; rc=$?
  if why=$(validate "$id" "$q/$id.log" "$rc"); then
    mv "$q/$id.log" "$q/$id.ok"; rm -f "$q/$id.invalid"
    say "OK    $id ($(( ($(date +%s) - t0) / 60 )) min) $(grep -o 'DONE.*' "$q/$id.ok" | tail -1)"
  else
    { echo "INVALID: $why"; cat "$q/$id.log"; } >"$q/$id.invalid"; rm -f "$q/$id.log"
    say "INVALID $id ($(( ($(date +%s) - t0) / 60 )) min): $why"
    echo "INVALID $id: $why (see .queue/$id.invalid; not counted)" >>"$here/runs.log"
    "$here/run.sh" stop >/dev/null 2>&1
  fi
}

case "${1:-}" in
  list)
    plan | while IFS='|' read -r id to est cmd; do
      st=todo; [ -f "$q/$id.deferred" ] && st=DEFERRED; [ -f "$q/$id.invalid" ] && st=INVALID; [ -f "$q/$id.ok" ] && st=ok
      printf '%-8s %-28s %3s min  %s\n' "$st" "$id" "$est" "$cmd"
    done
    echo "left to run: $(plan | while IFS='|' read -r id to est cmd; do [ -f "$q/$id.ok" ] || echo "$est"; done | paste -sd+ | bc) min estimated" ;;
  run)
    echo $$ >"$q/pid"; rm -f "$q/STOP"
    restore() {
      say "stopping: everything to 0"
      "$here/run.sh" stop >>"$q/queue.log" 2>&1
      say "END. $(ls "$q" | grep -c '\.ok$') ok, $(ls "$q" | grep -c '\.invalid$') invalid of $(plan | wc -l)"
      rm -f "$q/pid"
    }
    trap restore EXIT; trap 'exit 143' TERM INT HUP
    say "queue started, pid $$"
    for pass in 1 2 3; do
      while IFS='|' read -r id to est cmd <&3; do
        [ -f "$q/$id.ok" ] && continue
        # DEADLINE (UTC, anything `date -d` reads): what cannot finish by then waits for a later session.
        # The two wipes at the end always run.
        if [ -n "${DEADLINE:-}" ] && [ "${id#wipe-}" = "$id" ] && [ $(( $(date +%s) + est * 60 )) -gt "$(date -ud "$DEADLINE" +%s)" ]; then
          [ -f "$q/$id.deferred" ] || { say "DEFERRED $id (needs about $est min, deadline $DEADLINE)"; touch "$q/$id.deferred"; }
          continue
        fi
        rm -f "$q/$id.deferred"
        [ ! -f "$q/STOP" ] || { say "STOP file found"; exit 0; }
        healthy || { say "a node is not Ready, waiting 5 min"; sleep 300; healthy || { say "cluster unhealthy: giving up"; exit 1; }; }
        run_case "$id" "$to" "$cmd"
      done 3< <(plan)
      [ -n "$(ls "$q" | grep '\.invalid$')" ] || break
      [ ! -f "$q/STOP" ] || break
      say "pass $pass done, invalid cases get another try"
    done ;;
  stop)
    # bash runs a trap only after its foreground child ends, so the running case goes first.
    pkill -TERM -P "$(pgrep -P "$(cat "$q/pid")" timeout)" 2>/dev/null; kill -TERM "$(cat "$q/pid")" ;;
  *) sed -n 2,16p "$0"; exit 1 ;;
esac
