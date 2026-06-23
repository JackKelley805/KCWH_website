#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="${APP_NAME:-kcwh-website}"
REPO="${REPO:-JackKelley805/KCWH_website}"
TAG="${TAG:-website}"
INSTALL_DIR="${INSTALL_DIR:-/opt/${APP_NAME}}"
SERVICE_USER="${SERVICE_USER:-${APP_NAME}}"
ENV_FILE="${ENV_FILE:-/etc/${APP_NAME}.env}"
APP_PORT="${APP_PORT:-5000}"
DOTNET_ROOT="${DOTNET_ROOT:-/opt/dotnet}"
RELEASE_API="https://api.github.com/repos/${REPO}/releases/tags/${TAG}"

log() {
  printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "Run this script with sudo or as root."
  fi
}

install_packages() {
  local missing=()
  local command_name

  for command_name in curl tar unzip python3; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      missing+=("${command_name}")
    fi
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    return
  fi

  if command -v apt-get >/dev/null 2>&1; then
    log "Installing required packages: ${missing[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl tar unzip python3
    return
  fi

  fail "Missing required commands: ${missing[*]}. Install them first, then rerun this script."
}

install_dotnet_runtime() {
  if command -v dotnet >/dev/null 2>&1 && dotnet --list-runtimes | grep -q '^Microsoft.AspNetCore.App 8\.'; then
    DOTNET_BIN="$(command -v dotnet)"
    log "Found ASP.NET Core Runtime 8: ${DOTNET_BIN}"
    return
  fi

  log "Installing ASP.NET Core Runtime 8 to ${DOTNET_ROOT}"
  mkdir -p "${DOTNET_ROOT}"
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
  bash /tmp/dotnet-install.sh --channel 8.0 --runtime aspnetcore --install-dir "${DOTNET_ROOT}" --no-path
  DOTNET_BIN="${DOTNET_ROOT}/dotnet"

  if [[ ! -x "${DOTNET_BIN}" ]]; then
    fail "dotnet runtime install did not create ${DOTNET_BIN}."
  fi
}

download_release_asset() {
  local api_json asset_url asset_name auth_args=()
  api_json="$(mktemp)"

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    auth_args=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi

  log "Reading GitHub release ${REPO}@${TAG}"
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    "${auth_args[@]}" \
    "${RELEASE_API}" \
    -o "${api_json}"

  asset_url="$(python3 - "${api_json}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    release = json.load(handle)

assets = release.get("assets") or []
if not assets:
    sys.exit(1)

def score(asset):
    name = asset.get("name", "").lower()
    if "publish" in name and name.endswith(".zip"):
        return 0
    if "linux" in name and name.endswith(".zip"):
        return 1
    if name.endswith(".zip"):
        return 2
    if name.endswith((".tar.gz", ".tgz")):
        return 3
    return 10

assets = sorted(assets, key=score)
for asset in assets:
    if score(asset) < 10 and asset.get("browser_download_url"):
        print(asset["browser_download_url"])
        sys.exit(0)

sys.exit(1)
PY
)" || fail "No .zip/.tar.gz release asset was found. Upload a dotnet publish archive to the GitHub release."

  asset_name="${asset_url##*/}"
  DOWNLOAD_PATH="$(mktemp "/tmp/${APP_NAME}.XXXXXX.${asset_name}")"

  log "Downloading release asset ${asset_name}"
  curl -fL "${auth_args[@]}" "${asset_url}" -o "${DOWNLOAD_PATH}"
}

extract_release_asset() {
  local app_executable
  STAGING_DIR="$(mktemp -d "/tmp/${APP_NAME}.staging.XXXXXX")"

  log "Extracting release asset"
  case "${DOWNLOAD_PATH}" in
    *.zip)
      unzip -q "${DOWNLOAD_PATH}" -d "${STAGING_DIR}"
      ;;
    *.tar.gz|*.tgz)
      tar -xzf "${DOWNLOAD_PATH}" -C "${STAGING_DIR}"
      ;;
    *)
      fail "Unsupported release asset type: ${DOWNLOAD_PATH}"
      ;;
  esac

  APP_DLL="$(find "${STAGING_DIR}" -maxdepth 4 -type f -name 'tcadminwebpage.dll' -print -quit)"
  if [[ -n "${APP_DLL}" ]]; then
    APP_ROOT="$(dirname "${APP_DLL}")"
    APP_ENTRY_NAME="$(basename "${APP_DLL}")"
    APP_LAUNCH_MODE="framework-dependent"
    return
  fi

  app_executable="$(find "${STAGING_DIR}" -maxdepth 4 -type f -name 'tcadminwebpage' -print -quit)"
  if [[ -n "${app_executable}" ]]; then
    APP_ROOT="$(dirname "${app_executable}")"
    APP_ENTRY_NAME="$(basename "${app_executable}")"
    APP_LAUNCH_MODE="self-contained"
    chmod +x "${app_executable}"
    return
  fi

  fail "Could not find tcadminwebpage.dll or a tcadminwebpage executable in the release asset. Publish the app first, then upload the publish archive."
}

create_service_user() {
  if id "${SERVICE_USER}" >/dev/null 2>&1; then
    return
  fi

  log "Creating service user ${SERVICE_USER}"
  useradd --system --user-group --home-dir "${INSTALL_DIR}" --shell /usr/sbin/nologin "${SERVICE_USER}"
}

install_application_files() {
  local new_dir backup_dir timestamp
  timestamp="$(date '+%Y%m%d%H%M%S')"
  new_dir="${INSTALL_DIR}.new"
  backup_dir="${INSTALL_DIR}.backup.${timestamp}"

  log "Installing application to ${INSTALL_DIR}"
  rm -rf "${new_dir}"
  mkdir -p "${new_dir}"
  cp -a "${APP_ROOT}/." "${new_dir}/"
  if [[ "${APP_LAUNCH_MODE}" == "self-contained" ]]; then
    chmod +x "${new_dir}/${APP_ENTRY_NAME}"
  fi

  mkdir -p /var/log/"${APP_NAME}"/TcAdminResponses

  if [[ -d "${INSTALL_DIR}" ]]; then
    mv "${INSTALL_DIR}" "${backup_dir}"
    log "Previous install moved to ${backup_dir}"
  fi

  mv "${new_dir}" "${INSTALL_DIR}"
  chown -R "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}" /var/log/"${APP_NAME}"
}

create_environment_file() {
  if [[ -f "${ENV_FILE}" ]]; then
    log "Keeping existing environment file ${ENV_FILE}"
    chmod 600 "${ENV_FILE}"
    return
  fi

  log "Creating environment file ${ENV_FILE}"
  cat > "${ENV_FILE}" <<EOF
ASPNETCORE_ENVIRONMENT=Production
ASPNETCORE_URLS=http://127.0.0.1:${APP_PORT}

# Fill these in before opening the site publicly.
TcAdmin__Username=
TcAdmin__Password=
TcAdmin__GameId=
TcAdmin__GameDatacenter=
TcAdmin__GameSlots=20
TcAdmin__HostnameFormat={username}-minecraft
TcAdmin__GenerateBillingIdsWhenBlank=true
TcAdmin__ResponseLogDirectory=/var/log/${APP_NAME}/TcAdminResponses

Admin__Username=admin
Admin__Password=
EOF
  chmod 600 "${ENV_FILE}"
}

create_systemd_service() {
  local exec_start
  if [[ "${APP_LAUNCH_MODE}" == "framework-dependent" ]]; then
    exec_start="${DOTNET_BIN} ${INSTALL_DIR}/${APP_ENTRY_NAME}"
  else
    exec_start="${INSTALL_DIR}/${APP_ENTRY_NAME}"
  fi

  log "Writing systemd service /etc/systemd/system/${APP_NAME}.service"
  cat > "/etc/systemd/system/${APP_NAME}.service" <<EOF
[Unit]
Description=KC Web Hosting website
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=${INSTALL_DIR}
ExecStart=${exec_start}
Restart=always
RestartSec=10
KillSignal=SIGINT
SyslogIdentifier=${APP_NAME}
User=${SERVICE_USER}
Group=${SERVICE_USER}
Environment=DOTNET_ROOT=${DOTNET_ROOT}
Environment=PATH=${DOTNET_ROOT}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EnvironmentFile=${ENV_FILE}
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
}

start_service() {
  log "Starting ${APP_NAME}"
  systemctl daemon-reload
  systemctl enable "${APP_NAME}"
  systemctl restart "${APP_NAME}"
  systemctl --no-pager --full status "${APP_NAME}" || true
}

print_next_steps() {
  cat <<EOF

Install complete.

Edit secrets and TCAdmin settings:
  sudo nano ${ENV_FILE}
  sudo systemctl restart ${APP_NAME}

Watch logs:
  sudo journalctl -u ${APP_NAME} -f

Local app URL:
  http://127.0.0.1:${APP_PORT}

Put Nginx/Caddy/Apache in front of this for your public domain and HTTPS.
EOF
}

cleanup() {
  rm -f "${DOWNLOAD_PATH:-}" /tmp/dotnet-install.sh
  rm -rf "${STAGING_DIR:-}"
}

main() {
  trap cleanup EXIT
  require_root
  install_packages
  download_release_asset
  extract_release_asset
  if [[ "${APP_LAUNCH_MODE}" == "framework-dependent" ]]; then
    install_dotnet_runtime
  else
    DOTNET_BIN=""
    log "Release asset is self-contained; skipping .NET runtime install."
  fi
  create_service_user
  install_application_files
  create_environment_file
  create_systemd_service
  start_service
  print_next_steps
}

main "$@"
