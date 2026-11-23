# guides

Runnable companion files for my YouTube videos: commands, scripts and code you can copy and run.
One folder per video. Channel: [YouTube](https://www.youtube.com/channel/UCAjzppzNLxTCZLzeL7hEqTw) · Courses and practice tests: [yetmike.com](https://yetmike.com)

| Folder | Video | What's inside |
|---|---|---|
| [ml-kem-768](ml-kem-768/) | Your Browser Already Uses Post-Quantum Crypto (ML-KEM Explained) | OpenSSL 3.5 demo, Go `crypto/mlkem` demo, the ML-KEM-768 math in plain Python |
| [aws-secrets-rotation](aws-secrets-rotation/) | AWS Secrets Manager Rotation with Lambda, Explained with a Live Demo | rotation Lambda (Python), Terraform, the bash app, a local test |
| [alternat-nat-gateway](alternat-nat-gateway/) | AWS NAT Gateway Is Too Expensive. Do This Instead | AlterNAT Terraform (1 zone, small instance), failover test script |
| [redis-vs-dragonfly](redis-vs-dragonfly/) | Redis vs Dragonfly | Kubernetes manifests (Redis single, cluster, io-threads; Dragonfly), load generator (Go), run script, Grafana dashboards, results |
| [open-source-licenses-history](open-source-licenses-history/) | The History of Open Source Licenses | license count of the packages on your Debian/Ubuntu machine (Python), method notes, sources for the quotes |
| [minio-vs-rustfs](minio-vs-rustfs/) | MinIO vs RustFS | Kubernetes manifests, MinIO built from source (Dockerfile), S3 load generator (Go), run scripts (speed ramps, node loss with SHA-256 verify, resource use), Grafana dashboards, results |
| [history-of-shells](history-of-shells/) | Why Bash Still Speaks 1979 (50 Years of Unix Shells) | Dockerfile with every shell from the film (bash, dash, zsh, fish, tcsh, ksh, BusyBox, Nushell, an unpatched bash 4.3), the nine terminal demos with expected output |
| [docker-vs-podman](docker-vs-podman/) | Podman vs Docker: Why Podman Lost (and Where It Still Wins) | the docker group is root (script), rootless Podman uid mapping (script, runs with or without Podman installed), the Quadlet file |
| [dockershim](dockershim/) | Kubernetes Dropped Docker? What Really Happened With Dockershim | `check.sh` (runtime per node, pods that mount docker.sock), a test pod, kind demo steps |
| [containerd-vs-crio](containerd-vs-crio/) | containerd vs CRI-O: Does It Actually Matter? | `demo.sh` (kind containerd + minikube CRI-O side by side: runtime column, crictl, config files, image stores, shim vs conmon, OCI runtime, default capabilities), two test pods |
| [what-claude-sends](what-claude-sends/) | Claude Code Privacy: I Read Every Request It Sends | mitmproxy capture script with an empty environment and throwaway config, redaction addon, a viewer for the captures, the fake key trick |

## No secrets, ever

This repo is public. Demos that create keys do it in a temp directory and delete them.
Guard rails: `.gitignore` for keys/env/state files, a gitleaks scan on every push (GitHub Actions),
and GitHub secret scanning with push protection. Contributors: run `pre-commit install` once per clone.

Code here is MIT licensed (see LICENSE).
