# Docker vs Podman

Companion files for the video **Podman vs Docker: Why Podman Lost (and Where It Still Wins)**.
The film shows why the `docker` group is root on your host, and how rootless Podman maps root inside a container to your own user.
These scripts let you see both on your own machine.

| File | What it shows |
|---|---|
| [`docker-group-root.sh`](docker-group-root.sh) | `dockerd` runs as root, the socket belongs to the `docker` group, and a user in that group can mount the host's `/` into a container |
| [`podman-rootless.sh`](podman-rootless.sh) | rootless Podman: `uid 0` inside the container, your own user on the host |
| [`web.container`](web.container) | the Quadlet file from the film (Podman 4.4+): a container as a normal systemd user service |

## 1. The docker group is root

Needs: Linux with Docker Engine, your user in the `docker` group (`sudo usermod -aG docker $USER`, then log in again).
On Docker Desktop (Mac, Windows) `dockerd` runs inside a VM, so the `ps` line finds nothing and `/host` is the VM's root, not your Mac's.

```sh
./docker-group-root.sh
```

Expected output (trimmed):

```
$ id
uid=1000(you) gid=1000(you) groups=1000(you),...,984(docker)
$ ps -o user,pid,comm -C dockerd
USER         PID COMMAND
root        2926 dockerd
$ ls -l /var/run/docker.sock
srw-rw---- 1 root docker 0 ... /var/run/docker.sock
$ docker run --rm alpine id
uid=0(root) gid=0(root) groups=0(root),...
$ docker run --rm -v /:/host alpine ls /host
bin
boot
...
root
...
```

You never typed `sudo`, and you can read `/host/root` (root's home folder). A container could also write there:
the script is read-only on purpose. Docker's own docs say the docker group grants root-level privileges, and the
OWASP Docker Security Cheat Sheet makes "do not expose the Docker daemon socket" rule number one.

To get out of this: remove yourself from the group (`sudo gpasswd -d $USER docker`) and use `sudo docker`,
or switch to Docker's rootless mode (opt-in since Docker 20.10), or use Podman.

## 2. Rootless Podman

Needs: Podman, or only Docker (the script then runs Podman inside the official `quay.io/podman/stable` image, about 400 MB, with `--privileged`).

```sh
./podman-rootless.sh
```

Expected output:

```
$ podman run --rm docker.io/library/alpine id
uid=0(root) gid=0(root) groups=...
$ podman unshare cat /proc/self/uid_map   # inside-uid  host-uid  count
         0       1000          1
         1          1        999
      1000       1001      64535
```

Read the first row: uid 0 inside the container is uid 1000 on the host, which is you. No daemon, no root.
The other rows come from `/etc/subuid` and differ per machine: the output above is from inside the `quay.io/podman/stable` image; on a normal install the second row is usually `1  100000  65536`.

Podman's docs say most users can `alias docker=podman`.

## 3. Quadlet (Podman 4.4+)

```sh
mkdir -p ~/.config/containers/systemd
cp web.container ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start web
curl -s localhost:8080 | head -4
```

Expected: the nginx welcome page. Stop it with `systemctl --user stop web`.
Caveat: this one is copied from the Podman docs (`podman-systemd.unit`) and was not run for the video.

## Tested with

Docker Engine 29.9.3 on Ubuntu, Podman 6.1.3 (inside `quay.io/podman/stable`).
