import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tunefree_backend import cli, meta


class HomeCoversTest(unittest.TestCase):
    def test_cached_only_never_fetches_or_downloads(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, 'songs'))
            with open(os.path.join(root, 'songs', '1.json'), 'w') as f:
                json.dump({'title': 'Song', 'album_mid': 'album'}, f)
            client = meta.Client(cache_dir=root)
            with patch.object(client, '_open', side_effect=AssertionError('network')), patch.object(client, 'fetch', side_effect=AssertionError('fetch')):
                self.assertIsNone(client.preview(2, allow_network=False))
                self.assertEqual(client.preview(1, allow_network=False)['cover'], '')
                with open(os.path.join(root, 'album.jpg'), 'wb') as f:
                    f.write(b'x' * 2048)
                self.assertEqual(client.preview(1, allow_network=False)['cover'], os.path.join(root, 'album.jpg'))

    def test_distinct_covers_and_bounded_sample(self):
        with tempfile.TemporaryDirectory() as root:
            for i in range(40):
                open(os.path.join(root, '%d.mflac' % i), 'w').close()
            with patch.object(cli.decrypt, 'probe', return_value={'song_id': 1}) as probe, patch.object(meta.Client, 'preview', return_value={'cover': '/cached/shared.jpg'}):
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    cli.cmd_home_covers(root, cli.Reporter(True), allow_network=False)
                self.assertEqual(len(out.getvalue().splitlines()), 1)
                self.assertLessEqual(probe.call_count, 12)

    def test_missing_folder_is_quiet(self):
        with patch.object(meta.Client, 'preview') as preview, contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(cli.cmd_home_covers('/nonexistent/tunefree', cli.Reporter(True)), 0)
            preview.assert_not_called()
            self.assertEqual(out.getvalue(), '')

    def test_stops_after_three_unique_covers(self):
        with tempfile.TemporaryDirectory() as root:
            for i in range(20):
                open(os.path.join(root, '%d.mflac' % i), 'w').close()
            def probe(path): return {'song_id': int(os.path.basename(path).split('.')[0]) + 1}
            def preview(self, song_id, *args, **kwargs): return {'cover': '/cached/%d.jpg' % song_id}
            with patch.object(cli.decrypt, 'probe', side_effect=probe), patch.object(meta.Client, 'preview', preview), contextlib.redirect_stdout(io.StringIO()) as out:
                cli.cmd_home_covers(root, cli.Reporter(True))
                rows = [json.loads(line) for line in out.getvalue().splitlines()]
                self.assertEqual(len(rows), 3)
                self.assertEqual(len({r['cover'] for r in rows}), 3)
