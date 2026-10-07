#!/usr/bin/env bash

set -Eeuo pipefail

readonly COMMIT_HASH_PATTERN='^[0-9a-fA-F]{7,40}$'
readonly FULL_COMMIT_HASH_PATTERN='^[0-9a-fA-F]{40}$'

log() {
    printf '\n==> %s\n' "$1"
}

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

is_enabled() {
    case "${1,,}" in
        1|true|yes|on)
            return 0
            ;;
        0|false|no|off)
            return 1
            ;;
        *)
            fail "Invalid boolean value: $1"
            ;;
    esac
}

run_privileged() {
    if (( EUID == 0 )); then
        "$@"
        return
    fi

    "${DEPLOY_SUDO_BIN}" "$@"
}

release_hash_from_path() {
    local release_name
    local release_hash

    release_name="$(basename "$1")"

    [[ "${release_name}" == "${DEPLOY_APP_NAME}-"* ]] || return 1

    release_hash="${release_name#"${DEPLOY_APP_NAME}-"}"
    [[ "${release_hash}" =~ ${FULL_COMMIT_HASH_PATTERN} ]] || return 1

    printf '%s\n' "${release_hash}"
}

usage() {
    cat <<EOF_USAGE
Usage: $0 <commit-hash>

Required environment variables:
  DEPLOY_REPOSITORY        Git repository URL.

Common optional variables:
  DEPLOY_APP_NAME          Release prefix/current symlink name. Defaults to repository name.
  DEPLOY_ROOT              Release root. Default: /var/www
  DEPLOY_CURRENT_LINK      Live symlink. Default: <DEPLOY_ROOT>/<DEPLOY_APP_NAME>
  DEPLOY_ENV_SOURCE        Production .env source. Default: \$HOME/.env
  DEPLOY_OWNER             Release owner. Default: current user
  DEPLOY_GROUP             Release group. Default: www-data
  DEPLOY_PHP_FPM_SERVICE   PHP-FPM systemd service. Default: php8.4-fpm
  DEPLOY_PHP_FPM_ACTION    restart, reload, or none. Default: restart
  DEPLOY_RUN_COMPOSER      true/false. Default: true
  DEPLOY_RUN_NPM           true/false. Default: true
  DEPLOY_RUN_MIGRATIONS    true/false. Default: true
  DEPLOY_RESTART_QUEUE     true/false. Default: true
EOF_USAGE
}

if [[ $# -ne 1 ]]; then
    usage
    exit 1
fi

: "${DEPLOY_REPOSITORY:?DEPLOY_REPOSITORY is required}"

DEPLOY_COMMIT="$1"
DEPLOY_APP_NAME="${DEPLOY_APP_NAME:-$(basename "${DEPLOY_REPOSITORY%.git}")}"
DEPLOY_ROOT="${DEPLOY_ROOT:-/var/www}"
DEPLOY_CURRENT_LINK="${DEPLOY_CURRENT_LINK:-${DEPLOY_ROOT}/${DEPLOY_APP_NAME}}"
DEPLOY_ENV_SOURCE="${DEPLOY_ENV_SOURCE:-${HOME}/.env}"
DEPLOY_PREVIOUS_RELEASE_FILE="${DEPLOY_PREVIOUS_RELEASE_FILE:-${HOME}/.${DEPLOY_APP_NAME}-previous-release}"
DEPLOY_TEMP_ROOT="${DEPLOY_TEMP_ROOT:-${HOME}}"
DEPLOY_OWNER="${DEPLOY_OWNER:-$(id -un)}"
DEPLOY_GROUP="${DEPLOY_GROUP:-www-data}"
DEPLOY_PHP_BIN="${DEPLOY_PHP_BIN:-/usr/bin/php}"
DEPLOY_COMPOSER_BIN="${DEPLOY_COMPOSER_BIN:-composer}"
DEPLOY_NPM_BIN="${DEPLOY_NPM_BIN:-npm}"
DEPLOY_SUDO_BIN="${DEPLOY_SUDO_BIN:-sudo}"
DEPLOY_PHP_FPM_SERVICE="${DEPLOY_PHP_FPM_SERVICE:-php8.4-fpm}"
DEPLOY_PHP_FPM_ACTION="${DEPLOY_PHP_FPM_ACTION:-restart}"
DEPLOY_RUN_COMPOSER="${DEPLOY_RUN_COMPOSER:-true}"
DEPLOY_RUN_NPM="${DEPLOY_RUN_NPM:-true}"
DEPLOY_RUN_MIGRATIONS="${DEPLOY_RUN_MIGRATIONS:-true}"
DEPLOY_RESTART_QUEUE="${DEPLOY_RESTART_QUEUE:-true}"

[[ "${DEPLOY_COMMIT}" =~ ${COMMIT_HASH_PATTERN} ]] || fail "Commit hash must contain 7 to 40 hexadecimal characters."
[[ "${DEPLOY_APP_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "DEPLOY_APP_NAME contains unsupported characters."
[[ "${DEPLOY_ROOT}" == /* ]] || fail "DEPLOY_ROOT must be an absolute path."
[[ -d "${DEPLOY_TEMP_ROOT}" ]] || fail "Temporary root does not exist: ${DEPLOY_TEMP_ROOT}"
[[ -f "${DEPLOY_ENV_SOURCE}" ]] || fail "Environment file does not exist: ${DEPLOY_ENV_SOURCE}"

case "${DEPLOY_PHP_FPM_ACTION}" in
    restart|reload|none)
        ;;
    *)
        fail "DEPLOY_PHP_FPM_ACTION must be restart, reload, or none."
        ;;
esac

require_command git
require_command mktemp
require_command readlink
if is_enabled "${DEPLOY_RUN_MIGRATIONS}" || is_enabled "${DEPLOY_RESTART_QUEUE}"; then
    require_command "${DEPLOY_PHP_BIN}"
fi

if (( EUID != 0 )); then
    require_command "${DEPLOY_SUDO_BIN}"
fi

if is_enabled "${DEPLOY_RUN_COMPOSER}"; then
    require_command "${DEPLOY_COMPOSER_BIN}"
fi

if is_enabled "${DEPLOY_RUN_NPM}"; then
    require_command "${DEPLOY_NPM_BIN}"
fi

if [[ "${DEPLOY_PHP_FPM_ACTION}" != "none" ]]; then
    require_command systemctl
fi

if [[ -e "${DEPLOY_CURRENT_LINK}" && ! -L "${DEPLOY_CURRENT_LINK}" ]]; then
    fail "Current release path exists and is not a symlink: ${DEPLOY_CURRENT_LINK}"
fi

TEMP_PATH=""

cleanup() {
    if [[ -n "${TEMP_PATH}" && -d "${TEMP_PATH}" ]]; then
        rm -rf -- "${TEMP_PATH}"
    fi
}

trap cleanup EXIT

PREVIOUS_HASH=""

if [[ -L "${DEPLOY_CURRENT_LINK}" ]]; then
    CURRENT_RELEASE="$(readlink -f "${DEPLOY_CURRENT_LINK}" 2>/dev/null || true)"
    [[ -n "${CURRENT_RELEASE}" ]] || fail "Current release symlink is broken: ${DEPLOY_CURRENT_LINK}"

    log "Current release: ${CURRENT_RELEASE}"
    PREVIOUS_HASH="$(release_hash_from_path "${CURRENT_RELEASE}" || true)"
else
    log "Current release: none"
fi

log "Cloning repository"
TEMP_PATH="$(mktemp -d "${DEPLOY_TEMP_ROOT%/}/${DEPLOY_APP_NAME}.deploy.XXXXXX")"
git clone --no-checkout "${DEPLOY_REPOSITORY}" "${TEMP_PATH}"

log "Resolving commit ${DEPLOY_COMMIT}"
REQUESTED_HASH="$(git -C "${TEMP_PATH}" rev-parse --verify "${DEPLOY_COMMIT}^{commit}" 2>/dev/null)" \
    || fail "Commit was not found in the cloned repository: ${DEPLOY_COMMIT}"

[[ "${REQUESTED_HASH}" =~ ${FULL_COMMIT_HASH_PATTERN} ]] || fail "Git returned an invalid commit hash: ${REQUESTED_HASH}"

RELEASE_PATH="${DEPLOY_ROOT}/${DEPLOY_APP_NAME}-${REQUESTED_HASH}"

if [[ -e "${RELEASE_PATH}" ]]; then
    fail "Release already exists: ${RELEASE_PATH}"
fi

log "Checking out commit ${REQUESTED_HASH}"
git -C "${TEMP_PATH}" checkout --detach "${REQUESTED_HASH}"

CHECKED_OUT_HASH="$(git -C "${TEMP_PATH}" rev-parse HEAD)"
[[ "${CHECKED_OUT_HASH}" == "${REQUESTED_HASH}" ]] || fail "Checked out commit does not match requested commit."

log "Copying production environment"
cp "${DEPLOY_ENV_SOURCE}" "${TEMP_PATH}/.env"
chmod 640 "${TEMP_PATH}/.env"

if is_enabled "${DEPLOY_RUN_COMPOSER}"; then
    [[ -f "${TEMP_PATH}/composer.json" ]] || fail "composer.json was not found. Set DEPLOY_RUN_COMPOSER=false to skip Composer."

    log "Installing Composer dependencies"
    (
        cd "${TEMP_PATH}"
        "${DEPLOY_COMPOSER_BIN}" install \
            --no-dev \
            --no-interaction \
            --prefer-dist \
            --optimize-autoloader
    )
fi

if is_enabled "${DEPLOY_RUN_NPM}"; then
    [[ -f "${TEMP_PATH}/package-lock.json" ]] || fail "package-lock.json was not found. Set DEPLOY_RUN_NPM=false to skip npm."

    log "Installing npm dependencies"
    (
        cd "${TEMP_PATH}"
        "${DEPLOY_NPM_BIN}" ci
    )

    log "Building frontend assets"
    (
        cd "${TEMP_PATH}"
        "${DEPLOY_NPM_BIN}" run build
    )
fi

if is_enabled "${DEPLOY_RUN_MIGRATIONS}" || is_enabled "${DEPLOY_RESTART_QUEUE}"; then
    [[ -f "${TEMP_PATH}/artisan" ]] || fail "artisan was not found. Disable Laravel-specific steps for non-Laravel repositories."
fi

if is_enabled "${DEPLOY_RUN_MIGRATIONS}"; then
    log "Running database migrations"
    (
        cd "${TEMP_PATH}"
        "${DEPLOY_PHP_BIN}" artisan migrate --force
    )
fi

log "Moving release to ${RELEASE_PATH}"
run_privileged mv "${TEMP_PATH}" "${RELEASE_PATH}"

log "Setting release ownership and writable directories"
run_privileged chown -R "${DEPLOY_OWNER}:${DEPLOY_GROUP}" "${RELEASE_PATH}"

WRITABLE_PATHS=()

for relative_path in storage bootstrap/cache; do
    if [[ -d "${RELEASE_PATH}/${relative_path}" ]]; then
        WRITABLE_PATHS+=("${RELEASE_PATH}/${relative_path}")
    fi
done

if (( ${#WRITABLE_PATHS[@]} > 0 )); then
    run_privileged chmod -R ug+rwX "${WRITABLE_PATHS[@]}"
fi

log "Recording previous release"
if [[ -n "${PREVIOUS_HASH}" ]]; then
    printf '%s\n' "${PREVIOUS_HASH}" > "${DEPLOY_PREVIOUS_RELEASE_FILE}"
    printf 'Previous release: %s\n' "${PREVIOUS_HASH}"
else
    : > "${DEPLOY_PREVIOUS_RELEASE_FILE}"
    printf 'Previous release: none\n'
fi

log "Switching current release"
TEMP_LINK="${DEPLOY_CURRENT_LINK}.new"
run_privileged rm -f -- "${TEMP_LINK}"
run_privileged ln -s "${RELEASE_PATH}" "${TEMP_LINK}"
run_privileged mv -Tf "${TEMP_LINK}" "${DEPLOY_CURRENT_LINK}"
printf 'Current release: %s\n' "$(readlink -f "${DEPLOY_CURRENT_LINK}")"

if [[ "${DEPLOY_PHP_FPM_ACTION}" != "none" ]]; then
    log "Running systemctl ${DEPLOY_PHP_FPM_ACTION} ${DEPLOY_PHP_FPM_SERVICE}"
    run_privileged systemctl "${DEPLOY_PHP_FPM_ACTION}" "${DEPLOY_PHP_FPM_SERVICE}"
fi

if is_enabled "${DEPLOY_RESTART_QUEUE}"; then
    log "Restarting Laravel queue workers"
    "${DEPLOY_PHP_BIN}" "${DEPLOY_CURRENT_LINK}/artisan" queue:restart
fi

log "Cleaning old releases"
shopt -s nullglob

for directory in "${DEPLOY_ROOT}"/"${DEPLOY_APP_NAME}"-*; do
    [[ -d "${directory}" ]] || continue

    DIRECTORY_HASH="$(release_hash_from_path "${directory}" || true)"
    [[ -n "${DIRECTORY_HASH}" ]] || continue

    if [[ "${DIRECTORY_HASH}" == "${CHECKED_OUT_HASH}" ]]; then
        printf 'Keeping current release: %s\n' "${DIRECTORY_HASH}"
        continue
    fi

    if [[ -n "${PREVIOUS_HASH}" && "${DIRECTORY_HASH}" == "${PREVIOUS_HASH}" ]]; then
        printf 'Keeping previous release: %s\n' "${DIRECTORY_HASH}"
        continue
    fi

    printf 'Deleting old release: %s\n' "${DIRECTORY_HASH}"
    run_privileged rm -rf -- "${directory}"
done

log "Deployment complete"
printf 'Current:  %s -> %s\n' "${DEPLOY_CURRENT_LINK}" "$(readlink -f "${DEPLOY_CURRENT_LINK}")"

if [[ -n "${PREVIOUS_HASH}" ]]; then
    printf 'Previous: %s\n' "${PREVIOUS_HASH}"
else
    printf 'Previous: none\n'
fi