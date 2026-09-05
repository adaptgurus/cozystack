"""Run the deployment's real package/filesystem preflight in an isolated fixture.

No root, RPM installation, service mutation or live CloudStack host is used.
The script stays standalone for transport to the Rocky management host.
"""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name('deploy-dr-cloudstack-ui.sh')
SOURCE = SCRIPT.read_text()
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
      [[ $# -eq 4 && $2 == --qf && $3 == '%{NAME} %{VERSION}\n' && $4 == "$SERVED_UI/index.html" ]] || return 91
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
                'TEST_SERVICE_RC': '0', **overrides,
            }
            result = subprocess.run(
                ['bash', '-c', HARNESS + PREFLIGHT + '\nprintf "PREFLIGHT_PASS\\n"',
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
        for name in ('WEB-INF', 'META-INF'):
            with self.subTest(name=name):
                self.check_preflight('backend WEB-INF/META-INF content is missing', absent=name)

    def test_inactive_management_fails(self):
        self.check_preflight('must be healthy before deployment', TEST_SERVICE_RC='3')

    def test_incomplete_bundle_fails(self):
        for name in ('bundle.tar.gz', 'checksum', 'manifest'):
            with self.subTest(name=name):
                self.check_preflight('prebuilt UI bundle is incomplete', absent=name)


if __name__ == '__main__':
    unittest.main()
