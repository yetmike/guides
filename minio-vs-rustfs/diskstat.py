#!/usr/bin/env python3
"""stdin: the loadgen's PREFILL/STEP/DONE lines and the probe's PROBE lines. stdout: the same
loadgen lines, one DISK line (what the volume did during the ramp, per successful operation) and
one STALL line (a ramp) or one SUSTAINED line. usage: diskstat.py <step seconds> [sustained]

Disk stalls: the shared SSD of my lab freezes for 20 to 40 s every few minutes (average device
latency per request jumps from 3..13 ms to 20..80 ms). A step is "stalled" when its worst 10 s
sample is above 20 ms and more than 1.5x the worst sample of the last normal step, plus 1 ms. A stall in the
middle of a ramp only dents that step. A stall on the steps that end the ramp can end it early,
so the run does not count (STALL-INVALID) unless a step that was not stalled itself showed
saturation: achieved under 97% of the target. (Until 2026-10-13 11:40 UTC the step after a stalled
one did not count either; a stall that runs on shows in that step's own samples, so that was dropped.)"""
import calendar, re, sys, time

step = float(sys.argv[1])
steps, probes = [], []
for line in sys.stdin:
    line = line.rstrip()
    if line.startswith("PROBEINFO"):
        print(line)
        continue
    if line.startswith("PROBE"):
        f = line.split()
        # f[2:] = /sys/block/<dev>/stat: 0 reads, 3 read ms, 4 writes, 7 write ms, 15 flushes; last = node Cached kB
        st = [int(x) for x in f[2:]]
        probes.append((int(f[1]), st[0], st[4], st[15] if len(st) > 16 else 0, st[-1], st[3] + st[7]))
        continue
    print(line)
    m = re.match(r"(\d+/\d+/\d+ \d+:\d+:\d+) STEP target=(\S+) ok/s=(\S+)", line)
    if m:
        steps.append((calendar.timegm(time.strptime(m.group(1), "%Y/%m/%d %H:%M:%S")), float(m.group(3)), float(m.group(2))))
if not steps or len(probes) < 2:
    sys.exit(0)
at = lambda t: min(probes, key=lambda p: abs(p[0] - t))
a, b, c = at(steps[0][0] - step), at(steps[-1][0]), at(steps[-1][0] - step)
ok = max(sum(s[1] for s in steps) * step, 1)
print("DISK during the ramp: %d flushes, %d writes, %d reads; per ok op: %.2f flushes, %.2f writes, %.2f reads; "
      "last step: %.0f flushes/s; node page cache %.1f -> %.1f GiB"
      % (b[3] - a[3], b[2] - a[2], b[1] - a[1], (b[3] - a[3]) / ok, (b[2] - a[2]) / ok, (b[1] - a[1]) / ok,
         (b[3] - c[3]) / max(b[0] - c[0], 1), a[4] / 1048576, b[4] / 1048576))

if sys.argv[2:] == ["sustained"]:
    # no ramp to judge: the mean over the whole run, and how much of it the volume spent stalled
    # (a 10 s sample counts as stalled above 4x the run's median device latency, 25 ms at least)
    lat = sorted((q[5] - p[5]) / (q[1] + q[2] - p[1] - p[2]) for p, q in zip(probes, probes[1:])
                 if steps[0][0] - step <= p[0] < steps[-1][0] and q[1] + q[2] - p[1] - p[2] >= 50)
    cut = max(25, 4 * lat[len(lat) // 2]) if lat else 0
    rates = [s[1] for s in steps]
    print("SUSTAINED mean ok/s=%.2f over %d steps of %g s (lowest step %.2f, highest %.2f); volume stalled %d%% of the time "
          "(%d of %d samples above %.0f ms)" % (sum(rates) / len(rates), len(rates), step, min(rates), max(rates),
          100 * sum(x > cut for x in lat) / max(len(lat), 1), sum(x > cut for x in lat), len(lat), cut))
    sys.exit(0)

# worst 10 s sample of device latency (ms per request) in each step; samples with under 50 requests say nothing
worst = []
for t, _, _ in steps:
    lat = [(q[5] - p[5]) / (q[1] + q[2] - p[1] - p[2]) for p, q in zip(probes, probes[1:])
           if t - step <= p[0] < t and q[1] + q[2] - p[1] - p[2] >= 50]
    worst.append(max(lat) if lat else None)
known = [w for w in worst if w is not None]
normal = min(known) if known else 0
stalled = []
for w in worst:
    s = w is not None and w > max(20, 1.5 * normal + 1)  # 20 ms floor: at the knee 10 to 14 ms is load, not a stall
    stalled.append(s)
    if w is not None and not s:
        normal = w
low = [s[1] < 0.9 * s[2] for s in steps]
ending = []  # the streak of low steps that ended the ramp
for i in range(len(steps) - 1, -1, -1):
    if not low[i]:
        break
    ending.append(i)
saturated = any(not stalled[i] and steps[i][1] < 0.97 * steps[i][2] for i in range(len(steps)))
verdict = "STALL-INVALID: the ramp ended on a stalled step and no clean step showed saturation" \
    if any(stalled[i] for i in ending) and not saturated else "does not decide the result"
print("STALL steps (target: worst 10 s device ms): %s; %s"
      % (", ".join("%g: %.0f" % (steps[i][2], worst[i]) for i in range(len(steps)) if stalled[i]) or "none", verdict))
