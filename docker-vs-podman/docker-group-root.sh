#!/bin/sh
# Shows that the docker group is root on the host. Run it as a normal user who is in the docker group.
# Read-only: it lists the host's root folder from inside a container and changes nothing.
set -e
echo '$ id'; id
echo '$ ps -o user,pid,comm -C dockerd'; ps -o user,pid,comm -C dockerd || echo '(no dockerd on this machine: Docker Desktop runs it inside a VM)'
echo '$ ls -l /var/run/docker.sock'; ls -lL /var/run/docker.sock
echo '$ docker run --rm alpine id'; docker run --rm alpine id
echo '$ docker run --rm -v /:/host alpine ls /host'; docker run --rm -v /:/host alpine ls /host
