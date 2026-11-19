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
                ORBIT_CHROME_ID='a' * 32,
                ORBIT_CHROME_UPDATE='https://updates.example.test/update.xml',
                ORBIT_BROWSER_URL='https://parent.example.test',
                ORBIT_BROWSER_TOKEN='b' * 40,
                ORBIT_PROFILE_OUTPUT=str(output))
            subprocess.run([sys.executable, str(ROOT/'browser/generate-profile.py')],
                           env=env, check=True, capture_output=True)
            profile = plistlib.loads(output.read_bytes())
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            self.assertEqual(profile['PayloadType'], 'Configuration')
            chromePayload, storagePayload = profile['PayloadContent']
            self.assertEqual(chromePayload['PayloadType'], 'com.apple.ManagedClient.preferences')
            self.assertEqual(storagePayload['PayloadType'], 'com.apple.ManagedClient.preferences')
            chrome = chromePayload['PayloadContent']['com.google.Chrome']['Forced'][0]['mcx_preference_settings']
            storage = storagePayload['PayloadContent']['com.google.Chrome.extensions.' + 'a' * 32]['Forced'][0]['mcx_preference_settings']
            settings = chrome['ExtensionSettings']['a' * 32]
            self.assertEqual(settings['installation_mode'], 'force_installed')
            self.assertNotIn('policy', settings)
            self.assertEqual(profile['PayloadScope'], 'System')
            self.assertEqual(chrome['IncognitoModeAvailability'], 1)
            self.assertIs(chrome['BrowserGuestModeEnabled'], False)
            self.assertEqual(storage['browserToken'], 'b' * 40)
            self.assertEqual(storage['serverURL'], 'https://parent.example.test')
            for invalid in ['http://example.test', 'https://user:pass@example.test', 'https://example.test/#fragment',
                            'https://example.test/?token=x', 'https://example.test/path',
                            'https://example.test:invalid', 'https://example.test:99999']:
                env['ORBIT_BROWSER_URL'] = invalid
                result = subprocess.run([sys.executable, str(ROOT/'browser/generate-profile.py')],
                                        env=env, capture_output=True)
                self.assertNotEqual(result.returncode, 0)

if __name__ == '__main__':
    unittest.main()
