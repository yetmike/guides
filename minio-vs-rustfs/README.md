# MinIO vs RustFS: can RustFS replace MinIO?

Companion to the video **MinIO vs RustFS**. Every setting from the benchmark is here, so you can check it and run it yourself.
If you think a setting is wrong, run it and open an issue with your numbers.

Tested on 2026-10-12 and 2026-10-13:

| | version | image |
|---|---|---|
| MinIO | `RELEASE.2025-10-15T17-29-55Z`, the last community tag (commit `9e49d5e7a648`), default durability | **built from source** with [images/minio/Dockerfile](images/minio/Dockerfile). The official community images and binaries are gone |
| RustFS | 1.0.1, default durability (`strict`) | official `rustfs/rustfs:1.0.1` |
| load generator | 0.3.0, [loadgen/](loadgen/) | built from this folder |
| warp + fio | warp v1.8.2, fio 3.39 | built with [images/tools/Dockerfile](images/tools/Dockerfile) |

Both servers get the same budget: 3 CPU, 3 GiB (requests == limits) and one 30 GiB volume. One pod, one drive, no TLS.

| Test | What | Script |
|---|---|---|
| 1 | Speed on one node: PUT, GET and mixed at 4 KiB, 1 MiB and 100 MiB | `run.sh`, `queue.sh` |
| 2 | Three pods, one node lost: errors, healing time, SHA-256 of every object | `test2.sh` |
| 3 | What the two web consoles can do | by hand, steps below |
| 4 | Resource use: start time, idle, CPU per 1,000 requests | `test4.sh` |

## Results in short

Peak objects per second, median of three valid runs. All numbers, run counts and rules: [RESULTS.md](RESULTS.md).

| case | MinIO | RustFS | ratio |
|---|---|---|---|
| 4 KiB PUT | 650 | 177 | MinIO 3.7x |
| 4 KiB PUT, RustFS in `relaxed` mode | | 860 | 1.3x MinIO, 4.9x its own default |
| 4 KiB mixed, 70% GET | 1,152 | 683 | MinIO 1.7x |
| 4 KiB GET, data set bigger than memory | 3,796 | 4,989 | RustFS 1.3x |
| 4 KiB GET, cached | 5,819 | 6,493 | RustFS 1.1x |
| 1 MiB GET | 624 | 613 | tie, a lab limit |
| 100 MiB GET | 890 MiB/s | 820 MiB/s | tie, a lab limit |
| 1 MiB and 100 MiB writes | | | **not comparable**, see RESULTS.md |

- Test 2 (one run each): both lost no object and corrupted none when one of three nodes went away, both kept
  taking writes, and both healed by themselves in 3 to 4 minutes.
- Test 3: the MinIO community console is an object browser now. Users, policies, access keys, lifecycle rules
  and metrics are gone from it. The RustFS console has them.
- Test 4 (one run): with 35,000 objects and no load, MinIO used 111 MiB and RustFS 273 MiB in the first minutes
  after a start. RustFS needs 2.4x the CPU for a small PUT and 20% less for a small GET.

## What the numbers show, and what they do not

- **They show ratios on one slow disk.** My SSD gives one writer about 140 synced 4 KiB writes per second. Small
  PUTs are bound by how many sync points a server needs per object, not by CPU: both servers were under one
  core of three at the PUT peak. On an SSD with power-loss protection the numbers, and maybe the ratio, change.
- **The two defaults do not promise the same thing.** RustFS `strict` also makes the directory entry durable
  before it answers. MinIO's default does not. See "Durability settings" below. Power loss was not tested.
- **Large reads are a tie decided by the lab**, not by the servers: both stop at the same 610 to 890 MiB/s with
  CPU to spare.
- **Large writes have no fair comparison.** The volume stalled during large writes, no ramp survived it, and the
  one sustained run per contender met different volumes (one new, one used for 15 hours).
- **Three observations about RustFS on a full volume were seen once** and not tested further. They are marked
  "seen once" in RESULTS.md and are not bug reports.
- Tests 2 and 4 are one run each. Test 2 heals 500 small objects (55 MiB): that says nothing about a full drive.
- Not tested at all: multi-site replication, KMS, Object Lock, long-term stability, real multi-disk speed,
  objects above 100 MiB, TLS.

## The method in plain words

- **One contender at a time.** Every volume in my lab sits on the same SSD, so two servers under load would
  measure each other. `run.sh` scales the other server to 0 and waits until its pod is gone.
- **Same node, same budget.** Both servers run on the node labelled `bench-role=sut-a`, each on its own volume,
  with requests == limits (Guaranteed QoS). The load generator has its own node (`bench-role=clients`).
- **A fresh server process for every case.** The node's page cache is not dropped between cases.
- **Open loop.** The load generator asks for a fixed rate and raises it every 30 or 60 s. Latency is measured
  from the scheduled start of a request, so a server that falls behind shows as latency. A request that cannot
  start within 2 s of its slot is counted as `dropped`. Past the limit "achieved" falls under "target".
- **The ramp ends by itself**: two steps in a row under 90% of the target. The result is the best step.
- **Three valid runs, median.** A run is valid when the server did not restart, only one server was up, there
  were no errors below the knee, the load generator stayed under 90% of its CPU limit, and a disk stall did not
  end the ramp. `queue.sh` checks all of that from the logs. The stall rule changed twice on the day of the
  runs, after looking at runs it had rejected. That history is in RESULTS.md, "Validity rules".
- **Large writes** (1 MiB, 100 MiB) do not ramp: `SUSTAIN=10` runs 10 minutes of closed-loop load and reports
  the mean with stalls included.
- **Payload**: one incompressible random stream, every PUT sends a different window of it. 1,000 keys per
  prefix. 100 MiB objects go up as multipart, 16 MiB parts, 4 at a time. No client retries.
- **Cross-check**: warp, closed loop, agrees with the load generator's plateau within 6% at 4 KiB.

## Durability settings (defaults, not changed in the main runs)

| | knob | default | what the default syncs on a small PUT |
|---|---|---|---|
| MinIO | `MINIO_FS_OSYNC` (`cmd/common-main.go:745`) | off | one `fdatasync` of the object's `xl.meta`, which holds a 4 KiB object inline (`cmd/xl-storage.go:2836`, `Fdatasync` at `:2195`). The renames that publish the object are not synced; `MINIO_FS_OSYNC=on` adds a global `sync()` after them (`:2576`) |
| RustFS | `RUSTFS_DURABILITY_MODE` = `strict` / `relaxed` / `none` (`crates/ecstore/src/disk/local.rs:1066`), also per bucket | `strict` | `xl.meta` (with the inline object), the rollback backup, and the parent directories of the commit renames. `relaxed` syncs none of these for inline objects (`docs/operations/durability-modes.md`) |

Line numbers are for MinIO `RELEASE.2025-10-15T17-29-55Z` and RustFS `1.0.1`.
RustFS 4 KiB PUT also runs in `relaxed` as a labelled extra, to show what the default costs.

## Caveats

- **Homelab, not a cloud.** Three Talos Linux VMs (4 vCPU / 7 GiB each) on one hypervisor host. Every volume
  sits on the same consumer SSD, without power-loss protection. Compare ratios and curve shapes only.
- The virtual disk reports "write through" (no volatile cache), so the guest never sends a flush command.
  Whether a write is really on flash when the hypervisor acknowledges it is not something this lab can prove.
- **Reads come from RAM in part.** fio reads several GiB/s from this "disk": that is the hypervisor's page
  cache. Read results say more about CPU and network than about a disk.
- **The volume stalls for 10 to 40 s while writing**, for both contenders. Cause not identified. Ramps of
  large-object writes cannot be judged on this storage.
- The server node also ran a metrics store, a log store, a database and a control plane. They are light, and
  they were there for both contenders.
- PUT ramps write new keys until the key space wraps, then overwrite. Every PUT run starts on a wiped volume.
- One node, one drive in test 1: no erasure coding, no redundancy on either side.
- The MinIO image is my own build of the last community tag. Nothing is patched (the Dockerfile shows every step),
  but it is not an official binary.

## Files

| Path | What |
|---|---|
| [RESULTS.md](RESULTS.md) | every number, run counts, validity rules and their history, disk stalls, "seen once" notes |
| [manifests/](manifests/) | namespace, MinIO, RustFS, the two load generators. Everything starts at 0 replicas |
| [images/minio/Dockerfile](images/minio/Dockerfile) | MinIO built from the last community tag: clone, check the commit, build as upstream's `make build` does |
| [images/tools/Dockerfile](images/tools/Dockerfile) | warp v1.8.2 built from source, plus fio |
| [loadgen/](loadgen/) | the S3 load generator (Go, aws-sdk-go-v2, Prometheus histograms on `:9090/metrics`), its self-check and Dockerfile |
| [run.sh](run.sh) | test 1: one case (`case`), warp cross-check, fio baseline, wipe, check, cleanup |
| [queue.sh](queue.sh) | test 1 unattended: every case three times, validity check per run, resumable |
| [diskstat.py](diskstat.py) | disk writes per operation and the stall rule, from the probe's device counters |
| [test2.sh](test2.sh) | test 2: three pods, node loss, healing probe, SHA-256 verify |
| [test4.sh](test4.sh) | test 4: start time, idle and per-request CPU and memory |
| [monitoring/scrape-config.yaml](monitoring/scrape-config.yaml) | two 5 s scrape jobs: load generator metrics and cAdvisor for the `benchmark` namespace |
| [monitoring/minio-vs-rustfs.json](monitoring/minio-vs-rustfs.json) | Grafana dashboard: p99 latency, requests per second, CPU, network, memory |
| [monitoring/minio-vs-rustfs-health.json](monitoring/minio-vs-rustfs-health.json) | Grafana dashboard for the operator: errors, target vs achieved, load generator CPU, bytes per second |
| [monitoring/dashboard.py](monitoring/dashboard.py) | generates both dashboards |

## Run it

Needs:

- a Kubernetes cluster with 3 nodes of 4 vCPU and 7 GiB or more. The server node needs 3 CPU and 3 GiB free,
  the clients node 3.4 CPU;
- a default StorageClass with 60 GiB free for test 1 and 30 GiB per contender for test 2;
- `kubectl`, `bash` 4 or newer, `python3`, `openssl`, `bc`, GNU `date` (Linux), Docker;
- a registry your cluster can pull from;
- Prometheus or VictoriaMetrics, with Grafana if you want the dashboards.

### Before you run it

- **Use a test cluster.** Test 1 writes tens of GiB and deletes hundreds of thousands of files. On my cluster,
  where etcd shares the SSD with the benchmark volumes, that made control plane components restart
  (RESULTS.md, "Why the large-write runs stopped early"). `test4.sh` watches for that and stops. `queue.sh` does not.
- **Test 2 cordons a node** for 3 minutes and deletes one pod of the contender. `test2.sh down` uncordons it.
- The full `queue.sh` plan is about 14 hours on my disk. `./queue.sh list` shows the estimate per case.

### 1. Build and push the three images

There is no official MinIO community image any more, so you build it. The MinIO build is heavy: about
7 minutes on a CI runner. Do not run it on a busy laptop.

```bash
R=<your-registry>     # for example registry.example.com/me

docker build -t $R/minio-community:RELEASE.2025-10-15T17-29-55Z images/minio
docker build -t $R/s3-bench-tools:warp-1.8.2 images/tools
docker build -t $R/s3-bench-loadgen:0.3.0 loadgen       # runs go vet and the self-check first
docker push $R/minio-community:RELEASE.2025-10-15T17-29-55Z
docker push $R/s3-bench-tools:warp-1.8.2
docker push $R/s3-bench-loadgen:0.3.0

# point the manifests and scripts at your registry
sed -i "s|your-registry.example.com|$R|" manifests/minio.yaml manifests/loadgen.yaml run.sh test2.sh
```

`your-registry.example.com` is a placeholder: nothing is published under it. If your registry is private, add
your own `imagePullSecrets` to the manifests and to the pod templates in `run.sh` and `test2.sh`.
The MinIO binary reports its version on start: `minio --version` must print `RELEASE.2025-10-15T17-29-55Z`.

### 2. Label the nodes and create everything

```bash
kubectl label node <node-1> bench-role=sut-a      # MinIO and RustFS, one at a time
kubectl label node <node-2> bench-role=clients    # load generators
# the third node needs no label: only test 2 uses it (one pod per node)

kubectl apply -f manifests/namespace.yaml
kubectl apply -f manifests/        # 0 replicas, nothing runs yet
```

The credentials are not in this repo. `run.sh` creates the secret `s3-bench-creds` in the `benchmark` namespace
with random values (`openssl rand`) the first time it starts a server. They are never printed.

### 3. Monitoring

Add the two jobs from `monitoring/scrape-config.yaml` to your scraper. The job names matter: the scripts and the
dashboards read `job="cadvisor-benchmark"`. Import both JSON files in Grafana (Dashboards, New, Import) and pick
your datasource in the dropdown at the top.

The scripts read CPU and memory for each case from your metrics store, through the API server proxy. Tell them where it is:

```bash
export PROM_PROXY=/api/v1/namespaces/<namespace>/services/<service>:<port>/proxy
kubectl get --raw "$PROM_PROXY/api/v1/query?query=up" | head -c 200     # must print JSON
```

Without it the CPU values are `nan` and `queue.sh` marks every run invalid ("loadgen CPU unknown").

### 4. Test 1: speed on one node

```bash
./run.sh fio                      # disk baseline on each contender's own volume
./run.sh case 4k put              # one ramp for MinIO, then one for RustFS
./run.sh case 4k get minio        # prefills the 500,000 keys first (15 to 55 minutes)
./run.sh case 1m get rustfs
RUSTFS_MODE=relaxed WIPE=1 RATE_START=200 RATE_STEP=200 RATE_MAX=10000 ./run.sh case 4k put rustfs
SUSTAIN=10 WIPE=1 ./run.sh case 1m put minio      # large writes: 10 minutes sustained, no ramp
./run.sh warp 4k put              # cross-check, closed loop
./run.sh check                    # QoS, budgets, who is running
./run.sh stop
```

Or the whole matrix, three runs per case, unattended:

```bash
setsid nohup ./queue.sh run >/dev/null 2>&1 &
tail -f .queue/queue.log          # one line per case: START, OK or INVALID with the reason
./queue.sh list                   # the plan and the state of every case
touch .queue/STOP                 # stop after the current case
```

Starting it again skips every case that is already ok and retries the invalid ones.
Sizes are `4k`, `1m`, `100m`; operations `put`, `get`, `mixed` (70% GET). All options are in the header of `run.sh`.
The volumes hold 30 GiB: wipe between object sizes (`WIPE=1` or `./run.sh wipe`).

### 5. Test 2: three pods, one node lost

```bash
./test2.sh up rustfs              # 3 pods, one per node, 2 drives of 5 GiB each
./test2.sh smoke rustfs           # 20 objects written and read back
./test2.sh rate rustfs            # does it hold 100 requests/s with all pods up? dropped must be 0
./test2.sh run rustfs             # 9 minutes: load, node cordoned, pod deleted, 500 writes, uncordon, heal, verify
./test2.sh down rustfs            # removes everything, volumes included

./test2.sh up minio && ./test2.sh run minio && ./test2.sh down minio
```

`NODE=<name>` picks the node to lose (default: the first node without `bench-role=clients`), `RATE=<n>` the
load, `STORAGE_CLASS=<name>` the class of the drives.

### 6. Test 3: the web consoles

No script here. Start one server, forward its console and click through the same steps on both:
log in, create a bucket, upload a file, browse, open an object, then look for users, policies, access keys,
lifecycle rules, metrics and the licence page.

```bash
kubectl -n benchmark scale sts minio --replicas=1       # or rustfs; never both
kubectl -n benchmark port-forward minio-0 9001:9001     # then open http://localhost:9001
# the login is in the secret. This prints the demo credentials in your terminal:
kubectl -n benchmark get secret s3-bench-creds -o go-template='{{range $k, $v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'
```

### 7. Test 4: resource use

```bash
setsid nohup ./test4.sh >/dev/null 2>&1 &         # deletes the test 1 volumes first, about 50 minutes per contender
tail -f .queue/test4.log
```

## Expected output

A ramp prints one line per step, a `DONE` line with the peak, then what the disk did:

```
minio 4k put: started 2026-10-13T09:42:49Z (keys 500000, workers 64, 50..2000 per second, part size 0, 60 s steps)
  2026/10/13 09:43:49 STEP target=50 ok/s=50.0 MiB/s=0.2 errors=0 dropped=0 p50=9.9ms p99=39.4ms
  2026/10/13 09:44:49 STEP target=100 ok/s=100.0 MiB/s=0.4 errors=0 dropped=0 p50=17.6ms p99=49.3ms
  ...
  DISK during the ramp: 0 flushes, 554365 writes, 81606 reads; per ok op: 0.00 flushes, 1.95 writes, 0.29 reads; ...
  STALL steps (target: worst 10 s device ms): 300: 65, 500: 50, 650: 31, 700: 20; does not decide the result
```

- `ok/s` follows `target` step by step, then stops following: that is the knee. `dropped` starts to count there.
- The summary line of a case must say `server restarts 0, servers up at once 1`, and the load generator CPU must
  be under 90% of 3.4. If not, the run does not count.
- `STALL-INVALID` in the `STALL` line means a disk stall ended the ramp: run it again.
- A sustained run ends with `SUSTAINED mean ok/s=... volume stalled N% of the time`.
- Test 2 prints one line per phase (`before the kill`, `pod gone`, `after the uncordon`), a `healing` line with
  the seconds until all 500 objects are on the returned drives, and four `VERIFY` lines. They must end in
  `missing=0 corrupt=0`:

```
  t2-verify-check: VERIFY check db=minio objects=2000 ok=2000 missing=0 corrupt=0
  t2-heal-check: VERIFY check db=minio objects=500 ok=500 missing=0 corrupt=0
```

- On the dashboard, requests per second climb in steps and then flatten, and p99 latency jumps at the knee.
- Your absolute numbers will differ from mine. The interesting part is whether the order and the ratios hold on your disk.

Everything a run prints is also appended to `runs.log`, and pod logs are saved under `.queue/artifacts/`.
Both are git-ignored: they contain your node names.

## Clean up

```bash
./test2.sh down minio; ./test2.sh down rustfs
./run.sh cleanup                                  # deletes the two 30 GiB volumes, also with reclaim policy Retain
kubectl delete namespace benchmark                # the demo credentials go with it
kubectl label node <node-1> <node-2> bench-role-
kubectl get pv | grep benchmark                   # must print nothing
```

## What was tested, honestly

The numbers in RESULTS.md come from my private copy of these files, run end to end on my cluster.
This public copy was changed after that, to take out everything specific to my cluster:

- image names are a placeholder, and the pull secret is gone from the pod templates;
- the StorageClass is your default one (mine was pinned by name);
- the metrics address is `PROM_PROXY`, the tools image `TOOLS_IMAGE`, the node to lose in test 2 is picked by label;
- the steps that paused other workloads on my cluster are removed;
- `queue.sh` has one merged plan. My runs were spread over three earlier versions of it;
- `test4.sh` no longer assumes the year 2026 when it reads a timestamp.

What was checked on this public copy:

- the load generator image was built from `loadgen/` (`go vet`, the self-check and the build pass). The Go source is
  unchanged except for a comment;
- `images/minio/Dockerfile` and `images/tools/Dockerfile` are byte for byte the files that built the tested
  images. They were not built again from this folder;
- `bash -n` and shellcheck on every script, `python3 -m py_compile` on the Python files;
- `kubectl apply --dry-run=client` on every manifest, and on every manifest the scripts generate;
- the scripts were run against a fake `kubectl` that replays my saved logs: `run.sh` and `diskstat.py` print the
  same `DISK` and `STALL` lines and the same `SUSTAINED` mean as the original runs did;
- the two dashboards have the same panels and queries as the ones in the video.

**Not done: a run of this public copy against a real cluster.** If a script fails for you, that is the most
likely reason. Please open an issue.
