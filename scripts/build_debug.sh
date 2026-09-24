#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)

SCHEME=${SCHEME:-Dayflow}
CONFIG=${CONFIG:-Debug}
DERIVED_DATA=${DERIVED_DATA:-"${REPO_ROOT}/artifacts/build"}
RELEASE_DIR=${RELEASE_DIR:-"${REPO_ROOT}/release"}
APP_NAME=${APP_NAME:-Dayflow}
SIGN_IDENTITY=${SIGN_IDENTITY:-"Apple Development"}
PROJECT_PATH="${REPO_ROOT}/Dayflow/Dayflow.xcodeproj"
APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIG}/${APP_NAME}.app"
RELEASE_APP_PATH="${RELEASE_DIR}/${APP_NAME}.app"

SIGNING_IDENTITY_LINE=$(security find-identity -v -p codesigning | grep -F -m1 "${SIGN_IDENTITY}" || true)
if [[ -z "${SIGNING_IDENTITY_LINE}" ]]; then
  echo "ERROR: Signing identity not found: ${SIGN_IDENTITY}" >&2
  security find-identity -v -p codesigning >&2 || true
  exit 1
fi
SIGNING_HASH=$(printf '%s\n' "${SIGNING_IDENTITY_LINE}" | awk '{print $2}')
if [[ "${SIGNING_IDENTITY_LINE}" =~ \(([A-Z0-9]{10})\) ]]; then
  DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM:-${BASH_REMATCH[1]}}
else
  echo "ERROR: Cannot determine the development team for ${SIGN_IDENTITY}" >&2
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
  echo "ERROR: Built app not found at ${APP_PATH}" >&2
  exit 1
fi

mkdir -p "${RELEASE_DIR}"
STAGING_DIR=$(mktemp -d "${RELEASE_DIR}/.dayflow-debug.XXXXXX")
trap 'rm -rf "${STAGING_DIR}"' EXIT
STAGING_APP_PATH="${STAGING_DIR}/${APP_NAME}.app"
ditto "${APP_PATH}" "${STAGING_APP_PATH}"
codesign --verify --deep --strict "${STAGING_APP_PATH}"

if [[ -e "${RELEASE_APP_PATH}" ]]; then
  BACKUP_APP_PATH="${RELEASE_DIR}/${APP_NAME}-previous-$(date +%Y%m%d-%H%M%S)-$$.app"
  mv "${RELEASE_APP_PATH}" "${BACKUP_APP_PATH}"
  echo "Previous app saved: ${BACKUP_APP_PATH}"
fi
mv "${STAGING_APP_PATH}" "${RELEASE_APP_PATH}"

echo "Signed app: ${RELEASE_APP_PATH}"
codesign -dv --verbose=2 "${RELEASE_APP_PATH}" 2>&1 | grep -E 'Identifier=|Authority=|TeamIdentifier=|Signature=' || true
