#!/bin/sh
# Rootless Podman: root inside the container, your own user on the host.
# Uses your podman if you have one, else runs podman inside the quay.io/podman/stable image (needs Docker).
set -e
S='id; podman --version; echo "$ podman run --rm docker.io/library/alpine id"; podman run --rm docker.io/library/alpine id;
echo "$ podman unshare cat /proc/self/uid_map   # inside-uid  host-uid  count"; podman unshare cat /proc/self/uid_map'
if command -v podman >/dev/null; then sh -c "$S"
else docker run --rm --privileged --user podman quay.io/podman/stable sh -c "$S" 2>/dev/null; fi
