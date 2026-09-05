"""Run the deployment's real package/filesystem preflight in an isolated fixture.

No root, RPM installation, service mutation or live CloudStack host is used.
The script stays standalone for transport to the Rocky management host.
"""

import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest


SCRIPT = Path(__file__).with_name('deploy-dr-cloudstack-ui.sh')
SOURCE = SCRIPT.read_text()
BACKEND_FUNCTION = SOURCE.split('# BEGIN BACKEND FINGERPRINT\n', 1)[1].split('# END BACKEND FINGERPRINT', 1)[0]
PREFLIGHT = SOURCE.split("die 'Target is not Rocky Linux 9.'\n", 1)[1].split(
    '\n(\n  cd "$BUNDLE"', 1)[0]
HARNESS = r'''
set -Eeuo pipefail
IFS=$'\n\t'
EXPECTED_CLOUDSTACK_VERSION='4.22.1.1'
SERVED_UI=$1
ARCHIVE=$2
CHECKSUM=$3
MANIFEST=$4
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
rpm() {
  case "$1" in
    -q)
      [[ $# -eq 4 && $2 == --qf && $3 == '%{VERSION}' && $4 == cloudstack-management ]] || return 90
      printf '%s' "$TEST_VERSION"
      return "$TEST_VERSION_RC"
      ;;
    -qf)
      [[ $# -eq 4 && $2 == --qf && $3 == '%{NAME} %{VERSION}\n' ]] || return 91
      if [[ $4 == "$SERVED_UI/WEB-INF/web.xml" ]]; then
        printf '%s\n' "$TEST_BACKEND_OWNER"
        return "$TEST_BACKEND_OWNER_RC"
      fi
      [[ $4 == "$SERVED_UI/index.html" ]] || return 91
      printf '%s\n' "$TEST_OWNER"
      return "$TEST_OWNER_RC"
      ;;
    *) return 92 ;;
  esac
}
systemctl() {
  [[ $# -eq 3 && $1 == is-active && $2 == --quiet && $3 == cloudstack-management ]] || return 93
  return "$TEST_SERVICE_RC"
}
'''


class PackagePreflightTests(unittest.TestCase):
    def check_preflight(self, error=None, absent=None, **overrides):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            webapp = root / 'webapp'
            webapp.mkdir()
            for name in ('WEB-INF', 'META-INF'):
                if absent != name:
                    (webapp / name).mkdir()
            if absent not in ('WEB-INF', 'web.xml'):
                (webapp / 'WEB-INF/web.xml').write_text('<web-app/>')
            if absent != 'index.html':
                (webapp / 'index.html').write_text('existing UI')
            files = [root / name for name in ('bundle.tar.gz', 'checksum', 'manifest')]
            for path in files:
                if absent != path.name:
                    path.touch()
            env = {
                **os.environ,
                'TEST_VERSION': '4.22.1.1', 'TEST_VERSION_RC': '0',
                'TEST_OWNER': 'cloudstack-management 4.22.1.1', 'TEST_OWNER_RC': '0',
                'TEST_BACKEND_OWNER': 'cloudstack-management 4.22.1.1', 'TEST_BACKEND_OWNER_RC': '0',
                'TEST_SERVICE_RC': '0', **overrides,
            }
            result = subprocess.run(
                ['bash', '-c', HARNESS + BACKEND_FUNCTION + PREFLIGHT + '\nprintf "PREFLIGHT_PASS\\n"',
                 'preflight-test', str(webapp), *map(str, files)],
                env=env, capture_output=True, text=True, timeout=5,
            )
            if error is None:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, 'PREFLIGHT_PASS\n')
            else:
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(error, result.stderr)
                self.assertNotIn('PREFLIGHT_PASS', result.stdout)

    def test_management_owned_webapp_passes_without_separate_ui_rpm(self):
        # The RPM stub refuses every query for cloudstack-ui.
        self.check_preflight()

    def test_missing_management_package_fails(self):
        self.check_preflight('Cannot query cloudstack-management version', TEST_VERSION='', TEST_VERSION_RC='1')

    def test_wrong_management_version_fails(self):
        self.check_preflight('not exact version 4.22.1.1', TEST_VERSION='4.22.1.0')

    def test_failed_version_query_cannot_pass_with_matching_output(self):
        self.check_preflight('Cannot query cloudstack-management version', TEST_VERSION_RC='1')

    def test_unowned_webapp_fails(self):
        self.check_preflight('Cannot query CloudStack served webapp package ownership', TEST_OWNER='', TEST_OWNER_RC='1')

    def test_failed_owner_query_cannot_pass_with_matching_output(self):
        self.check_preflight('Cannot query CloudStack served webapp package ownership', TEST_OWNER_RC='1')

    def test_wrong_owner_or_owner_version_fails(self):
        for owner in ('cloudstack-ui 4.22.1.1', 'cloudstack-management 4.22.1.0',
                      'cloudstack-management 4.22.1.1\nother-package 4.22.1.1'):
            with self.subTest(owner=owner):
                self.check_preflight('not owned by cloudstack-management 4.22.1.1', TEST_OWNER=owner)

    def test_missing_entry_html_fails(self):
        self.check_preflight('CloudStack served webapp is missing', absent='index.html')

    def test_missing_backend_directory_fails(self):
        for name in ('WEB-INF', 'web.xml'):
            with self.subTest(name=name):
                self.check_preflight('backend WEB-INF/web.xml is missing or unsafe', absent=name)

    def test_absent_optional_meta_inf_passes(self):
        self.check_preflight(absent='META-INF')

    def test_backend_package_ownership_required(self):
        self.check_preflight('Cannot query CloudStack backend package ownership', TEST_BACKEND_OWNER_RC='1')
        self.check_preflight('backend is not owned by cloudstack-management 4.22.1.1', TEST_BACKEND_OWNER='cloudstack-ui 4.22.1.1')

    def test_inactive_management_fails(self):
        self.check_preflight('must be healthy before deployment', TEST_SERVICE_RC='3')

    def test_incomplete_bundle_fails(self):
        for name in ('bundle.tar.gz', 'checksum', 'manifest'):
            with self.subTest(name=name):
                self.check_preflight('prebuilt UI bundle is incomplete', absent=name)


class BackendFingerprintTests(unittest.TestCase):
    def fingerprint(self, root, fail=False):
        result = subprocess.run(['bash', '-c', BACKEND_FUNCTION + '\nbackend_fingerprint "$1"',
                                 'fingerprint-test', str(root)], capture_output=True, text=True, timeout=5)
        if fail:
            self.assertNotEqual(result.returncode, 0)
        else:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertRegex(result.stdout, r'^[a-f0-9]{64}\n$')
        return result.stdout

    def test_copy_preserves_hash_and_file_mutation_changes_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = root / 'original'
            (original / 'WEB-INF/lib').mkdir(parents=True)
            (original / 'WEB-INF/web.xml').write_text('<web-app/>')
            (original / 'WEB-INF/lib/backend.jar').write_bytes(b'backend')
            candidate = root / 'candidate'
            shutil.copytree(original, candidate)
            before = self.fingerprint(original)
            self.assertEqual(before, self.fingerprint(candidate))
            (candidate / 'WEB-INF/lib/backend.jar').write_bytes(b'changed')
            self.assertNotEqual(before, self.fingerprint(candidate))

    def test_optional_directory_and_links_are_part_of_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'WEB-INF').mkdir()
            (root / 'WEB-INF/web.xml').write_text('<web-app/>')
            before = self.fingerprint(root)
            (root / 'META-INF').mkdir()
            self.assertNotEqual(before, self.fingerprint(root))
            (root / 'META-INF/context.xml').write_text('context')
            before = self.fingerprint(root)
            (root / 'META-INF/context.xml').write_text('changed')
            self.assertNotEqual(before, self.fingerprint(root))
            link = root / 'WEB-INF/config-link'
            link.symlink_to('/unread/external/config')
            before = self.fingerprint(root)
            link.unlink()
            link.symlink_to('/different/external/config')
            self.assertNotEqual(before, self.fingerprint(root))

    def test_backend_root_symlink_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'WEB-INF').symlink_to('/unread/external/backend')
            self.fingerprint(root, fail=True)

    def test_actual_stage_and_deploy_guards_reject_backend_changes(self):
        guards = [line for line in SOURCE.splitlines()
                  if line.startswith('[[ "$(backend_fingerprint ')]
        self.assertEqual(len(guards), 3)  # stage, deploy, final verification
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'WEB-INF').mkdir()
            (root / 'WEB-INF/web.xml').write_text('<web-app/>')
            before = self.fingerprint(root).strip()
            for changed in (False, True):
                if changed:
                    (root / 'WEB-INF/web.xml').write_text('<changed/>')
                for guard in guards:
                    with self.subTest(changed=changed, guard=guard):
                        harness = BACKEND_FUNCTION + '\n' + r'''
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
CANDIDATE=$1
SERVED_UI=$1
BACKEND_BEFORE=$2
'''
                        result = subprocess.run(['bash', '-c', harness + guard, 'guard-test',
                                                 str(root), before], capture_output=True, text=True, timeout=5)
                        self.assertEqual(result.returncode == 0, not changed, result.stderr)


if __name__ == '__main__':
    unittest.main()
