"""CLI manifests must constrain both previews and conversion input."""
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tunefree_backend import cli


class InputListTest(unittest.TestCase):
    def test_preview_uses_selected_paths_only(self):
        with tempfile.TemporaryDirectory() as root:
            paths = [os.path.join(root, name + '.mflac') for name in ('a', 'b')]
            manifest = os.path.join(root, 'input.json')
            with open(manifest, 'w') as stream:
                json.dump({'files': [paths[1], paths[1]], 'batch_files': paths}, stream)
            with patch.object(cli, 'cmd_info', return_value=0) as preview:
                self.assertEqual(cli.main(['--info', '--json', '--input-list', manifest]), 0)
            self.assertEqual(preview.call_args.args[0], [paths[1]])

    def test_invalid_manifest_does_not_fall_back_to_directory_scan(self):
        with tempfile.TemporaryDirectory() as root:
            manifest = os.path.join(root, 'input.json')
            for data in ({'files': ['relative.mflac']}, {'files': ['/a'], 'batch_files': ['/b']}, {}):
                with open(manifest, 'w') as stream:
                    json.dump(data, stream)
                with contextlib.redirect_stdout(io.StringIO()), patch.object(cli.job_mod, 'scan_inputs') as scan:
                    self.assertEqual(cli.main(['--info', '--json', '--input-list', manifest]), 1)
                    scan.assert_not_called()
