#!/usr/bin/env bash
set -Eeuo pipefail

# GitHub -> local staging -> Cloudflare R2 backup wrapper.
#
# This version is optimized for small VPS disks:
#   1. discover repositories with gh
#   2. back up one repository into a stable local staging directory
#   3. upload that staging directory to Restic/R2
#   4. delete the local staging directory after the upload succeeds
#   5. repeat for the next item
#
# Gists and account-level metadata are backed up as separate cleanup units.
# github-backup has a --repository filter, but it does not have an equivalent
# per-gist filter, so all gists are handled together as the "gists" item.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Optional: load .env if present. Credentials are still read as environment variables.
ENV_FILE="${ENV_FILE:-${REPO_DIR}/.env}"
if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

COMMAND="${1:-backup}"

log() {
  printf '[%s] %s\n' "$(date -Is)" "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "Required environment variable is not set: ${name}"
}

bool_is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

safe_name() {
  # Keep paths and Restic tags boring and portable.
  printf '%s' "$1" | sed -E 's#[^A-Za-z0-9._-]+#__#g; s#__+#_#g; s#^_+##; s#_+$##'
}

load_defaults() {
  export GITHUB_TOKEN_TYPE="${GITHUB_TOKEN_TYPE:-classic}"        # classic|fine
  export GITHUB_ACCOUNT_TYPE="${GITHUB_ACCOUNT_TYPE:-user}"       # user|org
  export GITHUB_BACKUP_LOG_LEVEL="${GITHUB_BACKUP_LOG_LEVEL:-info}"
  export GITHUB_BACKUP_PREFER_SSH="${GITHUB_BACKUP_PREFER_SSH:-false}"
  export GITHUB_BACKUP_INCLUDE_STARRED_REPOSITORY_CLONES="${GITHUB_BACKUP_INCLUDE_STARRED_REPOSITORY_CLONES:-false}"
  export GITHUB_BACKUP_EXTRA_ARGS="${GITHUB_BACKUP_EXTRA_ARGS:-}"
  export GITHUB_REPO_LIST_LIMIT="${GITHUB_REPO_LIST_LIMIT:-1000}"

  # Item-level controls. These defaults keep local disk usage low.
  export BACKUP_STAGING_ROOT="${BACKUP_STAGING_ROOT:-${HOME}/github-r2-backup-stage}"
  export BACKUP_CLEANUP_AFTER_UPLOAD="${BACKUP_CLEANUP_AFTER_UPLOAD:-true}"
  export BACKUP_DELETE_STALE_STAGE_BEFORE_ITEM="${BACKUP_DELETE_STALE_STAGE_BEFORE_ITEM:-true}"
  export BACKUP_INCLUDE_ACCOUNT_METADATA="${BACKUP_INCLUDE_ACCOUNT_METADATA:-true}"
  export BACKUP_INCLUDE_REPOSITORIES="${BACKUP_INCLUDE_REPOSITORIES:-true}"
  export BACKUP_INCLUDE_GISTS="${BACKUP_INCLUDE_GISTS:-true}"

  export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"

  export RESTIC_KEEP_DAILY="${RESTIC_KEEP_DAILY:-14}"
  export RESTIC_KEEP_WEEKLY="${RESTIC_KEEP_WEEKLY:-8}"
  export RESTIC_KEEP_MONTHLY="${RESTIC_KEEP_MONTHLY:-12}"
  export RESTIC_RUN_FORGET="${RESTIC_RUN_FORGET:-true}"
  export RESTIC_RUN_CHECK="${RESTIC_RUN_CHECK:-true}"
  export RESTIC_CHECK_READ_DATA_SUBSET="${RESTIC_CHECK_READ_DATA_SUBSET:-1G}"
}

validate_common_env() {
  require_env GITHUB_ACCOUNT
  require_env GITHUB_TOKEN
  require_env RESTIC_REPOSITORY
  require_env AWS_ACCESS_KEY_ID
  require_env AWS_SECRET_ACCESS_KEY

  if [[ -z "${RESTIC_PASSWORD:-}" && -z "${RESTIC_PASSWORD_FILE:-}" && -z "${RESTIC_PASSWORD_COMMAND:-}" ]]; then
    fail "Set one of RESTIC_PASSWORD, RESTIC_PASSWORD_FILE, or RESTIC_PASSWORD_COMMAND"
  fi

  case "${GITHUB_TOKEN_TYPE}" in
    classic|fine) ;;
    *) fail "GITHUB_TOKEN_TYPE must be 'classic' or 'fine'" ;;
  esac

  case "${GITHUB_ACCOUNT_TYPE}" in
    user|org) ;;
    *) fail "GITHUB_ACCOUNT_TYPE must be 'user' or 'org'" ;;
  esac

  [[ "${GITHUB_REPO_LIST_LIMIT}" =~ ^[0-9]+$ ]] || fail "GITHUB_REPO_LIST_LIMIT must be a positive integer"
}

check_requirements() {
  require_command git
  require_command gh
  require_command github-backup
  require_command restic

  if ! command -v git-lfs >/dev/null 2>&1; then
    log "WARNING: git-lfs is not installed. LFS backup may fail even though --lfs is enabled."
  fi
}

export_tool_tokens() {
  # gh prefers GH_TOKEN/GH_ENTERPRISE_TOKEN. github-backup uses the explicit
  # --token/--token-fine argument below. Set GH_TOKEN only for repository discovery.
  export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN}}"
}

restic_repo_exists() {
  restic snapshots >/dev/null 2>&1
}

init_restic() {
  load_defaults
  validate_common_env
  require_command restic

  if restic_repo_exists; then
    log "Restic repository already exists: ${RESTIC_REPOSITORY}"
    return 0
  fi

  log "Initializing restic repository: ${RESTIC_REPOSITORY}"
  restic init
}

base_github_backup_args() {
  local output_dir="$1"
  GITHUB_BACKUP_ARGS=(
    "${GITHUB_ACCOUNT}"
    --output-directory "${output_dir}"
    --log-level "${GITHUB_BACKUP_LOG_LEVEL}"
    --incremental
  )

  if [[ "${GITHUB_TOKEN_TYPE}" == "classic" ]]; then
    GITHUB_BACKUP_ARGS+=(--token "${GITHUB_TOKEN}")
  else
    GITHUB_BACKUP_ARGS+=(--token-fine "${GITHUB_TOKEN}")
  fi

  if [[ "${GITHUB_ACCOUNT_TYPE}" == "org" ]]; then
    GITHUB_BACKUP_ARGS+=(--organization)
  fi

  if bool_is_true "${GITHUB_BACKUP_PREFER_SSH}"; then
    GITHUB_BACKUP_ARGS+=(--prefer-ssh)
  fi

  if [[ -n "${GITHUB_BACKUP_EXTRA_ARGS}" ]]; then
    # Intentional word splitting for advanced users who pass extra CLI flags.
    # shellcheck disable=SC2206
    EXTRA_ARGS=( ${GITHUB_BACKUP_EXTRA_ARGS} )
    GITHUB_BACKUP_ARGS+=("${EXTRA_ARGS[@]}")
  fi
}

prepare_staging_dir() {
  local item_dir="$1"

  if [[ -e "${item_dir}" ]]; then
    if bool_is_true "${BACKUP_DELETE_STALE_STAGE_BEFORE_ITEM}"; then
      log "Removing stale staging directory before item: ${item_dir}"
      rm -rf -- "${item_dir}"
    else
      fail "Staging directory already exists: ${item_dir}. Remove it or set BACKUP_DELETE_STALE_STAGE_BEFORE_ITEM=true."
    fi
  fi

  mkdir -p -- "${item_dir}"
}

upload_and_cleanup_item() {
  local kind="$1"
  local label="$2"
  local item_dir="$3"
  local safe_kind safe_label
  safe_kind="$(safe_name "${kind}")"
  safe_label="$(safe_name "${label}")"

  log "Uploading item to Restic/R2: ${kind}:${label}"
  restic backup "${item_dir}" \
    --tag github \
    --tag "github-${GITHUB_ACCOUNT_TYPE}" \
    --tag "account-$(safe_name "${GITHUB_ACCOUNT}")" \
    --tag "kind-${safe_kind}" \
    --tag "item-${safe_label}"

  if bool_is_true "${BACKUP_CLEANUP_AFTER_UPLOAD}"; then
    log "Upload succeeded. Deleting local staging directory: ${item_dir}"
    rm -rf -- "${item_dir}"
  else
    log "Upload succeeded. Keeping local staging directory because BACKUP_CLEANUP_AFTER_UPLOAD=false: ${item_dir}"
  fi
}

backup_account_metadata() {
  local item_dir="${BACKUP_STAGING_ROOT}/account-metadata__$(safe_name "${GITHUB_ACCOUNT}")"
  prepare_staging_dir "${item_dir}"

  base_github_backup_args "${item_dir}"
  GITHUB_BACKUP_ARGS+=(
    --starred
    --watched
    --followers
    --following
  )

  log "Backing up account metadata for ${GITHUB_ACCOUNT}"
  github-backup "${GITHUB_BACKUP_ARGS[@]}"
  upload_and_cleanup_item "account-metadata" "${GITHUB_ACCOUNT}" "${item_dir}"
}

backup_repository() {
  local repo_name="$1"
  local item_dir="${BACKUP_STAGING_ROOT}/repository__$(safe_name "${GITHUB_ACCOUNT}")__$(safe_name "${repo_name}")"
  prepare_staging_dir "${item_dir}"

  base_github_backup_args "${item_dir}"
  GITHUB_BACKUP_ARGS+=(
    --repositories
    --repository "${repo_name}"
    --private
    --fork
    --bare
    --lfs
    --wikis
    --issues
    --issue-comments
    --issue-events
    --pulls
    --pull-comments
    --pull-commits
    --pull-details
    --labels
    --hooks
    --milestones
    --security-advisories
    --attachments
    --releases
    --assets
  )

  log "Backing up repository: ${GITHUB_ACCOUNT}/${repo_name}"
  github-backup "${GITHUB_BACKUP_ARGS[@]}"
  upload_and_cleanup_item "repository" "${GITHUB_ACCOUNT}/${repo_name}" "${item_dir}"
}

backup_gists() {
  local item_dir="${BACKUP_STAGING_ROOT}/gists__$(safe_name "${GITHUB_ACCOUNT}")"
  prepare_staging_dir "${item_dir}"

  base_github_backup_args "${item_dir}"
  GITHUB_BACKUP_ARGS+=(
    --gists
    --starred-gists
  )

  log "Backing up owned and starred gists for ${GITHUB_ACCOUNT}"
  github-backup "${GITHUB_BACKUP_ARGS[@]}"
  upload_and_cleanup_item "gists" "${GITHUB_ACCOUNT}" "${item_dir}"
}

backup_starred_repository_clones() {
  local item_dir="${BACKUP_STAGING_ROOT}/starred-repositories__$(safe_name "${GITHUB_ACCOUNT}")"
  prepare_staging_dir "${item_dir}"

  base_github_backup_args "${item_dir}"
  GITHUB_BACKUP_ARGS+=(
    --all-starred
    --bare
    --lfs
  )

  log "Backing up full clones of starred repositories for ${GITHUB_ACCOUNT}"
  log "WARNING: github-backup does not expose a per-starred-repo filter. This item can be very large."
  github-backup "${GITHUB_BACKUP_ARGS[@]}"
  upload_and_cleanup_item "starred-repositories" "${GITHUB_ACCOUNT}" "${item_dir}"
}

list_repositories() {
  export_tool_tokens
  gh repo list "${GITHUB_ACCOUNT}" \
    --limit "${GITHUB_REPO_LIST_LIMIT}" \
    --json name \
    --jq '.[].name'
}

run_forget_and_check() {
  if bool_is_true "${RESTIC_RUN_FORGET}"; then
    log "Applying restic retention policy"
    restic forget \
      --tag github \
      --keep-daily "${RESTIC_KEEP_DAILY}" \
      --keep-weekly "${RESTIC_KEEP_WEEKLY}" \
      --keep-monthly "${RESTIC_KEEP_MONTHLY}" \
      --prune
  fi

  if bool_is_true "${RESTIC_RUN_CHECK}"; then
    log "Running restic repository check"
    restic check --read-data-subset="${RESTIC_CHECK_READ_DATA_SUBSET}"
  fi
}

run_backup() {
  load_defaults
  validate_common_env
  check_requirements
  export_tool_tokens

  mkdir -p -- "${BACKUP_STAGING_ROOT}"

  if ! restic_repo_exists; then
    fail "Restic repository is not initialized. Run: ./scripts/backup-github-to-r2.sh init"
  fi

  log "Starting item-by-item GitHub backup for ${GITHUB_ACCOUNT_TYPE}: ${GITHUB_ACCOUNT}"
  log "Local staging root: ${BACKUP_STAGING_ROOT}"

  if bool_is_true "${BACKUP_INCLUDE_ACCOUNT_METADATA}"; then
    backup_account_metadata
  fi

  if bool_is_true "${BACKUP_INCLUDE_REPOSITORIES}"; then
    mapfile -t REPOSITORIES < <(list_repositories)
    log "Discovered ${#REPOSITORIES[@]} repositories with gh repo list"

    for repo_name in "${REPOSITORIES[@]}"; do
      [[ -n "${repo_name}" ]] || continue
      backup_repository "${repo_name}"
    done
  fi

  if bool_is_true "${BACKUP_INCLUDE_GISTS}"; then
    if [[ "${GITHUB_ACCOUNT_TYPE}" == "org" ]]; then
      log "Skipping gists because GitHub gists are user-owned, not organization-owned."
    else
      backup_gists
    fi
  fi

  if bool_is_true "${GITHUB_BACKUP_INCLUDE_STARRED_REPOSITORY_CLONES}"; then
    if [[ "${GITHUB_ACCOUNT_TYPE}" == "org" ]]; then
      log "Skipping starred repository clones because starring is user-owned, not organization-owned."
    else
      backup_starred_repository_clones
    fi
  fi

  run_forget_and_check
  log "Backup completed successfully"
}

show_snapshots() {
  load_defaults
  validate_common_env
  require_command restic
  restic snapshots --tag github
}

run_check() {
  load_defaults
  validate_common_env
  require_command restic
  restic check --read-data-subset="${RESTIC_CHECK_READ_DATA_SUBSET}"
}

show_repositories() {
  load_defaults
  validate_common_env
  require_command gh
  export_tool_tokens
  list_repositories
}

show_usage() {
  cat <<USAGE
Usage: $0 [command]

Commands:
  init        Initialize the restic repository in Cloudflare R2
  backup      Back up GitHub item-by-item, uploading each item to R2 before deleting local staging
  list-repos  Print repositories discovered by GitHub CLI for this account/org
  snapshots   List restic snapshots tagged as github
  check       Check the restic repository
  help        Show this help

Examples:
  $0 init
  $0 list-repos
  $0 backup
  $0 snapshots
USAGE
}

case "${COMMAND}" in
  init) init_restic ;;
  backup) run_backup ;;
  list-repos) show_repositories ;;
  snapshots) show_snapshots ;;
  check) run_check ;;
  help|-h|--help) show_usage ;;
  *) show_usage; fail "Unknown command: ${COMMAND}" ;;
esac
