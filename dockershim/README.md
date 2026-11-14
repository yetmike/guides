# Dockershim: check your own nodes

Companion to the video **Kubernetes Dropped Docker? What Really Happened With Dockershim**.

Two read-only checks to run before a Kubernetes upgrade:

1. Which container runtime each node uses.
2. Which pods still mount the node's Docker socket (`/var/run/docker.sock`).

You can run them on your own cluster, or on a throwaway [kind](https://kind.sigs.k8s.io/) cluster as in the video.

## Files

| File | What |
|---|---|
| `check.sh` | both checks for the cluster in your current kubectl context (only `get` commands) |
| `sock-pod.yaml` | a test pod that mounts `/var/run/docker.sock`, so the second check has something to find |

## Needs

- `kubectl` and `jq` for `check.sh`
- for the demo cluster: Docker and `kind` (the video used kind v0.30.0, node image `kindest/node:v1.34.0`)

## Run it on your cluster

```sh
./check.sh
```

Expected output on a containerd node:

```
== Container runtime per node
NAME                    VERSION   RUNTIME
my-node-1               v1.34.0   containerd://2.1.3

== Pods that mount docker.sock
none
```

How to read it:

- `containerd://...` or `cri-o://...`: the node talks CRI to the runtime directly.
- `docker://...` on Kubernetes 1.24 or newer: that node runs Docker Engine through cri-dockerd.
- Every pod listed under "Pods that mount docker.sock" expects Docker Engine on its node. On a containerd or CRI-O node that socket does not exist, so the pod's docker commands fail.

## Reproduce the demo (throwaway kind cluster)

```sh
kind create cluster --name demo --wait 120s

# 1. the runtime column
kubectl get nodes -o wide

# 2. pods that mount docker.sock (the quick grep from the video, then the exact check)
kubectl get pods -A -o yaml | grep -c docker.sock     # 0 on a fresh cluster
./check.sh

# inside the node: no docker.sock, only the containerd socket
docker exec demo-control-plane ls /var/run/docker.sock /run/containerd/containerd.sock

# docker ps does not exist in the node; crictl is the CRI tool
docker exec demo-control-plane crictl ps --name kube-apiserver
```

Expected (names and IDs differ on your machine):

```
NAME                 STATUS   ROLES           AGE   VERSION   ...   CONTAINER-RUNTIME
demo-control-plane   Ready    control-plane   63s   v1.34.0   ...   containerd://2.1.3

ls: cannot access '/var/run/docker.sock': No such file or directory
/run/containerd/containerd.sock

CONTAINER       IMAGE           CREATED          STATE     NAME             ATTEMPT   ...
92daddfc2c1d4   90550c43ad2bc   About a minute   Running   kube-apiserver   0         ...
```

Now give the check something to find:

```sh
kubectl apply -f sock-pod.yaml
./check.sh            # lists default/old-ci-job
kubectl delete -f sock-pod.yaml
```

Clean up:

```sh
kind delete cluster --name demo
```

## Caveats

- `check.sh` only sees running pods. Also search your manifests, Helm charts and CI configs for `docker.sock`, and node scripts for `docker ps` or `systemctl restart docker`.
- The grep from the video counts lines, not pods: any match means "look closer". `check.sh` lists the pods.
- `sock-pod.yaml` leaves the hostPath `type` empty. On a containerd node the kubelet then creates an empty directory at `/var/run/docker.sock`, so the test pod starts but nothing can talk to Docker through it. That is exactly the failure an old CI job would hit.
- A pod that mounts the whole `/var/run` directory is not caught by the check. Search for that too if your agents do it.

## Sources

- Kubernetes docs: "Check whether dockershim removal affects you" and "Find out what container runtime is used on a node" (kubernetes.io)
- Kubernetes 1.20 and 1.24 release announcements, "Don't Panic: Kubernetes and Docker" (kubernetes.io/blog)
- KEP-2221, Removing dockershim from kubelet (github.com/kubernetes/enhancements)
