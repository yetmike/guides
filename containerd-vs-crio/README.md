# containerd vs CRI-O: see the differences on your own laptop

Companion to the video **containerd vs CRI-O: Does It Actually Matter?**

The film runs the same checks on two throwaway clusters: kind (containerd) and minikube with `--container-runtime=cri-o` (CRI-O).
`demo.sh` creates both, runs every command shown in the video, and deletes both clusters at the end.

## Files

| File | What |
|---|---|
| [`demo.sh`](demo.sh) | creates both clusters, runs all the checks below, cleans up (`KEEP=1` keeps the clusters, `./demo.sh down` deletes them) |
| [`two.yaml`](two.yaml) | a pod with two containers (`sleep`), to compare the process trees |
| [`capsdrop.yaml`](capsdrop.yaml) | a pod that drops ALL capabilities and prints what it has left |

## Needs

- Linux with Docker (the minikube docker driver and kind both run nodes as containers), about 4 GB of free RAM
- [kind](https://kind.sigs.k8s.io/) v0.33 or newer (Kubernetes 1.37 node image, containerd 2.3)
- [minikube](https://minikube.sigs.k8s.io/) (the video used v1.39.0)
- kubectl 1.37 or newer
- optional: `capsh` (package `libcap2-bin` on Debian/Ubuntu, `libcap` on Fedora) to decode the capability masks

## Run it

```sh
./demo.sh            # about 3 to 5 minutes, deletes both clusters at the end
KEEP=1 ./demo.sh     # keep the clusters to look around; later: ./demo.sh down
```

It creates:

```sh
kind create cluster --name crt --wait 180s
minikube start -p crio --container-runtime=cri-o --driver=docker --cpus=2 --memory=3g --kubernetes-version=v1.35.8
```

minikube is pinned to Kubernetes 1.35.8 because it ships CRI-O 1.35, and CRI-O versions follow Kubernetes versions (see Caveats).
The minikube node container is named after the profile (`crio`), so `docker exec crio ...` runs a command on the CRI-O node.
On both nodes `docker exec` runs as root, so `crictl` needs no `sudo`.

## What you should see

Names, ages, IDs and image tags differ on your machine.

### 1. Which runtime runs your pods

```
$ kubectl --context kind-crt get nodes -o wide
NAME                STATUS   ROLES           AGE   VERSION   ...   CONTAINER-RUNTIME
crt-control-plane   Ready    control-plane   74s   v1.37.0   ...   containerd://2.3.4

$ kubectl --context crio get nodes -o wide
NAME   STATUS   ROLES           AGE   VERSION   ...   CONTAINER-RUNTIME
crio   Ready    control-plane   36s   v1.35.8   ...   cri-o://1.35.7
```

The last column is the answer for your own cluster too. If a node still shows `containerd://1.x`, upgrade it before Kubernetes 1.36:
from 1.36 the kubelet needs containerd 2.0 or newer.

### 2. The same answer on the node

```
$ docker exec crt-control-plane crictl version
RuntimeName:  containerd
RuntimeVersion:  v2.3.4
RuntimeApiVersion:  v1

$ docker exec crio crictl version
RuntimeName:  cri-o
RuntimeVersion:  1.35.7
RuntimeApiVersion:  v1
```

### 3. Configuration

```
$ docker exec crt-control-plane head -3 /etc/containerd/config.toml
# explicitly use v2 config format
version = 2

$ docker exec crt-control-plane sh -c 'containerd config dump 2>/dev/null | grep -m2 cri.v1'
  [plugins.'io.containerd.cri.v1.images']
    [plugins.'io.containerd.cri.v1.images'.pinned_images]

$ docker exec crio ls /etc/crio/crio.conf.d
02-crio.conf
10-crio.conf
```

kind still writes the old config format (`version = 2`, sections named `io.containerd.grpc.v1.cri`). containerd 2 migrates it when it loads,
and the effective config uses the new section names (`io.containerd.cri.v1.*`). CRI-O reads `crio.conf` plus the drop-in files in `crio.conf.d`.

### 4. Where the images live

```
$ docker exec crt-control-plane ctr images ls -q
                                   <- empty: the default namespace has no images
$ docker exec crt-control-plane ctr -n k8s.io images ls -q | grep -v sha256 | head -4
docker.io/kindest/kindnetd:v20260820-69b56db7
docker.io/kindest/local-path-helper:v20260131-7181c60a
docker.io/kindest/local-path-provisioner:v20260820-69b56db7
docker.io/library/busybox:1.37

$ docker exec crio ls /var/lib/containers/storage
artifacts
defaultNetworkBackend
libpod
mounts
overlay
overlay-containers
overlay-images
overlay-layers
storage.lock
tmp
userns.lock
```

containerd keeps Kubernetes images in the `k8s.io` namespace under `/var/lib/containerd`. CRI-O uses `/var/lib/containers/storage`, the same store layout as Podman.

### 5. Process tree

```
$ docker exec crt-control-plane ps -e | grep -m3 shim
    310 ?        00:00:00 containerd-shim
    333 ?        00:00:00 containerd-shim
    349 ?        00:00:00 containerd-shim

$ docker exec crio ps -e | grep -m3 conmon
   1208 ?        00:00:00 conmon
   1209 ?        00:00:00 conmon
   1210 ?        00:00:00 conmon
```

Then the parents of the two `sleep` processes of pod `two`:

```
containerd node:            CRI-O node:
    PID COMMAND                 PID COMMAND
   5452 containerd-shim        2038 conmon
                               2045 conmon
```

containerd: one shim per pod. CRI-O: one `conmon` per container (and no pause container by default).

### 6. Default OCI runtime

```
$ docker exec crt-control-plane crictl info | grep -m1 defaultRuntimeName
      "defaultRuntimeName": "runc",

$ docker exec crio crictl info | grep -m1 DefaultRuntime
      "DefaultRuntime": "crun",
```

### 7. Default capabilities, then drop ALL

The `caps` pod sets no `securityContext`, so the runtime picks the starting set:

```
$ kubectl --context kind-crt logs caps
CapEff:	00000000a80425fb
14 capabilities: cap_chown,cap_dac_override,cap_fowner,cap_fsetid,cap_kill,cap_setgid,cap_setuid,cap_setpcap,cap_net_bind_service,cap_net_raw,cap_sys_chroot,cap_mknod,cap_audit_write,cap_setfcap

$ kubectl --context crio logs caps
CapEff:	00000000000005fb
9 capabilities: cap_chown,cap_dac_override,cap_fowner,cap_fsetid,cap_kill,cap_setgid,cap_setuid,cap_setpcap,cap_net_bind_service

$ kubectl --context kind-crt logs capsdrop
CapEff:	0000000000000000

$ kubectl --context crio logs capsdrop
CapEff:	0000000000000000
```

CRI-O leaves out five: `net_raw`, `sys_chroot`, `mknod`, `audit_write`, `setfcap`. With `drop: [ALL]` (what the restricted Pod Security profile asks for) both are empty, and the difference is gone.

## Check your own cluster

Read-only, works on any cluster:

```sh
kubectl get nodes -o wide        # last column: containerd://... or cri-o://...
```

On a node (SSH or a debug pod): `crictl version`, `crictl info`, and `ps -e | grep -E 'shim|conmon'`.

## Caveats

- Default minikube v1.39 starts Kubernetes 1.37 with CRI-O 1.35 (the minors do not match). That is why the script pins `--kubernetes-version=v1.35.8`. Upstream, CRI-O 1.N is the release for Kubernetes 1.N.
- kubectl from your distro may be several minors older than the kind server (1.37). Use kubectl 1.37+, or `minikube kubectl --` for the CRI-O cluster.
- The minikube node image also contains `ctr`, `nerdctl` and Docker binaries, but only CRI-O runs there. Do not read their presence as "this node runs containerd".
- kind gets its 14 default capabilities from `/etc/containerd/cri-base.json`; the list matches containerd's own default.
- The `kubelet_cri_losing_support` metric from the video stays empty on current runtimes: the kubelet only sets it when the runtime is too old.
- The process tree check uses `pgrep -x sleep`: on a fresh cluster the only `sleep` processes are the two in pod `two`.

## Cleanup

`./demo.sh` deletes both clusters unless you set `KEEP=1`. To delete them by hand:

```sh
./demo.sh down       # = kind delete cluster --name crt; minikube delete -p crio
```

## Sources

- Kubernetes docs: "Container Runtimes", "Find out what container runtime is used on a node", "Pod Security Standards" (kubernetes.io)
- containerd: README, RELEASES.md, docs/cri/config.md (github.com/containerd/containerd)
- CRI-O: README and compatibility matrix (github.com/cri-o/cri-o)
- crun README (github.com/containers/crun)
