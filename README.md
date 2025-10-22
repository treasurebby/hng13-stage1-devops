# DevOps Stage 1 — Automated Deployment Script

This repository contains `deploy.sh`, a POSIX-style Bash script that automates cloning a Git repository and deploying it on a remote Linux host as a Dockerized service with Nginx as a reverse proxy.

## What it does (high level)
- Collects deployment parameters interactively (repo URL, PAT, branch, remote SSH details, port)
- Clones or updates the repository locally
- Validates presence of `Dockerfile` or `docker-compose.yml`
- SSHs to the remote host, updates system packages, installs Docker / docker-compose plugin and Nginx if missing
- Transfers project files via `rsync`
- Builds and runs the containers (supports `docker compose` or plain `Dockerfile`)
- Creates an Nginx site config to proxy HTTP (80) to the container's internal port
- Validates deployment via local and remote curl checks
- Logs everything to `deploy_YYYYMMDD_HHMMSS.log`
- Supports `--cleanup` flag to remove deployed resources (basic)

## Prerequisites
- A Unix-like environment to run `deploy.sh` (Linux or MacOS). Running from Windows requires WSL or Git Bash that supports POSIX shell behavior.
- `ssh`, `rsync`, `git`, and `curl` installed locally.
- SSH access to the remote Linux host with a user that can use `sudo`.
- Docker (engine) and `docker compose` (plugin) will be installed on the remote host by the script if missing.
- Nginx is installed (or will be installed by the script) on the remote host to act as a reverse proxy.

## Usage
1. Make executable:
```bash
chmod +x deploy.sh
```

2. Run interactively:
```bash
./deploy.sh
```
The script will prompt for:
- Git repository URL
- Personal Access Token (if private repo)
- Branch or tag to deploy
- Remote SSH host (user@host)
- Remote SSH port (optional)
- Remote deploy directory (optional)
- Application internal port (the port the container listens on)

3. Non-interactive / flags (examples)
- Run with cleanup to remove deployed resources:
```bash
./deploy.sh --cleanup
```
- Use environment variables to prefill values (example):
```bash
REPO_URL="https://github.com/owner/repo.git" \
REPO_BRANCH="main" \
SSH_HOST="user@1.2.3.4" \
APP_PORT="3000" \
./deploy.sh
```

## Flags and options
- `--cleanup` : Attempt to stop and remove containers, remove deployed files and Nginx site configuration created by the script.
- `--help` : Show basic help text and exit.

## Logging
The script writes a timestamped log file named `deploy_YYYYMMDD_HHMMSS.log` in the directory where it was run. Check this file if a deployment fails for detailed output.

## Troubleshooting
- SSH failures: ensure your SSH key is added to the remote user's `~/.ssh/authorized_keys` and `sshd` allows your authentication method.
- Permission errors on remote host: the script executes installation and service management with `sudo` — ensure the remote user has sudo privileges and that `sudo` doesn't require a TTY for password input.
- Firewall / port issues: ensure port 80 (for HTTP) and the application port are allowed through the remote host's firewall.
- If `docker compose` is unavailable after install, try connecting to the host and running `sudo systemctl restart docker` and re-run the script.

## Security notes
- Avoid typing long-lived personal access tokens in insecure environments. Consider using temporary deploy keys or CI-based secrets in production.
- The script may enable installation of packages on the remote host; review it before running on sensitive systems.

## Next steps / Improvements
- Add unit/integration tests for portions that can be validated locally.
- Add a `--dry-run` mode to show planned actions without executing them.
- Add support for TLS with Let's Encrypt.
- Integrate with CI/CD (GitHub Actions / GitLab CI) for automated deployments on merge.
