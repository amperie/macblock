import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class BrowserInstallerTests(unittest.TestCase):
    def test_profile_generation(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / 'profile.mobileconfig'
            env = dict(os.environ,
                MACBLOCK_CHROME_ID='a' * 32,
                MACBLOCK_CHROME_UPDATE='https://updates.example.test/update.xml',
                MACBLOCK_BROWSER_URL='https://parent.example.test',
                MACBLOCK_BROWSER_TOKEN='b' * 40,
                MACBLOCK_PROFILE_OUTPUT=str(output))
            subprocess.run([sys.executable, str(ROOT/'browser/generate-profile.py')],
                           env=env, check=True, capture_output=True)
            profile = plistlib.loads(output.read_bytes())
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            self.assertEqual(profile['PayloadType'], 'Configuration')
            settings = profile['PayloadContent'][0]['ExtensionSettings']['a' * 32]
            self.assertEqual(settings['installation_mode'], 'force_installed')
            self.assertEqual(settings['policy']['browserToken'], 'b' * 40)
            for invalid in ['http://example.test', 'https://user:pass@example.test', 'https://example.test/#fragment']:
                env['MACBLOCK_BROWSER_URL'] = invalid
                result = subprocess.run([sys.executable, str(ROOT/'browser/generate-profile.py')],
                                        env=env, capture_output=True)
                self.assertNotEqual(result.returncode, 0)

if __name__ == '__main__':
    unittest.main()
