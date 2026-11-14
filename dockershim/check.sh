#!/bin/sh
# Dockershim check for the cluster in your current kubectl context. Read-only: it only runs get commands.
#   1. the container runtime of every node
#   2. every pod that mounts the Docker socket (hostPath ending in docker.sock)
# Needs: kubectl, jq.
set -eu

echo "== Container runtime per node"
kubectl get nodes -o custom-columns=NAME:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion

echo
echo "== Pods that mount docker.sock"
found=$(kubectl get pods -A -o json | jq -r '
  .items[]
  | select(any(.spec.volumes[]?; (.hostPath.path // "") | test("docker\\.sock$")))
  | "\(.metadata.namespace)/\(.metadata.name)"')
if [ -n "$found" ]; then
  echo "$found"
else
  echo "none"
fi
