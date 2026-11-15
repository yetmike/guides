#!/bin/sh
# containerd vs CRI-O: every terminal moment from the video, on two throwaway clusters.
#   kind "crt"      -> containerd
#   minikube "crio" -> CRI-O (Kubernetes pinned to v1.35.8 so CRI-O 1.35 matches it)
# Needs: Docker, kind v0.33+, minikube, kubectl 1.37+. Optional: capsh (libcap) to decode capability masks.
# Usage: ./demo.sh          run everything, then delete both clusters
#        KEEP=1 ./demo.sh   keep the clusters (delete later: ./demo.sh down)
set -e
cd "$(dirname "$0")"

if [ "$1" = down ]; then
  kind delete cluster --name crt
  minikube delete -p crio
  exit 0
fi

run() { printf '\n$ %s\n' "$*"; sh -c "$*"; }

kind get clusters 2>/dev/null | grep -qx crt || kind create cluster --name crt --wait 180s
minikube start -p crio --container-runtime=cri-o --driver=docker --cpus=2 --memory=3g --kubernetes-version=v1.35.8

for c in kind-crt crio; do
  kubectl --context $c delete pod caps capsdrop two --ignore-not-found >/dev/null
  kubectl --context $c run caps --image=busybox:1.37 --restart=Never -- grep CapEff /proc/1/status
  kubectl --context $c apply -f capsdrop.yaml -f two.yaml
  for p in caps capsdrop; do kubectl --context $c wait --for=jsonpath='{.status.phase}'=Succeeded pod/$p --timeout=180s; done
  kubectl --context $c wait --for=condition=Ready pod/two --timeout=180s
done

echo; echo '== 1. Which runtime runs your pods (last column)'
run kubectl --context kind-crt get nodes -o wide
run kubectl --context crio get nodes -o wide

echo; echo '== 2. The same answer on the node'
run docker exec crt-control-plane crictl version
run docker exec crio crictl version

echo; echo '== 3. Configuration'
run docker exec crt-control-plane head -3 /etc/containerd/config.toml
run "docker exec crt-control-plane sh -c 'containerd config dump 2>/dev/null | grep -m2 cri.v1'"
run docker exec crio ls /etc/crio/crio.conf.d

echo; echo '== 4. Where the images live'
run docker exec crt-control-plane ctr images ls -q
run "docker exec crt-control-plane ctr -n k8s.io images ls -q | grep -v sha256 | head -4"
run docker exec crio ls /var/lib/containers/storage

echo; echo '== 5. Process tree: one shim per pod vs one conmon per container'
run "docker exec crt-control-plane ps -e | grep -m3 shim"
run "docker exec crio ps -e | grep -m3 conmon"
echo; echo '# pod "two" (2 containers, both run sleep): the parent processes of the two sleeps'
run "docker exec crt-control-plane sh -c 'ps -o pid,comm -p \$(for p in \$(pgrep -x sleep); do ps -o ppid= -p \$p; done | sort -u | xargs | tr \" \" ,)'"
run "docker exec crio sh -c 'ps -o pid,comm -p \$(for p in \$(pgrep -x sleep); do ps -o ppid= -p \$p; done | sort -u | xargs | tr \" \" ,)'"

echo; echo '== 6. Default OCI runtime'
run "docker exec crt-control-plane crictl info | grep -m1 defaultRuntimeName"
run "docker exec crio crictl info | grep -m1 DefaultRuntime"

echo; echo '== 7. Default capabilities, then drop ALL'
for c in kind-crt crio; do
  run kubectl --context $c logs caps
  if command -v capsh >/dev/null; then
    m=$(kubectl --context $c logs caps | awk '{print $2}')
    l=$(capsh --decode=$m | cut -d= -f2)
    echo "$(echo $l | tr , '\n' | wc -l) capabilities: $l"
  fi
done
run kubectl --context kind-crt logs capsdrop
run kubectl --context crio logs capsdrop

if [ -z "$KEEP" ]; then
  echo; echo '== Cleanup'
  kind delete cluster --name crt
  minikube delete -p crio
fi
