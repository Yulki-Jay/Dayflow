import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("build_debug.sh")
CERTIFICATE = b"test-certificate"
FINGERPRINT = hashlib.sha1(CERTIFICATE).hexdigest().upper()

MOCK = r'''#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ['TEST_ROOT'])
cert = b'test-certificate'
identity = hashlib.sha1(cert).hexdigest().upper()
team = 'REALTEAM01'
if name == 'ps':
    print(os.environ.get('RUNNING_APP', ''))
elif name == 'security':
    if args[0] == 'find-identity':
        print(f'  1) {identity} "Apple Development: test (NOTTHETEAM)"')
    else:
        print('-----BEGIN CERTIFICATE-----\ndummy\n-----END CERTIFICATE-----')
elif name == 'openssl':
    sys.stdin.buffer.read()
    if '-outform' in args:
        sys.stdout.buffer.write(cert)
    else:
        print('subject=\n    CN = Apple Development: test (NOTTHETEAM)\n    OU = REALTEAM01')
elif name == 'xcodebuild':
    (root / 'build-args').write_text('\n'.join(args))
    assert 'DEVELOPMENT_TEAM=REALTEAM01' in args
    app = root / 'artifacts/build/Build/Products/Debug/Dayflow.app'
    app.mkdir(parents=True, exist_ok=True)
    info = {'requirement': os.environ.get('NEW_REQUIREMENT', 'stable'), 'team': team, 'cert': 'test-certificate'}
    (app / 'identity.json').write_text(json.dumps(info))
elif name == 'codesign':
    app = pathlib.Path(args[-1])
    info = json.loads((app / 'identity.json').read_text())
    extraction = next((a.split('=', 1)[1] for a in args if a.startswith('--extract-certificates=')), None)
    if '--extract-certificates' in args:
        sys.exit(1)
    if extraction:
        pathlib.Path(extraction + '0').write_bytes(info['cert'].encode())
    elif '-R' in args:
        requirement = args[args.index('-R') + 1]
        if not requirement.startswith('='):
            sys.exit(1)
        if requirement[1:].strip() != info['requirement']:
            sys.exit(1)
        with (root / 'verified-requirements').open('a') as log:
            log.write(str(app) + '\n')
    elif '-r-' in args:
        print('designated => ' + info['requirement'], file=sys.stderr)
    elif '-dv' in args:
        print('Identifier=teleportlabs.com.Dayflow', file=sys.stderr)
        print('TeamIdentifier=' + info['team'], file=sys.stderr)
'''


class BuildDebugTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dayflow-build-tests-")
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        shutil.copy2(SCRIPT, self.root / "scripts/build_debug.sh")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        mock = self.bin / "mock"
        mock.write_text(MOCK)
        mock.chmod(0o755)
        for command in ["ps", "security", "openssl", "xcodebuild", "codesign"]:
            (self.bin / command).symlink_to(mock)
        self.app = self.root / "release/Dayflow.app"
        self.app.mkdir(parents=True)
        self.set_identity()
        self.env = {k: v for k, v in os.environ.items() if k not in [
            "SIGN_IDENTITY", "DEVELOPMENT_TEAM", "ALLOW_SIGNING_IDENTITY_CHANGE",
            "INSTALL_APP", "RELEASE_DIR", "DERIVED_DATA", "SCHEME", "CONFIG", "APP_NAME"]}
        self.env.update(TEST_ROOT=str(self.root), PATH=str(self.bin) + os.pathsep + self.env["PATH"])

    def tearDown(self):
        self.temp.cleanup()

    def set_identity(self, certificate="test-certificate", requirement="stable"):
        import json
        (self.app / "identity.json").write_text(json.dumps({
            "cert": certificate, "requirement": requirement, "team": "REALTEAM01"}))

    def run_build(self, **settings):
        return subprocess.run(["bash", str(self.root / "scripts/build_debug.sh")],
            env={**self.env, **settings}, capture_output=True, text=True)

    def test_actual_certificate_ou_and_mutual_requirements(self):
        result = self.run_build(INSTALL_APP="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DEVELOPMENT_TEAM=REALTEAM01", (self.root / "build-args").read_text())
        verified = (self.root / "verified-requirements").read_text().splitlines()
        self.assertEqual(len(verified), 2)
        self.assertIn(str(self.app), verified)
        self.assertFalse(list(self.app.parent.glob("Dayflow-previous-*.app")))

    def test_running_app_with_arguments_is_not_replaced(self):
        result = self.run_build(RUNNING_APP=str(self.app / "Contents/MacOS/Dayflow") + " --argument")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No process was stopped", result.stderr)
        self.assertFalse((self.root / "build-args").exists())

    def test_verify_only_build_leaves_running_release_untouched(self):
        result = self.run_build(INSTALL_APP="0", RUNNING_APP=str(self.app / "Contents/MacOS/Dayflow"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(list(self.app.parent.glob("Dayflow-previous-*.app")))

    def test_running_derived_app_blocks_even_verify_only_build(self):
        path = self.root / "artifacts/build/Build/Products/Debug/Dayflow.app/Contents/MacOS/Dayflow"
        result = self.run_build(INSTALL_APP="0", RUNNING_APP=str(path))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "build-args").exists())

    def test_wrong_team_is_rejected_before_build(self):
        result = self.run_build(INSTALL_APP="0", DEVELOPMENT_TEAM="NOTTHETEAM")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match", result.stderr)
        self.assertFalse((self.root / "build-args").exists())

    def test_certificate_change_needs_explicit_opt_in(self):
        self.set_identity(certificate="official-certificate")
        result = self.run_build(INSTALL_APP="0", SIGN_IDENTITY=FINGERPRINT)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Signing identity would change", result.stderr)
        self.assertFalse((self.root / "build-args").exists())

    def test_missing_old_certificate_does_not_fall_back(self):
        self.set_identity(certificate="expired-certificate")
        result = self.run_build(INSTALL_APP="0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("will not silently switch", result.stderr)

    def test_changed_requirement_prevents_installation(self):
        result = self.run_build(NEW_REQUIREMENT="different")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(list(self.app.parent.glob("Dayflow-previous-*.app")))

    def test_two_builds_preserve_backups(self):
        for _ in range(2):
            result = self.run_build()
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(list(self.app.parent.glob("Dayflow-previous-*.app"))), 2)
        self.assertTrue(self.app.exists())


if __name__ == "__main__":
    unittest.main()
