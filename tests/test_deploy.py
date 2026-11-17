import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import sqlite3

spec = importlib.util.spec_from_file_location('release', Path(__file__).resolve().parents[1] / 'deploy/release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def archive(extra=None):
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode='w') as output:
        for name in sorted(release.FILES):
            body = b'pass\n' if name.endswith('.py') else b'asset'
            member = tarfile.TarInfo(name)
            member.size = len(body)
            output.addfile(member, io.BytesIO(body))
        if extra:
            output.addfile(extra)
    return data.getvalue()


class DeploymentTests(unittest.TestCase):
    def test_archive_accepts_only_complete_regular_server_files(self):
        with tempfile.TemporaryDirectory() as directory:
            release.unpack(archive(), Path(directory))
            self.assertEqual((Path(directory) / 'server/server.py').read_text(), 'pass\n')
        for name, kind in [('../escape', tarfile.REGTYPE), ('server/app.js', tarfile.SYMTYPE),
                           ('server/app.js', tarfile.REGTYPE)]:
            with self.subTest(name=name, kind=kind), tempfile.TemporaryDirectory() as directory:
                extra = tarfile.TarInfo(name)
                extra.type = kind
                with self.assertRaises(ValueError):
                    release.unpack(archive(extra), Path(directory))

    def test_failed_health_check_restores_code_and_database(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'app'
            state = Path(directory) / 'state'
            root.mkdir()
            state.mkdir()
            previous = root / 'old'
            previous.mkdir()
            (root / 'current').symlink_to(previous)
            database = state / 'state.sqlite3'
            with sqlite3.connect(database) as conn:
                conn.execute('CREATE TABLE original (id INTEGER)')

            def probe(config):
                if (root / 'current').resolve() == previous.resolve():
                    return True
                with sqlite3.connect(database) as conn:
                    conn.execute('DROP TABLE original')
                return False

            stdin = type('Input', (), {'buffer': io.BytesIO(archive())})()
            with patch.object(release, 'ROOT', root), patch.object(release, 'STATE', state), \
                 patch.object(release.sys, 'stdin', stdin), patch.object(release, 'settings', return_value={}), \
                 patch.object(release.subprocess, 'run') as command, patch.object(release, 'healthy', side_effect=probe), \
                 patch.object(release.shutil, 'chown'):
                with self.assertRaisesRegex(RuntimeError, 'New release failed'):
                    release.deploy('a' * 40)
                self.assertEqual(command.call_count, 4)
            self.assertEqual((root / 'current').resolve(), previous.resolve())
            with sqlite3.connect(database) as conn:
                self.assertEqual(conn.execute('SELECT count(*) FROM original').fetchone()[0], 0)
            self.assertEqual(len(list((state / 'backups').iterdir())), 1)
