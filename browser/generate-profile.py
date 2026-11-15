"""Generate a macOS Chrome policy configuration profile without shell interpolation."""
import os
import plistlib
import re
import uuid
from pathlib import Path
from urllib.parse import urlsplit

extension_id = os.environ['MACBLOCK_CHROME_ID']
update_url = os.environ['MACBLOCK_CHROME_UPDATE']
server_url = os.environ['MACBLOCK_BROWSER_URL']
token = os.environ['MACBLOCK_BROWSER_TOKEN']
destination = Path(os.environ['MACBLOCK_PROFILE_OUTPUT'])

if not re.fullmatch(r'[a-p]{32}', extension_id):
    raise ValueError('Invalid Chrome extension ID')
for value in (update_url, server_url):
    parts = urlsplit(value)
    if parts.scheme != 'https' or not parts.hostname or parts.username or parts.password or parts.fragment:
        raise ValueError('HTTPS URL without embedded credentials required')
if len(token) < 32:
    raise ValueError('Invalid browser token')

# Chrome enterprise policy. Browser token is readable by the browser user,
# so it must have only read-only access to the domain policy endpoint.
settings = {
    extension_id: {
        'installation_mode': 'force_installed',
        'update_url': update_url,
        'policy': {'serverURL': server_url, 'browserToken': token},
    }
}
profile = {
    'PayloadType': 'Configuration',
    'PayloadVersion': 1,
    'PayloadIdentifier': 'com.macblock.chrome.configuration',
    'PayloadUUID': str(uuid.uuid4()).upper(),
    'PayloadDisplayName': 'MacBlock Chrome Browser Policy',
    'PayloadOrganization': 'MacBlock',
    'PayloadRemovalDisallowed': False,
    'PayloadContent': [{
        'PayloadType': 'com.google.Chrome',
        'PayloadVersion': 1,
        'PayloadIdentifier': 'com.macblock.chrome.policy',
        'PayloadUUID': str(uuid.uuid4()).upper(),
        'PayloadDisplayName': 'Chrome managed extension settings',
        'ExtensionSettings': settings,
    }],
}
destination.parent.mkdir(parents=True, exist_ok=True)
with destination.open('wb') as file:
    plistlib.dump(profile, file)
print('Generated', destination)
