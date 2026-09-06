"""Offline DC wrapper guards; these do not represent live UI acceptance."""
import contextlib
import io
import json
import pathlib
import re
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parent
BLOCKS = re.findall(r"<<'PY'\n(.*?)\nPY", (ROOT / 'deploy-dc-current-ui.sh').read_text(), re.S)


class DcUiGuards(unittest.TestCase):
    def identity(self, bios, mac='00:15:5d:00:39:0a', ip='10.10.10.14'):
        replies = [json.dumps([{'address': mac, 'master': 'cloudbr0'}]).encode(),
                   json.dumps([{'addr_info': [{'local': ip, 'prefixlen': 24}]}]).encode()]
        with patch('os.geteuid', return_value=0), patch('pathlib.Path.read_text', return_value=bios), patch('subprocess.check_output', side_effect=replies):
            exec(compile(BLOCKS[0], '<identity-guard>', 'exec'), {})

    def test_wrong_vm_bios_nic_and_address_rejected(self):
        bios = 'ccbcac90-c8e3-4091-90a0-7e2e8cf2f7e5'
        self.identity(bios)
        for values in [('29ba176b-b81a-4f47-8f51-ecec869f247f',), (bios, '00:15:5d:00:00:00'), (bios, '00:15:5d:00:39:0a', '10.10.10.20')]:
            with self.assertRaises(AssertionError): self.identity(*values)

    def config(self, index, root, config):
        code = BLOCKS[index].replace("'/etc/cloudstack/management/server.properties'", repr(str(config))).replace('s.st_uid==0', 's.st_uid==__import__("os").getuid()')
        with patch('sys.argv', ['guard', str(root)]), contextlib.redirect_stdout(io.StringIO()):
            exec(compile(code, '<config-guard>', 'exec'), {})

    def test_original_config_bytes_and_metadata_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory); config = root / 'server.properties'
            original = b'# retain comments\r\nhttp.port=8080\r\nhttps.enable=false\n'
            config.write_bytes(original); config.chmod(0o640)
            self.config(1, root, config); self.config(2, root, config)
            config.write_bytes(original + b'http.port=9000\n')
            with self.assertRaises(AssertionError): self.config(2, root, config)
            config.write_bytes(original); config.chmod(0o600)
            with self.assertRaises(AssertionError): self.config(2, root, config)

    def test_private_backup_cannot_be_overwritten_or_follow_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory); config = root / 'server.properties'
            config.write_text('http.port=8080\n'); config.chmod(0o640)
            (root / 'dc-server.properties.before').symlink_to(config)
            with self.assertRaises(FileExistsError): self.config(1, root, config)
            self.assertEqual(config.read_text(), 'http.port=8080\n')


if __name__ == '__main__': unittest.main()
