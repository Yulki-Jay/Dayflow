# Dayflow project instructions

## Build artifacts

- For Debug builds, run `bash scripts/build_debug.sh` so Xcode signs with the available Apple Development certificate, uses repository-local derived data at `artifacts/build/`, and places the runnable app at the fixed path `release/Dayflow.app`.
- Keep `release/Dayflow.app` at the same path and open that copy when testing macOS permissions; the Debug app also remains at `artifacts/build/Build/Products/Debug/Dayflow.app`. Keep the same signing certificate and Bundle ID `teleportlabs.com.Dayflow` across builds so macOS can usually reuse screen-recording and other privacy permissions; switching away from the old adhoc signature may require one new authorization.
- Each replacement preserves the previous Debug app as a timestamped `release/Dayflow-previous-*.app` backup; do not delete these backups unless the user explicitly asks.
- Put packaged, signed, notarized, or distributable app and DMG outputs under the repository root's `release/` directory. Use the existing release scripts for packaged builds; their default output directory is `release/`.
- Do not delete existing files under `artifacts/` or `release/` unless the user explicitly asks.
