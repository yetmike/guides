# guides

Runnable companion files for my YouTube videos: commands, scripts and code you can copy and run.
One folder per video. Channel: [YouTube](https://www.youtube.com/channel/UCAjzppzNLxTCZLzeL7hEqTw) · Courses and practice tests: [yetmike.com](https://yetmike.com)

| Folder | Video | What's inside |
|---|---|---|
| [ml-kem-768](ml-kem-768/) | Your Browser Already Uses Post-Quantum Crypto (ML-KEM Explained) | OpenSSL 3.5 demo, Go `crypto/mlkem` demo, the ML-KEM-768 math in plain Python |
| [aws-secrets-rotation](aws-secrets-rotation/) | AWS Secrets Manager Rotation with Lambda, Explained with a Live Demo | rotation Lambda (Python), Terraform, the bash app, a local test |
| [alternat-nat-gateway](alternat-nat-gateway/) | AWS NAT Gateway Is Too Expensive. Do This Instead | AlterNAT Terraform (1 zone, small instance), failover test script |

## No secrets, ever

This repo is public. Demos that create keys do it in a temp directory and delete them.
Guard rails: `.gitignore` for keys/env/state files, a gitleaks scan on every push (GitHub Actions),
and GitHub secret scanning with push protection. Contributors: run `pre-commit install` once per clone.

Code here is MIT licensed (see LICENSE).
