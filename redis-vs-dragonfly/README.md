# Redis vs Dragonfly on equal CPU

Companion to the video **Redis vs Dragonfly**. Every setting from the benchmark is here, so you can check it and run it yourself.
If you think a setting is wrong, run it and open an issue with your numbers.

Tested: Redis 8.10.1 and Dragonfly 1.40.2 (io_uring, `--cache_mode`), with the same CPU budget for both, on 2026-09-06.

| Test | Redis side | Dragonfly side |
|---|---|---|
| 1 | one process, 1 CPU | 1 thread, 1 CPU |
| 2 | Redis Cluster, 3 masters x 950m, no replicas | 3 threads, 2850m |
| 3 | one process, `io-threads 3`, 2850m | 3 threads, 2850m (the test 2 run) |

Workload per iteration: `SET key <512 B> EX 20`, then `GET key`, 100k keys, 256 connections.
The load generator is open-loop: it asks for a fixed rate and raises it every 30 s, so a server that falls behind shows up as latency.
Persistence is off on both. Redis runs `allkeys-lru`, Dragonfly runs `--cache_mode` (its equivalent).

## Results (pipeline depth 16, one contender at a time)

ops/s = SET + GET. Knee = first sample where GET p99 crosses 5 ms. Values are the median of two rounds.

| test | contender | CPU budget | knee ops/s | plateau ops/s | CPU at plateau | p99 @100k | p99 @200k | p99 @300k |
|---|---|---|---|---|---|---|---|---|
| 1 | Redis, single process | 1 CPU | ~225k | ~281k | 0.65 | 0.5 ms | 1.6 ms | 25 ms |
| 1 | Dragonfly, 1 thread | 1 CPU | ~178k | ~195k | 0.94 | 0.55 ms | 34 ms | n/a |
| 2 | Redis Cluster, 3 masters | 3 x 950m | ~280k | ~466k * | 1.58 | 0.5 ms | 1.5 ms | 5-10 ms |
| 2 | Dragonfly, 3 threads | 2850m | ~287k | ~377k | 2.4 | 0.9 ms | 1.9 ms | 12-17 ms |
| 3 | Redis, io-threads 3 | 2850m | ~307k | ~421k * | 1.58 | 0.5 ms | 1.2 ms | 4-5 ms |

`*` client node and database node were both at 85-90 % CPU (kernel networking): that plateau is the lab's limit, the contender still had CPU left.

Pipeline depth 1 (one round trip per operation, both contenders at once): all three tests stopped at 26-29k ops/s per contender,
with 30-48 ms p99 and half a CPU used. Both were waiting on the network. Dragonfly had 0.5-4 ms lower p99 in every depth-1 run.

What it says:

- One core: Redis had a ~45 % higher plateau and lower latency at every load above 100k. Dragonfly used more CPU for less throughput (0.94 vs 0.65 cores at plateau).
- Three cores: the Redis Cluster and Redis with io-threads both reached higher throughput than Dragonfly with three threads.
  io-threads had the lowest latency of the three. Dragonfly used ~50 % more CPU than either Redis variant at plateau.
- Dragonfly's knee in test 2 (~287k) was on par with the cluster's (~280k), and the cluster varied more between rounds (knee 250k vs 310k).
- On equal CPU the throughput differences stayed within 1.5x.

## About the 25X number

Dragonfly's [README](https://github.com/dragonflydb/dragonfly/blob/main/README.md) says (read 2026-10-12):

> Compared to legacy in-memory datastores, Dragonfly delivers 25X more throughput

and, in its benchmark section:

> Dragonfly showed a 25X increase in throughput compared to a single Redis process, crossing 3.8M QPS.

That number is from an AWS c6gn.16xlarge (64 vCPUs), where Dragonfly uses the whole machine and is compared with one single Redis process.
This test asks a different question: the same CPU budget for both, on small VMs (1 and 3 cores).
It does not confirm or disprove the 64 vCPU result. I did not test a machine of that size.

## Caveats

- **Homelab, not a cloud.** Three Talos VMs (4 vCPU / 7 GiB each) on one Proxmox host with a consumer CPU (Ryzen 7 6800H, 16 threads).
  The Proxmox host is itself a VM, so CPU steal from the outer layer is invisible. Compare ratios and curve shapes. The absolute numbers do not transfer to other hardware.
- **Pipelining was required.** Round trips between two VMs on this host stop near 35k/s (measured with `redis-benchmark`, independent of connection count;
  pipelining lifts the same path to 318k). At depth 1 nothing reaches server saturation, so the headline table uses depth 16, the same for both.
- **The Redis plateaus in tests 2 and 3 are lab-bound** (nodes at 85-90 % CPU). Their real ceilings are probably higher than the table shows.
- **Dragonfly on Talos needs `seccompProfile: Unconfined` for io_uring.** The Talos default seccomp profile blocks `io_uring_setup`; Dragonfly then falls back to epoll
  and flatlines near 18k ops/s on one thread. `Unconfined` turns seccomp filtering off for that pod, and the namespace has to allow it
  (`pod-security.kubernetes.io/enforce: privileged`). Fine for a throwaway benchmark pod. Decide for yourself before doing it in production.
- **Dragonfly's memory budget grows with threads.** It needs 256 MiB of maxmemory per thread, so it got 768 MB at three threads against 512 MB per Redis process.
  The dataset is ~50 MB and nothing was evicted in any run.
- **The nodes were not empty.** A few small unrelated workloads and the monitoring stack stayed on the Dragonfly node during the runs.
- Two rounds per leg, not more. The rounds agree within 5 %; the Redis Cluster knee is the exception (250k vs 310k).
- Contenders ran back to back at depth 16 (both load generators together saturate the client node first), so they did not see exactly the same minute of host noise.
- The Redis Cluster has no replicas. That is a cache setup, not a highly available one.

## Files

| Path | What |
|---|---|
| [manifests/](manifests/) | namespace, Redis (single, cluster, io-threads), Dragonfly, the two load generators. Everything starts at 0 replicas |
| [run.sh](run.sh) | starts a test: scales the right pods up, creates the cluster, sets Dragonfly's threads and CPU, starts the ramp |
| [loadgen/](loadgen/) | the load generator (Go, raw RESP, Prometheus histograms on `:9090/metrics`) and its Dockerfile |
| [monitoring/scrape-config.yaml](monitoring/scrape-config.yaml) | two 5 s scrape jobs: load generator metrics and cAdvisor for the `benchmark` namespace |
| [monitoring/redis-vs-dragonfly.json](monitoring/redis-vs-dragonfly.json) | Grafana dashboard: p99 latency, requests per second, CPU, network, memory |
| [monitoring/redis-vs-dragonfly-health.json](monitoring/redis-vs-dragonfly-health.json) | Grafana dashboard for the operator: errors, target vs achieved, load generator CPU |
| [monitoring/dashboard.py](monitoring/dashboard.py) | generates both dashboards |

## Run it

Needs: a Kubernetes cluster with 3 nodes of 4 vCPU or more, `kubectl`, Docker, a registry your cluster can pull from,
and Prometheus or VictoriaMetrics with Grafana.

```bash
# 1. Build and push the load generator, then point the manifest at it
docker build -t <your-registry>/redis-bench-loadgen:0.3.0 loadgen
docker push <your-registry>/redis-bench-loadgen:0.3.0
sed -i 's|your-registry.example.com|<your-registry>|' manifests/loadgen.yaml

# 2. Give each role its own node
kubectl label node <node-1> bench-role=sut-a      # Redis
kubectl label node <node-2> bench-role=sut-b      # Dragonfly
kubectl label node <node-3> bench-role=clients    # load generators

# 3. Create everything (0 replicas, nothing runs yet)
kubectl apply -f manifests/namespace.yaml
kubectl apply -f manifests/
```

4. Add the two jobs from `monitoring/scrape-config.yaml` to your scraper and import both JSON files in Grafana (Dashboards, New, Import).
   Pick your datasource in the dropdown at the top.

```bash
# 5. One leg at a time at depth 16. Watch the dashboard, stop when throughput no longer follows the target (10 to 20 minutes)
PIPELINE=16 ONLY=redis     ./run.sh test1
PIPELINE=16 ONLY=dragonfly ./run.sh test1
PIPELINE=16 ONLY=redis     ./run.sh test2     # Redis Cluster
PIPELINE=16 ONLY=dragonfly ./run.sh test2
PIPELINE=16 ONLY=redis     ./run.sh test3     # io-threads; compare with the Dragonfly leg of test2

./run.sh test1                                # depth 1, both at once: shows the network wall
./run.sh stop                                 # everything back to 0
```

## Expected output

- `run.sh` prints two lines from the Dragonfly log, then `ramp started <UTC time>: <contender>, pipeline 16, <start> -> <max> it/s`.
  Check the Dragonfly lines: if you see `switching to epoll`, io_uring is blocked and the Dragonfly numbers will be far too low.
- On the dashboard, requests per second climb in steps every 30 s, then flatten. p99 latency stays low and then jumps: that jump is the knee.
- On the health dashboard, errors stay at 0 and the load generator's CPU stays below its 1.5 CPU limit. If it does not, the run is client-bound and does not count.
- Your absolute numbers will differ from mine. The interesting part is whether the order and the ratios hold on your hardware.

## Clean up

```bash
kubectl delete namespace benchmark
kubectl label node <node-1> <node-2> <node-3> bench-role-
```
