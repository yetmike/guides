# MinIO vs RustFS, results

All runs are from 2026-10-12 and 2026-10-13. MinIO `RELEASE.2025-10-15T17-29-55Z` (built from source, default
durability) against RustFS 1.0.1 (default `strict` durability unless a row says `relaxed`).

Test 1 setup: one pod each, 3 CPU / 3 GiB (requests == limits), one 30 GiB ext4 volume each, both on the same
node, one at a time, a fresh server process for every case. Load generator 0.3.0 (`loadgen/`), open-loop ramp.
"Peak" is the best step of the ramp in objects per second.

The rule is three valid runs and the median. Where a case has fewer, the table says so.
The raw logs are not published: they contain the node names of my cluster. Every number below is copied from them.

**Read this first:** the lab is three VMs on one host, and every volume sits on the same consumer SSD.
Compare ratios and curve shapes. The absolute numbers do not transfer to other hardware.

## Test 1: speed on one node

| case | MinIO | RustFS | ratio |
|---|---|---|---|
| 4 KiB PUT | **median 650** (570, 650, 730) | **median 177** (156, 182, 177) | MinIO 3.7x |
| 4 KiB PUT, RustFS `relaxed` | | **median 860** (689, 860, 882) | 4.9x its own strict, 1.3x MinIO |
| 4 KiB mixed 70% GET / 30% PUT | **median 1,152** (1,133, 1,154, 1,152) | **median 683** (665, 683, 697) | MinIO 1.7x |
| 4 KiB GET, 500k keys, not cacheable | **median 3,796** (3,685, 3,796, 3,829) | **median 4,989** (4,987, 4,991, 4,968, 5,130) | RustFS 1.3x |
| 4 KiB GET, 20k keys, cached | **median 5,819** (5,615, 5,819, 5,853) | **median 6,493** (6,493, 6,498, 6,480) | RustFS 1.1x |
| 1 MiB GET, 20 GiB | **median 624** (634, 602, 624) | **median 613** (604, 625, 613) | tie, a lab limit |
| 100 MiB GET, 20 GiB | **median 8.9** = 890 MiB/s (8.1, 9.0, 8.9) | **median 8.2** = 820 MiB/s (8.3, 8.1, 8.2) | tie, a lab limit |
| 1 MiB PUT, sustained | **one run only**: 136 MiB/s (5 min, new volume, no stall) | **one run only**: 72 MiB/s (10 min, used volume, stalled 27% of the time) | **not comparable**, see below |
| 1 MiB mixed, 100 MiB PUT and mixed | **no valid run** | **no valid run** | missing |
| 4 KiB PUT, one flat prefix | one run: about 600 for 12 min | one run: about 190 for 35 min | no cliff |

Three valid runs or more in every row that shows a median. 4 KiB PUT, mixed and `relaxed` are ramps with 60 s
steps, all run on 2026-10-13 between 09:26 and 11:54 UTC. An earlier series with 30 s steps agrees with it:
PUT MinIO 629, 550, 580 and RustFS 165, 160, 156 (ratio 3.6x); mixed MinIO 1,224, 1,299 and RustFS 640, 643,
688; relaxed 729, 837.

### Reading

- **Small writes: MinIO is 3.7x faster than RustFS in its default mode on this disk**, and 1.7x on the mixed
  load. Server CPU is far from the limit on both (0.4 to 0.8 of 3 cores at the PUT peak), so this is the cost
  of synced writes: the volume saw 2.0 writes per PUT with MinIO, 3.7 to 4.1 with RustFS `strict`, 0.7 with
  `relaxed`. At 100 PUT/s the median latency was 21 ms (MinIO), 92 ms (RustFS strict), 5 ms (RustFS relaxed).
  The two defaults do not promise the same thing (README, "Durability settings"): RustFS `strict` also makes
  the directory entry durable before it answers.
- **RustFS `relaxed` is 1.3x faster than MinIO's default** and 4.9x faster than its own default. `relaxed`
  does not sync small objects at all. The vendor's "twice as fast at 4 KiB" claim holds here only in that mode.
- **Small reads: RustFS is 1.3x faster** when the data set does not fit in memory (1.6 device reads per GET for
  both), and still ahead on a cached data set. Below the knee, at 3,000 GET/s, p99 was 76 ms (MinIO) against
  9 ms (RustFS).
- **Large reads are a tie that the lab decides.** At 1 MiB and 100 MiB both stop at the same 610 to 890 MiB/s
  with CPU to spare on the client (0.4 to 1.2 of 3 cores) and on the server (1.1 to 2.4). The limit is the
  virtual network or disk path. What differs: for the same 100 MiB traffic MinIO used about 1.2 cores and
  RustFS about 1.7.
- **Large writes: no fair comparison.** There is one sustained 1 MiB PUT run each, and they did not meet the
  same disk. RustFS ran on a volume that had been in use for 15 hours, and the volume stalled 27% of the time
  (72 MiB/s over 10 minutes, 74 over the first 5). MinIO ran later on a newly created volume and saw no stall
  at all in 5 minutes and 41 GiB (136 MiB/s, steps between 123 and 155). So the stalls may belong to an aged
  volume, and 136 against 72 says nothing about the servers. The only like-for-like large-write evidence is
  the bulk loads below (one run each, both on used volumes): MinIO ahead by about 1.3x. No 100 MiB write ramps
  or sustained runs exist, by decision.
- The cached RustFS runs all peak on the 6,500 step and fail on the 7,000 step, so "about 6,500" is as fine as
  the 500 per step ramp resolves.
- The disk decides the size of every write number: one writer gets 140 synced writes per second from it, 64
  writers together 3,800 (fio). On an SSD with power-loss protection the numbers, and maybe the ratio, change.

### Bulk loads (prefill: closed loop, as fast as the server takes it, stalls included, one run each)

| data set | MinIO | RustFS strict |
|---|---|---|
| 4 KiB x 980,000 (64 writers) | 547 obj/s | 155 obj/s |
| 1 MiB x 20,000 = 20 GiB (32 writers) | 111 MiB/s | 83 MiB/s |
| 100 MiB x 200 = 20 GiB, multipart (8 writers x 4 parts) | 155 MiB/s | 119 MiB/s |

A 4 KiB object costs 12 KiB and 2 inodes on disk on both servers. The 30 GiB ext4 volume has 1.97M inodes, so
it holds at most about 980,000 such objects: MinIO's first prefill of 1M keys failed there. That is why the
4 KiB GET data set is 500,000 keys.

## How to read the load generator: open loop, with a 2 s cap

The load generator asks for a fixed rate and raises it step by step. Latency is measured from the moment a
request was scheduled, not from the moment a worker got free, so a server that falls behind shows as latency.

A request that cannot start within 2 s of its slot is **dropped** and counted (`dropped=` in the log,
`status="dropped"` in the metrics). So past the limit "achieved" falls below "target", and measured latency
cannot grow far beyond 2 s plus the request itself. A p99 near 2.5 s with many dropped slots means "over the
limit", not "2.5 s".

A ramp ends by itself: two steps in a row under 90% of the target, or the top of the ramp.

## Validity rules (final, applied again to every saved run from its logs)

A run counts when all of these hold:

- no server restart, exactly one server up, no prefill errors, no request errors below the knee;
- the load generator is under 90% of its CPU limit, read for this case's own pod and averaged over the peak
  step. It never came close: at most 1.8 cores at 6,500 GET/s. (My first check read a 20 s maximum over every
  load generator pod and rejected three runs that were fine; they are counted now. The limit was 3 CPU until
  09:14 UTC on 2026-10-13 and 3.4 after.)
- the ramp was not ended by a disk stall: a step is stalled when its worst 10 s device latency is above 20 ms
  and above 1.5x the last normal step; the run is rejected when the ramp ended on a stalled step and no step
  that was not stalled showed saturation (under 97% of the target).

**The stall rule changed twice during the day** (a 20 ms floor was added, and the step after a stalled one
stopped counting as stalled). Both changes were made after looking at runs the rule had rejected. That is a
weak spot, so it is written down here and in `diskstat.py`. To keep it honest, every run was evaluated again
under the final rule.

Rejected under the final rule: one MinIO 4 KiB PUT (30 s steps, peak 350), one MinIO 4 KiB mixed (30 s, 800),
one RustFS relaxed (30 s, 577), and the 1 MiB and 100 MiB write ramps. One of those write ramps passes the
rule (RustFS 100 MiB PUT at 1.3 objects per second); it saw the same stalls as the others and is not used.
One 30 s run that the final rule accepts is still left out of the headline: RustFS 4 KiB PUT with a peak of
75, when the device was three times slower than normal for the whole knee (14 to 16 ms, under the 20 ms
floor). The 60 s series does not depend on it.

## Disk stalls

From the probe logs (device counters every 10 s, all cases, 110 stall events):

- **What:** the volume's average time per request jumps from its normal 3 to 13 ms to 25 to 250 ms (seconds in
  the 100 MiB cases) for 10 to 40 s, and throughput drops with it.
- **When:** only while writing. In the ramps it looked like one stall after about every 4 to 7 GiB written
  (100 MiB PUT: every 7.0 GiB, range 6.5 to 7.3, 12 intervals). At 4 KiB that is one every 4 to 5 minutes; at
  1 MiB and 100 MiB one every 70 to 110 s. Pure GET phases had none (0 of 125 samples for MinIO 4 KiB GET).
  The later MinIO run on a new volume wrote 41 GiB with no stall, so the age of the volume may matter too.
- **Who:** both contenders, equally. Share of time stalled: 4 KiB PUT 4% (MinIO) and 3% (RustFS); 1 MiB PUT
  19% and 25%; 100 MiB PUT 25% and 30%.
- **Cause:** not identified. I could not see it from inside the cluster. It is somewhere below the guest:
  the thin pool, the host's write cache, or the SSD's own cache.
- **Effect on the method:** the ramp ends after two steps under 90% of the target. With 30 s steps (60 s at
  100 MiB) a stall of 20 to 40 s can produce those two steps by itself.

Are the results fair to compare? **Yes for all GET results** (no writes, no stalls). **Yes for 4 KiB PUT and
mixed**: stalls are rare there (3 to 4% of the time), both contenders were exposed equally, and the 60 s
series has three valid runs each. MinIO's best step still varies more than RustFS's (570 to 730), because its
ramp is three times longer and meets more stalls. **No for 1 MiB and 100 MiB writes**: no ramp is free of
stalls, and the sustained method has one run per contender on unequal volumes.

### What I changed because of the stalls

1. **4 KiB PUT and mixed ramp in 60 s steps** with twice the rate step. One stall then costs one low step and
   the ramp goes on. All six cases got three valid runs this way.
2. **1 MiB and 100 MiB writes are meant to run as 10 minutes of sustained closed-loop load** (`SUSTAIN=10`),
   reported as the mean with stalls included, plus the share of time the volume was stalled. Only one such run
   per contender exists (RustFS: 72 MiB/s, lowest 30 s step 18, highest 107, stalled 27% of the time; MinIO:
   136 MiB/s over 5 minutes on a new volume).

## Why the large-write runs stopped early: the control plane

My three nodes are also the control plane, and etcd sits on the same SSD as the benchmark volumes. During the
runs Kubernetes control plane components restarted several times (lost leader leases):

| time (UTC, 2026-10-13) | what restarted | what the benchmark was doing |
|---|---|---|
| 08:12 | scheduler on one node | 100 MiB single PUT against RustFS |
| 10:26 | controller manager on one node | MinIO 4 KiB PUT ramp, during a disk stall |
| 11:59 to 12:02 | scheduler and controller manager on two nodes each, the API server on the server node | deleting the 500,000 object data set from the MinIO volume (8 minutes of `rm`) |

The last episode also failed a case ("etcdserver: request timed out"). Nodes stayed Ready, but a benchmark may
not shake the control plane, so I stopped after the running case instead of running five more sustained write
cases. Everything after that ran one case at a time, with 5 minutes of quiet between cases, volumes recreated
instead of emptied, and a watcher that would have stopped everything on the first control plane restart or
etcd timeout. The watcher did not trip. (On Talos Linux etcd runs outside Kubernetes, so its own restarts are
not visible to such a watcher.)

If your control plane shares a disk with the benchmark volumes, expect the same. See the README, "Before you run it".

## Seen once, not tested (RustFS, 100 MiB mixed)

These three happened in one run. I did not reproduce them, so they are observations, not bug reports.

- The 30 GiB volume ran full (a 20 GiB data set plus multipart overwrites in flight). RustFS answered
  `500 InternalError` to 64 `UploadPart` requests and logged "No space left on device". MinIO ran the same
  case three times with no error. **Seen once, not tested.**
- The next two attempts never started: the RustFS pod did not become ready within 5 minutes on that full
  volume. Its logs were not saved. After a wipe it started normally. **Seen once (twice in a row), not tested.**
- One GET in that run, before the volume was full, ended early with "unexpected EOF" after 16 of 100 MiB; the
  server logged "No such file or directory" for part 2 of that object. It looks like a read racing an
  overwrite of the same key. **Seen once, not tested.**

## Flat prefix: no cliff

One fixed overload run each, all keys in one prefix, volume wiped first: MinIO held about 600 PUT/s for
12 minutes (2 minute averages 680, 622, 625, 492, 609, 599; about 430,000 objects), RustFS about 190 for
35 minutes (about 400,000 objects; 4 minute averages between 153 and 208). No drop with the object count for
either.

In the first dry run MinIO seemed to fall to about 240 PUT/s near 200,000 objects in one prefix. That is
**not confirmed**: those runs wrote into a prefix that earlier runs had filled, partly overwrote keys, and the
stalls were not known then. The load generator keeps 1,000 keys per prefix by default, as warp spreads its keys;
`KEYS_PER_PREFIX=0` is the flat case.

## Test 2: three pods, one node lost (one run each)

`test2.sh`. Three pods of one contender, one per node, two 5 GiB drives each (6 drives, default parity),
1 CPU / 1 GiB per pod. First 2,000 objects of 4 KiB to 1 MiB (0.7 GiB) are written; their SHA-256 is known from
the seed. Then a steady load of 4 KiB objects (80% GET, 20% PUT) runs through a ClusterIP service, with no
client retries. After 2 minutes one node is cordoned and its pod deleted; 3 minutes later the node is
uncordoned. While the pod is gone 500 more objects go into a second bucket. A probe on that node counts those
500 on the returned pod's own two drives every 5 s: that is the healing measure. At the end every object of
both sets is read back and its SHA-256 compared.

### Run 2, the one to use: 100 requests per second (20 PUT + 80 GET)

The rate was chosen with a 60 s check on three-pod RustFS with all pods up: 100 of 100 per second, no dropped
slot, p99 0.28 to 0.53 s. Same rate for both.

| | MinIO | RustFS |
|---|---|---|
| before the kill (2 min) | 100 of 100 per second, median 4 ms, p99 up to 0.23 s, 0 errors, 0 dropped | 100 of 100 per second, median 20 ms, p99 up to 0.43 s, 0 errors, 0 dropped |
| pod gone (3 min) | 100 per second, **4 failed requests** of about 19,000, 0 dropped, p99 up to 0.50 s | 98 per second, **1 failed request**, **295 dropped** (all in the first 10 s), p99 4.3 s in that step, up to 1.1 s for a minute, then normal |
| after the uncordon (4 min) | 100 per second, 0 errors, p99 up to 0.28 s | 100 per second, 0 errors, p99 up to 0.66 s |
| writes while the pod was gone | 500 of 500 accepted | 500 of 500 accepted |
| pod Ready again after the uncordon | 3 s | 8 s |
| healing starts (first of the 500 on the returned drives) | 71 s after the uncordon | 18 s after the uncordon |
| **healing complete (all 500 on both returned drives)** | **197 s after the uncordon** | **249 s after the uncordon** |
| SHA-256, 2,000 objects written before | 2,000 intact, 0 missing, 0 corrupt | 2,000 intact, 0 missing, 0 corrupt |
| SHA-256, 500 objects written during the outage | 500 intact, 0 missing, 0 corrupt | 500 intact, 0 missing, 0 corrupt |

- **Both survive the loss of one of three nodes without losing or corrupting anything, keep taking writes,
  and heal by themselves in about 3 to 4 minutes** for this small set, under load, with no command given.
- The difference is in the first seconds: MinIO lost 4 requests that were on their way to the dead pod
  (timeouts and broken connections) and never slowed down. RustFS lost 1 request and stalled for about 3 s
  (295 slots dropped in the first 10 s step), then was slower for about a minute.
- RustFS started healing sooner and went at a steady 2 objects per second; MinIO waited about 70 s and then
  went faster. For RustFS the last 20 of 500 arrived just after the load had ended and the verify reads had
  begun, so reads may have helped with those; MinIO was complete 40 s before its load ended.
- One run each. Healing time here is for 500 small objects (55 MiB). It says nothing about a full drive.
- Not done: "delete all pods at once" (RustFS issue #2663), and a bigger version of this test.

### Run 1, not to be used for latency: 250 requests per second (50 PUT + 200 GET)

| | MinIO | RustFS |
|---|---|---|
| before the kill | 250 of 250 per second, median 3 ms, p99 up to 0.43 s, 0 dropped | **145 to 150 of 250**, median 1.0 to 1.3 s, about 100 slots per second dropped: over its limit with all pods up |
| pod gone | 250 per second, 19 failed requests of about 47,000 | 176 to 184 per second, 1 failed request |
| after the uncordon | 250 per second, 0 errors | about 150 per second, 0 errors |
| pod Ready again after the uncordon | 7 s | 15 s |
| SHA-256, 2,000 objects | 2,000 intact | 2,000 intact |

Only RustFS was saturated, and before anything was killed: loading the 2,000 small objects ran at 40 PUT/s on
RustFS against 156 on MinIO in this layout, so 50 PUT/s in the mix were more than it takes (its pods used 0.5
to 0.8 of 1 CPU: waiting on synced writes). With a node gone it got faster, having fewer drives to sync.
Its latency in that run is the 2 s cap described above, not an effect of the node loss. That run also had no
healing measure. It is kept because it shows where three-pod RustFS stops on this disk: between 100 and 150
requests per second of this mix, where MinIO still had room at 250.

## Test 3: what the two web consoles offer (2026-10-13)

The same steps on both, in a scripted browser, on a fresh volume with one bucket and 300 small objects.
The browser script is not in this folder; the steps are easy to repeat by hand (README, "Test 3").

| step | MinIO community console | RustFS 1.0.1 console |
|---|---|---|
| log in | works; an AGPL notice must be acknowledged first | works |
| create a bucket | works | works; versioning, object lock and quota in the dialog |
| upload a file, browse 300 objects | works | works |
| object details | download, share link, preview, tags, versions, delete | download, preview, tags, versions, temporary share URL |
| users | **missing** | works: user created with the `readonly` policy attached |
| policies | **missing** | works: 8 built-in policies, policy editor |
| access keys | **missing** | works |
| lifecycle rules | **missing** | page per bucket, add-rule dialog (expiration, transition); no rule was saved in the recording |
| metrics | **missing** | "Running Status": health, capacity, servers, disks. No request graphs |
| licence page | "Community Edition" next to "Enterprise", an Upgrade button, "Intended use: Test and Dev Use" | Apache License 2.0 |

The MinIO sidebar has four entries: Create Bucket, Documentation, License, Sign Out. The addresses of the old
admin pages (users, policies, access keys, bucket lifecycle, metrics) fall back to the object browser. That work
needs the `mc` client.
The RustFS sidebar has 22 entries, among them S3 Tables, User Groups, Import/Export, Rebalance, Pool
Decommission, Bucket Events, Bucket and Site Replication, Tiered Storage, Event and Audit targets, SSE, OIDC.
Only the pages in the table were opened. The others were not exercised, so "it has a page" is all that is claimed.

## Test 4: resource use (one run, small objects only)

`test4.sh`, each contender alone on a fresh volume, same node, 3 CPU / 3 GiB limits. CPU and memory from cAdvisor.

| | MinIO | RustFS |
|---|---|---|
| image, compressed | 38.5 MiB (my build: the binary on distroless) | 106.0 MiB (official image) |
| container start to Ready, empty new volume | 1 s | 1 s |
| container start to Ready, restart with 35,000 objects (3 times) | 1 s, 1 s, 1 s | 0 s, 0 s, 0 s |
| idle on an empty volume: CPU / memory | 0.001 cores / 76 MiB | 0.001 cores / 70 MiB |
| idle with 35,000 objects, minutes 2 to 5 after a start: CPU / memory | 0.012 cores / 111 MiB | 0.080 cores / 273 MiB |
| 100 PUT/s of 4 KiB for 5 min: CPU | 0.17 cores = 1.7 CPU-s per 1,000 PUT | 0.40 cores = 4.0 CPU-s per 1,000 PUT |
| 1,000 GET/s of 4 KiB for 5 min: CPU | 0.60 cores = 0.60 CPU-s per 1,000 GET | 0.48 cores = 0.48 CPU-s per 1,000 GET |
| memory at the end of those runs (working set, page cache included) | 362 and 373 MiB | 351 and 387 MiB |

- Start times are below what this can resolve (1 s timestamps, readiness probe every 2 s): both start in about a
  second. From pod creation, which includes attaching and formatting a new volume, it was 6 s and 11 s once.
- Idle on an empty volume both are free. With data RustFS used more CPU and 2.5x the memory in the minutes after
  a start. Whether that settles later was not measured (5 minutes only).
- Per request the picture matches test 1: RustFS spends 2.4x the CPU of MinIO on a small PUT and 20% less on a
  small GET. No request errors in any of the four runs.
- Not measured: idle with 20 GiB stored, and memory growth over a 30 minute mixed run.

## Disk baseline and cross-check with warp (dry run, 2026-10-12)

This was the first dry run: one run per case, MinIO on one node and RustFS on another, load generator 0.2.0.
It is here for two things only: what the disk does, and that the load generator agrees with warp.

fio, O_DIRECT, 30 s each, on each contender's own volume:

| | MinIO's volume (node sut-a) | RustFS's volume (node sut-b) |
|---|---|---|
| seq write 1 MiB | 546 MiB/s | 541 MiB/s |
| seq read 1 MiB | 2,652 MiB/s | 8,186 MiB/s |
| rand read 4 KiB, depth 32 | 112k IOPS | 195k IOPS |
| rand write 4 KiB, depth 32 | 3,390 IOPS | 3,318 IOPS |
| 4 KiB write + fsync | 138 IOPS | 132 IOPS |

Writes are equal on both nodes. Reads are faster than any SSD (that is the hypervisor's page cache) and differ
3x between the nodes. That is why every later run has both contenders on the same node. fio on the two volumes
there: 637 against 629 MiB/s sequential write, 140 against 140 synced writes per second, 3,761 against 3,789
with 64 writers.

4 KiB, peak objects per second, 64 workers against 64 warp clients:

| case | contender | load generator plateau | warp average | difference |
|---|---|---|---|---|
| PUT | MinIO | 591 | 610 (later 575 and 624) | 3% |
| PUT | RustFS | 161 | 171 | 6% |
| GET, 20,000 objects (cached) | MinIO | 5,560 | 5,598 | 1% |
| GET, 20,000 objects (cached) | RustFS | 6,574 | 6,717 | 2% |

warp is closed loop (N clients as fast as they can), so its average is compared with the load generator's
plateau at the same number of workers. They agree within 6%.

## What is missing

| what | status |
|---|---|
| 1 MiB PUT sustained on equal volumes (both new, or both used), three runs each | not run: large writes were stopped (control plane) |
| 1 MiB mixed sustained, three runs each | not run |
| 100 MiB PUT and mixed | dropped by decision; the bulk loads are the only evidence |
| RustFS full-volume and read-during-overwrite test | not run: the three "seen once" observations stay untested |
| Three nodes: all pods deleted at once, and a data set bigger than 55 MiB | not run |
| Multi-site replication, KMS, Object Lock, long-term stability, real multi-disk speed, objects above 100 MiB | not tested at all |
