"""Generate a macOS Chrome policy configuration profile without shell interpolation."""
import os
import plistlib
import re
import uuid
import tempfile
from pathlib import Path
from urllib.parse import urlsplit

extension_id = os.environ['ORBIT_CHROME_ID']
update_url = os.environ['ORBIT_CHROME_UPDATE']
server_url = os.environ['ORBIT_BROWSER_URL']
token = os.environ['ORBIT_BROWSER_TOKEN']
destination = Path(os.environ['ORBIT_PROFILE_OUTPUT'])

if not re.fullmatch(r'[a-p]{32}', extension_id):
    raise ValueError('Invalid Chrome extension ID')
for value in (update_url, server_url):
    parts = urlsplit(value)
    if parts.scheme != 'https' or not parts.hostname or parts.username or parts.password or parts.fragment or any(ch.isspace() for ch in value):
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
    'PayloadIdentifier': 'com.side-forge.orbit.chrome.configuration',
    'PayloadUUID': str(uuid.uuid4()).upper(),
    'PayloadDisplayName': 'Orbit Chrome Browser Policy',
    'PayloadOrganization': 'Orbit',
    'PayloadRemovalDisallowed': False,
    'PayloadContent': [{
        'PayloadType': 'com.google.Chrome',
        'PayloadVersion': 1,
        'PayloadIdentifier': 'com.side-forge.orbit.chrome.policy',
        'PayloadUUID': str(uuid.uuid4()).upper(),
        'PayloadDisplayName': 'Chrome managed extension settings',
        'ExtensionSettings': settings,
    }],
}
destination.parent.mkdir(parents=True, exist_ok=True)
if destination.is_symlink():
    raise ValueError('Refusing symlinked profile destination')
fd, temporary = tempfile.mkstemp(prefix='.orbit-', suffix='.mobileconfig', dir=destination.parent)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, 'wb') as file:
        plistlib.dump(profile, file)
    os.replace(temporary, destination)
except BaseException:
    if os.path.exists(temporary):
        os.unlink(temporary)
    raise
print('Generated', destination)
