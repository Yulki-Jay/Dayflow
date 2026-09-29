#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
SCHEME=${SCHEME:-Dayflow}
CONFIG=${CONFIG:-Debug}
DERIVED_DATA=$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "${DERIVED_DATA:-${REPO_ROOT}/artifacts/build}")
RELEASE_DIR=$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "${RELEASE_DIR:-${REPO_ROOT}/release}")
APP_NAME=${APP_NAME:-Dayflow}
PROJECT_PATH="${REPO_ROOT}/Dayflow/Dayflow.xcodeproj"
APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIG}/${APP_NAME}.app"
RELEASE_APP_PATH="${RELEASE_DIR}/${APP_NAME}.app"
EXPECTED_BUNDLE_ID=teleportlabs.com.Dayflow
INSTALL_APP=${INSTALL_APP:-1}

ensure_not_running() {
  if ! python3 - "$@" <<'PY'
import subprocess, sys
commands = subprocess.check_output(['ps', '-axo', 'args='], text=True).splitlines()
for path in sys.argv[1:]:
    if any(line.strip() == path or line.strip().startswith(path + ' ') for line in commands):
        print(f'ERROR: Quit {path} from the Dayflow menu before replacing it. No process was stopped.', file=sys.stderr)
        sys.exit(1)
PY
  then
    exit 1
  fi
}
ensure_not_running "${APP_PATH}/Contents/MacOS/${APP_NAME}"
if [[ "${INSTALL_APP}" == 1 ]]; then
  ensure_not_running "${RELEASE_APP_PATH}/Contents/MacOS/${APP_NAME}"
fi

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "${TEMP_DIR}"' EXIT
EXISTING_HASH=""
EXISTING_REQUIREMENT=""
if [[ -d "${RELEASE_APP_PATH}" ]]; then
  codesign --verify --deep --strict "${RELEASE_APP_PATH}"
  EXISTING_REQUIREMENT=$(codesign -d -r- "${RELEASE_APP_PATH}" 2>&1 | grep '^designated =>' | cut -d '>' -f2- || true)
  if codesign -d --extract-certificates="${TEMP_DIR}/previous-cert-" "${RELEASE_APP_PATH}" 2>/dev/null; then
    if [[ -f "${TEMP_DIR}/previous-cert-0" ]]; then
      EXISTING_HASH=$(shasum "${TEMP_DIR}/previous-cert-0" | cut -d ' ' -f1 | tr '[:lower:]' '[:upper:]')
    fi
  fi
fi

SIGN_IDENTITY=${SIGN_IDENTITY:-${EXISTING_HASH:-"Apple Development"}}
IDENTITIES=$(security find-identity -v -p codesigning)
MATCHES=$(printf '%s\n' "${IDENTITIES}" | grep -F "${SIGN_IDENTITY}" || true)
MATCH_COUNT=$(printf '%s\n' "${MATCHES}" | grep -c '"' || true)
if [[ "${MATCH_COUNT}" != 1 ]]; then
  echo "ERROR: Select exactly one available signing certificate using SIGN_IDENTITY=<certificate SHA-1>." >&2
  echo "The existing app's certificate is preferred; it will not silently switch to another identity." >&2
  printf '%s\n' "${IDENTITIES}" >&2
  exit 1
fi
SIGNING_HASH=$(printf '%s\n' "${MATCHES}" | awk '{print $2}')
security find-certificate -a -p > "${TEMP_DIR}/certificates.pem"
CERTIFICATE_TEAM=$(python3 - "${TEMP_DIR}/certificates.pem" "${SIGNING_HASH}" <<'PY'
import hashlib, re, subprocess, sys
certificates = open(sys.argv[1], 'rb').read()
for pem in re.findall(rb'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', certificates, re.S):
    der = subprocess.run(['openssl', 'x509', '-outform', 'DER'], input=pem, capture_output=True, check=True).stdout
    if hashlib.sha1(der).hexdigest().upper() != sys.argv[2].upper():
        continue
    subject = subprocess.run(['openssl', 'x509', '-noout', '-subject', '-nameopt', 'sep_multiline'], input=pem, capture_output=True, check=True).stdout.decode()
    match = re.search(r'^\s*OU\s*=\s*([A-Z0-9]{10})\s*$', subject, re.M)
    if not match:
        sys.exit('Selected certificate has no valid team OU')
    print(match.group(1))
    break
else:
    sys.exit('Selected signing certificate was not found')
PY
)
if [[ -n "${DEVELOPMENT_TEAM:-}" && "${DEVELOPMENT_TEAM}" != "${CERTIFICATE_TEAM}" ]]; then
  echo "ERROR: DEVELOPMENT_TEAM does not match the certificate OU (${CERTIFICATE_TEAM})." >&2
  exit 1
fi
DEVELOPMENT_TEAM=${CERTIFICATE_TEAM}
if [[ -d "${RELEASE_APP_PATH}" && "${SIGNING_HASH}" != "${EXISTING_HASH}" && "${ALLOW_SIGNING_IDENTITY_CHANGE:-0}" != 1 ]]; then
  echo "ERROR: Signing identity would change. Permissions may need reauthorization." >&2
  echo "For an intentional one-time migration, set SIGN_IDENTITY and ALLOW_SIGNING_IDENTITY_CHANGE=1." >&2
  exit 1
fi

xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIG}" \
  -derivedDataPath "${DERIVED_DATA}" \
  CODE_SIGN_IDENTITY="${SIGNING_HASH}" \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  build

if [[ ! -d "${APP_PATH}" ]]; then
  echo "ERROR: Built app not found: ${APP_PATH}" >&2
  exit 1
fi
codesign --verify --deep --strict "${APP_PATH}"
SIGNATURE=$(codesign -dv --verbose=2 "${APP_PATH}" 2>&1)
printf '%s\n' "${SIGNATURE}" | grep -Fx "Identifier=${EXPECTED_BUNDLE_ID}" >/dev/null
printf '%s\n' "${SIGNATURE}" | grep -Fx "TeamIdentifier=${DEVELOPMENT_TEAM}" >/dev/null
if [[ -n "${EXISTING_REQUIREMENT}" && "${ALLOW_SIGNING_IDENTITY_CHANGE:-0}" != 1 ]]; then
  codesign --verify --strict -R "=${EXISTING_REQUIREMENT}" "${APP_PATH}"
  NEW_REQUIREMENT=$(codesign -d -r- "${APP_PATH}" 2>&1 | grep '^designated =>' | cut -d '>' -f2-)
  codesign --verify --strict -R "=${NEW_REQUIREMENT}" "${RELEASE_APP_PATH}"
fi

if [[ "${INSTALL_APP}" != 1 ]]; then
  echo "Built and verified: ${APP_PATH}. Installation skipped (INSTALL_APP=${INSTALL_APP})."
  exit 0
fi

mkdir -p "${RELEASE_DIR}"
STAGING_DIR=$(mktemp -d "${RELEASE_DIR}/.dayflow-debug.XXXXXX")
trap 'rm -rf "${TEMP_DIR}" "${STAGING_DIR}"' EXIT
STAGING_APP_PATH="${STAGING_DIR}/${APP_NAME}.app"
ditto "${APP_PATH}" "${STAGING_APP_PATH}"
codesign --verify --deep --strict "${STAGING_APP_PATH}"
ensure_not_running "${RELEASE_APP_PATH}/Contents/MacOS/${APP_NAME}"
if [[ -e "${RELEASE_APP_PATH}" ]]; then
  BACKUP_APP_PATH="${RELEASE_DIR}/${APP_NAME}-previous-$(date +%Y%m%d-%H%M%S)-$$.app"
  mv "${RELEASE_APP_PATH}" "${BACKUP_APP_PATH}"
  echo "Previous app saved: ${BACKUP_APP_PATH}"
fi
mv "${STAGING_APP_PATH}" "${RELEASE_APP_PATH}"
echo "Signed app: ${RELEASE_APP_PATH}"
codesign -dv --verbose=2 "${RELEASE_APP_PATH}" 2>&1 | grep -E 'Identifier=|Authority=|TeamIdentifier=|Signature='
