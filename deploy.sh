#!/usr/bin/env bash
# Bash script for automated Dockerized app deployment to remote Linux host.
# Author: (you)
# Usage: ./deploy.sh [--help] [--dry-run] [--ssh-port N] [--cleanup]
# Make executable: chmod +x deploy.sh

set -o errexit
set -o nounset
set -o pipefail

# -------- CONFIG / GLOBALS --------
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOGFILE="deploy_${TIMESTAMP}.log"
WORKDIR="$(pwd)"
TMPDIR="$(mktemp -d 2>/dev/null || mktemp -d -t deploytmp)"
# Defaults (can be overridden by env vars or CLI flags)
SSH_PORT=""
DRY_RUN=false
NON_INTERACTIVE=false
# Warning: StrictHostKeyChecking=no is insecure; configurable in future
SSH_OPTS_BASE="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
CLEANUP_REQUESTED=${CLEANUP_REQUESTED:-false}

# Exit codes (meaningful)
EC_BAD_INPUT=10
EC_GIT_FAIL=11
EC_SSH_FAIL=12
EC_REMOTE_PREP_FAIL=13
EC_DEPLOY_FAIL=14
EC_NGINX_FAIL=15
EC_VALIDATION_FAIL=16

# -------- HELPERS / LOGGING --------
log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOGFILE"
}

die() {
  local code=${1:-1}
  shift || true
  log "ERROR: $*"
  echo "See $LOGFILE for details."
  exit "$code"
}

info() { log "INFO: $*"; }
success() { log "SUCCESS: $*"; }

trap 'on_exit $?' EXIT

on_exit() {
  code=$1
  if [ "$code" -ne 0 ]; then
    log "Script exited with code $code"
  else
    log "Script completed successfully"
  fi
  # cleanup
  if [ -d "$TMPDIR" ]; then
    rm -rf "$TMPDIR"
  fi
}

# -------- INPUT / VALIDATION --------
print_help() {
  cat <<'EOT'
Usage: deploy.sh [options]

Options:
  --help            Show this help and exit
  --dry-run         Print actions that would be taken, don't execute remote changes
  --ssh-port PORT   Use non-default SSH port for remote connections
  --cleanup         Run cleanup mode (stop/remove containers, nginx config)
  --non-interactive Use env vars and fail if required values missing

You can also set env vars: REPO_URL, PAT, BRANCH, REMOTE_USER, REMOTE_HOST,
SSH_KEY_PATH, CONTAINER_PORT, REMOTE_APP_DIR
EOT
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help)
        print_help; exit 0;;
      --dry-run)
        DRY_RUN=true; shift;;
      --cleanup)
        CLEANUP_REQUESTED=true; shift;;
      --ssh-port)
        if [ -n "${2:-}" ]; then SSH_PORT="$2"; shift 2; else die $EC_BAD_INPUT "--ssh-port requires a value"; fi ;;
      --non-interactive)
        NON_INTERACTIVE=true; shift;;
      --*)
        die $EC_BAD_INPUT "Unknown option: $1";;
      *)
        # positional, ignore
        shift;;
    esac
  done
}

info "Starting deployment - logging to $LOGFILE"

parse_args "$@"

# Prompt helper: use env var if present, otherwise interactive prompt
prompt() {
  local prompt_msg="$1"; local def="${2:-}"; local envvar_name="${3:-}"
  # If env var specified and set, use it
  if [ -n "${envvar_name:-}" ] && [ -n "${!envvar_name:-}" ]; then
    echo "${!envvar_name}"; return 0
  fi
  if [ "$NON_INTERACTIVE" = true ]; then
    # Non-interactive mode must have env var set
    if [ -n "$def" ]; then
      echo "$def"; return 0
    fi
    die $EC_BAD_INPUT "Required value for: $prompt_msg"
  fi
  if [ -n "$def" ]; then
    printf "%s [%s]: " "$prompt_msg" "$def"
  else
    printf "%s: " "$prompt_msg"
  fi
  IFS= read -r val || true
  if [ -z "$val" ]; then
    echo "$def"
  else
    echo "$val"
  fi
}

info "DRY_RUN=$DRY_RUN SSH_PORT=${SSH_PORT:-'(default 22)'}"

# Collect parameters (interactive or via env)
REPO_URL="${REPO_URL:-$(prompt 'Git repository URL (HTTPS)' '' REPO_URL)}"
if [ -z "$REPO_URL" ]; then die $EC_BAD_INPUT "No repo URL"; fi
GIT_USERNAME="${GIT_USERNAME:-${GIT_USERNAME:-x-access-token}}"
# Read PAT silently if not provided via env
if [ -n "${PAT:-}" ]; then
  : # use provided
else
  if [ "$NON_INTERACTIVE" = true ]; then
    die $EC_BAD_INPUT "PAT must be set in non-interactive mode via env var PAT"
  fi
  printf 'Personal Access Token (PAT) — will not be stored permanently: '
  # read -s for silent input
  stty -echo || true
  IFS= read -r PAT || true
  stty echo || true
  printf '\n'
fi
BRANCH="${BRANCH:-$(prompt 'Branch name (default: main)' 'main' BRANCH)}"
REMOTE_USER="${REMOTE_USER:-$(prompt 'Remote SSH username' '' REMOTE_USER)}"
if [ -z "$REMOTE_USER" ]; then die $EC_BAD_INPUT "No remote username"; fi
REMOTE_HOST="${REMOTE_HOST:-$(prompt 'Remote server IP or hostname' '' REMOTE_HOST)}"
if [ -z "$REMOTE_HOST" ]; then die $EC_BAD_INPUT "No remote host"; fi
SSH_KEY_PATH="${SSH_KEY_PATH:-$(prompt 'Path to SSH private key (e.g. ~/.ssh/id_rsa)' '~/.ssh/id_rsa' SSH_KEY_PATH)}"
CONTAINER_PORT="${CONTAINER_PORT:-$(prompt 'Application internal container port (e.g., 8000)' '' CONTAINER_PORT)}"
if [ -z "$CONTAINER_PORT" ]; then die $EC_BAD_INPUT "No container port"; fi
REMOTE_APP_DIR="${REMOTE_APP_DIR:-$(prompt 'Remote app directory (absolute, e.g. /srv/myapp)' '/srv/myapp' REMOTE_APP_DIR)}"

# Tilde expansion for ssh key path
case "$SSH_KEY_PATH" in
  ~/*) SSH_KEY_PATH="$HOME/${SSH_KEY_PATH#~/}" ;;
  ~) SSH_KEY_PATH="$HOME" ;;
esac

# Basic validation
if [ ! -f "$SSH_KEY_PATH" ]; then
  die $EC_BAD_INPUT "SSH key not found at $SSH_KEY_PATH"
fi

info "Inputs: repo=$REPO_URL branch=$BRANCH remote=${REMOTE_USER}@${REMOTE_HOST}${SSH_PORT:+:$SSH_PORT} app_dir=${REMOTE_APP_DIR} container_port=${CONTAINER_PORT}"

# -------- CLONE OR UPDATE REPO LOCALLY --------
REPO_NAME="$(basename "$REPO_URL" .git)"
CLONE_DIR="${WORKDIR}/${REPO_NAME}"

git_clone_or_update() {
  info "Preparing to fetch repository"
  # Use temporary GIT_ASKPASS script to avoid putting PAT into URL
  GIT_ASKPASS_SCRIPT="$TMPDIR/git_askpass.sh"
  cat > "$GIT_ASKPASS_SCRIPT" <<EOF
#!/bin/sh
# askpass helper: return the PAT when git asks for password
echo "$PAT"
EOF
  chmod +x "$GIT_ASKPASS_SCRIPT"

  if [ -d "$CLONE_DIR/.git" ]; then
    info "Repository already cloned. Pulling latest from $BRANCH"
    (
      cd "$CLONE_DIR"
      GIT_ASKPASS="$GIT_ASKPASS_SCRIPT" GIT_TERMINAL_PROMPT=0 git fetch --prune origin >>"$LOGFILE" 2>&1 || die $EC_GIT_FAIL "git fetch failed"
      GIT_ASKPASS="$GIT_ASKPASS_SCRIPT" GIT_TERMINAL_PROMPT=0 git checkout "$BRANCH" >>"$LOGFILE" 2>&1 || die $EC_GIT_FAIL "git checkout $BRANCH failed"
      GIT_ASKPASS="$GIT_ASKPASS_SCRIPT" GIT_TERMINAL_PROMPT=0 git pull origin "$BRANCH" >>"$LOGFILE" 2>&1 || die $EC_GIT_FAIL "git pull failed"
    )
    success "Updated local repo at $CLONE_DIR"
  else
    info "Cloning repository into $CLONE_DIR"
    # Clone with credentials via askpass
    env GIT_ASKPASS="$GIT_ASKPASS_SCRIPT" GIT_TERMINAL_PROMPT=0 git clone --branch "$BRANCH" "$REPO_URL" "$CLONE_DIR" >>"$LOGFILE" 2>&1 || die $EC_GIT_FAIL "git clone failed"
    success "Cloned repo to $CLONE_DIR"
  fi
  # Remove askpass after use
  rm -f "$GIT_ASKPASS_SCRIPT"
}

git_clone_or_update

# Validate presence of Dockerfile or docker-compose.yml
if [ -f "$CLONE_DIR/Dockerfile" ]; then
  info "Dockerfile found in repo"
elif [ -f "$CLONE_DIR/docker-compose.yml" ] || [ -f "$CLONE_DIR/docker-compose.yaml" ]; then
  info "docker-compose file found in repo"
else
  die $EC_GIT_FAIL "No Dockerfile or docker-compose.yml found in $CLONE_DIR"
fi

# Build SSH options including port if provided
SSH_OPTS="$SSH_OPTS_BASE"
if [ -n "$SSH_PORT" ]; then
  SSH_OPTS="$SSH_OPTS -p $SSH_PORT"
fi

# -------- SSH CONNECTIVITY CHECK --------
SSH_TARGET="${REMOTE_USER}@${REMOTE_HOST}"
info "Checking SSH connectivity to $SSH_TARGET"
if [ "$DRY_RUN" = true ]; then
  info "DRY_RUN: would check SSH connectivity to $SSH_TARGET"
else
  if ! ssh -i "$SSH_KEY_PATH" $SSH_OPTS "$SSH_TARGET" 'echo SSH_OK' >/dev/null 2>&1; then
    die $EC_SSH_FAIL "Unable to SSH to $SSH_TARGET with provided key"
  fi
  success "SSH connectivity OK"
fi

# -------- REMOTE PREP: update, install Docker, docker-compose, nginx --------
remote_exec() {
  # Usage: remote_exec "command here"
  if [ "$DRY_RUN" = true ]; then
    info "DRY_RUN: remote_exec would run on $SSH_TARGET: $1"
    return 0
  fi
  ssh -i "$SSH_KEY_PATH" $SSH_OPTS "$SSH_TARGET" "bash -lc '$1'"
}

info "Preparing remote environment (update & install check)"

prepare_remote() {
  # Basic update + install if missing (works on Debian/Ubuntu; attempts fallback for yum)
  read -r -d '' PREP_SCRIPT <<'ENDSSH'
set -e
export DEBIAN_FRONTEND=noninteractive || true

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"; return; fi
  if command -v yum >/dev/null 2>&1; then echo "yum"; return; fi
  if command -v apk >/dev/null 2>&1; then echo "apk"; return; fi
  echo "none"
}

PM="$(detect_pkg_mgr)"

if [ "$PM" = "apt" ]; then
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https
  # Docker install
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
  fi
  # docker-compose plugin (compose v2)
  if ! docker compose version >/dev/null 2>&1; then
    sudo apt-get install -y docker-compose-plugin || true
  fi
  # nginx
  if ! command -v nginx >/dev/null 2>&1; then
    sudo apt-get install -y nginx
  fi
  sudo systemctl enable --now docker || true
  sudo systemctl enable --now nginx || true
elif [ "$PM" = "yum" ]; then
  sudo yum makecache -y
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
  fi
  if ! command -v nginx >/dev/null 2>&1; then
    sudo yum install -y nginx
  fi
  sudo systemctl enable --now docker || true
  sudo systemctl enable --now nginx || true
else
  echo "No known package manager; please install docker and nginx manually" >&2
  exit 2
fi

# Add user to docker group if necessary
if [ "$(id -u)" -ne 0 ]; then
  # prefer REMOTE_USER if provided in env, else fall back to current user
  TARGET_USER="${REMOTE_USER:-$USER}"
  if groups "$TARGET_USER" 2>/dev/null | grep -qw docker; then
    echo "user_in_docker_group"
  else
    sudo usermod -aG docker "$TARGET_USER" || true
    echo "added_user_to_docker"
  fi
fi

# Print versions
docker --version || true
docker compose version || true
nginx -v || true
ENDSSH

  remote_exec "$PREP_SCRIPT" >>"$LOGFILE" 2>&1 || die $EC_REMOTE_PREP_FAIL "Remote preparation failed"
  success "Remote environment prepared (Docker, docker-compose plugin, nginx checked)"
}

prepare_remote

# -------- TRANSFER FILES to remote (rsync) --------
info "Transferring project files to remote host via rsync"
transfer_project() {
  # ensure remote directory exists
  remote_exec "mkdir -p '$REMOTE_APP_DIR' && chmod 755 '$REMOTE_APP_DIR'" >>"$LOGFILE" 2>&1 || die $EC_SSH_FAIL "Unable to create remote app directory"

  # .git excluded in transfer to avoid sending local credentials; send necessary files
  if [ "$DRY_RUN" = true ]; then
    info "DRY_RUN: would rsync $CLONE_DIR/ to $SSH_TARGET:$REMOTE_APP_DIR/ (excludes .git and $LOGFILE)"
  else
    rsync -avz -e "ssh -i $SSH_KEY_PATH $SSH_OPTS" --delete --exclude='.git' --exclude="$LOGFILE" "$CLONE_DIR"/ "$SSH_TARGET":"$REMOTE_APP_DIR"/ >>"$LOGFILE" 2>&1 || die $EC_SSH_FAIL "rsync failed"
  fi
  success "Project files transferred to $REMOTE_APP_DIR"
}

transfer_project

# -------- REMOTE DEPLOY (docker build/run or docker-compose) --------
info "Starting remote deployment"
deploy_remote() {
  # Build a remote deploy script that uses a project name to avoid duplicate networks
  PROJECT_NAME="${REPO_NAME//[^a-zA-Z0-9]/}_proj"

  read -r -d '' DEPLOY_SCRIPT <<'ENDSSH'
set -euo pipefail
cd "$REMOTE_APP_DIR" || exit 2

# Stop previously running compose by project name if present
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  echo "Using docker compose (project: $PROJECT_NAME) to deploy"
  sudo docker compose --project-name "$PROJECT_NAME" down || true
  sudo docker compose --project-name "$PROJECT_NAME" pull || true
  sudo docker compose --project-name "$PROJECT_NAME" up -d --build
  sudo docker compose --project-name "$PROJECT_NAME" ps
else
  # If no compose, handle Dockerfile
  if [ -f Dockerfile ]; then
    IMAGE_NAME="$PROJECT_NAME:latest"
    echo "Building image $IMAGE_NAME"
    sudo docker build -t "$IMAGE_NAME" .
    # Stop old container(s) matching name pattern
    if sudo docker ps -a --format '{{.Names}}' | grep -q '^app$'; then
      sudo docker rm -f app || true
    fi
    sudo docker run -d --name app -p 127.0.0.1:${CONTAINER_PORT}:${CONTAINER_PORT} "$IMAGE_NAME"
  else
    echo "No docker-compose.yml or Dockerfile found on remote" >&2
    exit 3
  fi
fi

# Post-run: health check with retries
TRIES=10
SLEEP=2
COUNT=0
while [ $COUNT -lt $TRIES ]; do
  if curl -sS -m 5 "http://127.0.0.1:${CONTAINER_PORT}/" >/dev/null 2>&1; then
    echo "local_app_ok"
    exit 0
  fi
  COUNT=$((COUNT+1))
  sleep $SLEEP
done
echo "local_app_maybe_unreachable"
exit 0
ENDSSH

  # Run on remote (respect DRY_RUN)
  if [ "$DRY_RUN" = true ]; then
    info "DRY_RUN: would deploy project on remote $SSH_TARGET (project name: $PROJECT_NAME)"
  else
    ssh -i "$SSH_KEY_PATH" $SSH_OPTS "$SSH_TARGET" "REPO_NAME='$REPO_NAME' PROJECT_NAME='$PROJECT_NAME' REMOTE_APP_DIR='$REMOTE_APP_DIR' CONTAINER_PORT='$CONTAINER_PORT' bash -s" < <(printf '%s\n' "$DEPLOY_SCRIPT") >>"$LOGFILE" 2>&1 || die $EC_DEPLOY_FAIL "Remote deployment failed"
    success "Remote deployment completed"
  fi
}

deploy_remote

# -------- NGINX CONFIGURATION (remote) --------
info "Configuring Nginx as reverse proxy on remote host"

configure_nginx_remote() {
  # Build Nginx server block content
  NGINX_CONF="server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    access_log /var/log/nginx/deployed_app_access.log;
    error_log /var/log/nginx/deployed_app_error.log;

    location / {
        proxy_pass http://127.0.0.1:${CONTAINER_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 90;
    }
}
"

  # Write Nginx config remotely (idempotent)
  # Use a deterministic file name so repeated runs overwrite the same config
  REMOTE_CONF_PATH="/etc/nginx/sites-available/deployed_app.conf"
  # If sites-available not present, will symlink into conf.d instead
  if [ "$DRY_RUN" = true ]; then
    info "DRY_RUN: would write nginx config to $REMOTE_CONF_PATH (or conf.d if sites-available absent)"
  else
    remote_exec "bash -lc 'cat > \"$REMOTE_CONF_PATH\" <<\"NGCONF\"\n$NGINX_CONF\nNGCONF'" >>"$LOGFILE" 2>&1 || die $EC_NGINX_FAIL "Failed to write nginx config"

    # Enable config
    remote_exec "bash -lc 'if [ -d /etc/nginx/sites-enabled ]; then ln -sf \"$REMOTE_CONF_PATH\" /etc/nginx/sites-enabled/deployed_app.conf; else ln -sf \"$REMOTE_CONF_PATH\" /etc/nginx/conf.d/deployed_app.conf; fi'" >>"$LOGFILE" 2>&1 || die $EC_NGINX_FAIL "Failed to enable nginx config"

    # Test and reload nginx
    remote_exec "sudo nginx -t" >>"$LOGFILE" 2>&1 || die $EC_NGINX_FAIL "Nginx config test failed"
    remote_exec "sudo systemctl reload nginx || sudo service nginx reload" >>"$LOGFILE" 2>&1 || die $EC_NGINX_FAIL "Failed to reload nginx"
    success "Nginx configured to proxy to 127.0.0.1:${CONTAINER_PORT}"
  fi
}

configure_nginx_remote

# -------- VALIDATION --------
info "Validating deployment locally and remotely"

validate() {
  # 1) Docker running remote (fatal)
  if ! remote_exec "sudo systemctl is-active --quiet docker" >>"$LOGFILE" 2>&1; then
    die $EC_VALIDATION_FAIL "Docker service not active on remote"
  fi

  # 2) Container existence / listening
  remote_exec "sudo docker ps --format '{{.Names}} {{.Status}} {{.Ports}}' | grep -E 'app|$PROJECT_NAME' || true" >>"$LOGFILE" 2>&1 || log "Warning: could not find expected containers by name"
  remote_exec "ss -ltnp | grep -E ':${CONTAINER_PORT} ' || true" >>"$LOGFILE" 2>&1 || log "Warning: port ${CONTAINER_PORT} not found listening (may be binded differently)"

  # 3) curl local from remote (app should respond)
  if [ "$DRY_RUN" = true ]; then
    info "DRY_RUN: would curl http://127.0.0.1:${CONTAINER_PORT} on remote"
  else
    remote_exec "curl -sS -m 5 http://127.0.0.1:${CONTAINER_PORT} || true" >>"$LOGFILE" 2>&1 || log "Warning: remote local curl failed (app may not respond with 200)"
  fi

  # 4) curl via nginx (public on remote)
  if [ "$DRY_RUN" = true ]; then
    info "DRY_RUN: would curl http://127.0.0.1/ on remote to test nginx"
  else
    if ssh -i "$SSH_KEY_PATH" $SSH_OPTS "$SSH_TARGET" "curl -sS -m 5 http://127.0.0.1/" >/dev/null 2>&1; then
      success "Nginx successfully returned content locally on remote"
    else
      log "Warning: curl via nginx on remote failed"
    fi
  fi

  # 5) From this machine, try curl to remote host port 80
  if [ "$DRY_RUN" = true ]; then
    info "DRY_RUN: would curl http://${REMOTE_HOST}/ from this machine"
  else
    if curl -sS -m 8 "http://${REMOTE_HOST}/" >/dev/null 2>&1; then
      success "Deployment accessible from this machine via http://${REMOTE_HOST}/"
    else
      log "Warning: Could not reach http://${REMOTE_HOST}/ from this machine (network or firewall may block)."
    fi
  fi
}

validate

# -------- OPTIONAL CLEANUP FLAG HANDLING --------
if [ "$CLEANUP_REQUESTED" = true ]; then
  info "Cleanup requested: removing app containers, images, nginx config and files"
  if [ "$DRY_RUN" = true ]; then
    info "DRY_RUN: would remove nginx config at /etc/nginx/sites-available/deployed_app.conf and symlinks, stop containers and remove $REMOTE_APP_DIR/*"
  else
    remote_exec "set -e
    if [ -f /etc/nginx/sites-available/deployed_app.conf ]; then
      sudo rm -f /etc/nginx/sites-enabled/deployed_app.conf || true
      sudo rm -f /etc/nginx/conf.d/deployed_app.conf || true
      sudo rm -f /etc/nginx/sites-available/deployed_app.conf || true
      sudo systemctl reload nginx || true
    fi
    cd $REMOTE_APP_DIR || true
    sudo docker compose down || true
    sudo docker rm -f app || true
    # Remove files
    sudo rm -rf $REMOTE_APP_DIR/*
  " >>"$LOGFILE" 2>&1 || log "Cleanup had some failures"
    success "Cleanup attempted. Check logs for details."
  fi
fi

success "Deployment finished — check $LOGFILE for the full run output."

exit 0
