"""Public policy routing checks without opening network listeners."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
import io
import tarfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('privacy_server', ROOT / 'server/server.py')
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


class PrivacyTests(unittest.TestCase):
    def test_policy_is_public_and_does_not_access_database(self):
        for path in ['/privacy', '/privacy/', '/privacy?source=store']:
            with self.subTest(path=path):
                handler = object.__new__(server.Handler)
                handler.path = path
                handler.reply = Mock()
                handler.authorized = Mock(side_effect=AssertionError('Policy must not require login'))
                with patch.object(server.sqlite3, 'connect', side_effect=AssertionError('No database access')):
                    handler.do_GET()
                handler.reply.assert_called_once_with(200, server.PRIVACY_HTML, 'text/html; charset=utf-8')
                handler.authorized.assert_not_called()
        self.assertIn('hostname', server.PRIVACY_HTML)
        self.assertIn('authentication token', server.PRIVACY_HTML)
        self.assertIn('90 days', server.PRIVACY_HTML)
        self.assertIn('Limited Use', server.PRIVACY_HTML)
        self.assertIn('deletion', server.PRIVACY_HTML)
        self.assertNotIn('<script', server.PRIVACY_HTML)

    def test_dashboard_links_to_public_policy(self):
        self.assertIn('href="/privacy"', (ROOT / 'server/index.html').read_text())

    def test_existing_release_helper_packages_the_policy(self):
        release_spec = importlib.util.spec_from_file_location('privacy_release', ROOT / 'deploy/release.py')
        release = importlib.util.module_from_spec(release_spec)
        release_spec.loader.exec_module(release)
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode='w') as output:
            for name in sorted(release.FILES):
                output.add(ROOT / name, arcname=name)
        with tempfile.TemporaryDirectory() as directory:
            release.unpack(archive.getvalue(), Path(directory))
            deployed = (Path(directory) / 'server/server.py').read_text()
            self.assertIn('Orbit privacy policy', deployed)
            self.assertIn('"/privacy"', deployed)
