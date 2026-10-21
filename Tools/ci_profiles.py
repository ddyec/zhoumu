"""Install explicit provisioning profiles and map all four targets for manual signing."""
import datetime
import os
from pathlib import Path
import plistlib
import re
import subprocess
import zipfile

bundle = os.environ['APP_BUNDLE_ID']
team = os.environ['IOS_TEAM_ID']
root = Path(os.environ['SIGN_DIR'])
required = {bundle + suffix for suffix in ('', '.widget', '.watchkitapp', '.watchkitapp.widget')}
profiles = {}
install = Path.home() / 'Library/MobileDevice/Provisioning Profiles'
install.mkdir(parents=True, exist_ok=True)
manifest = Path(os.environ['RUNNER_TEMP']) / 'zhoumu-installed-profiles.txt'
with zipfile.ZipFile(root / 'profiles.zip') as archive:
    for index, entry in enumerate(archive.infolist()):
        if not entry.filename.endswith('.mobileprovision') or entry.is_dir():
            continue
        assert entry.file_size < 2_000_000, 'Provisioning profile too large'
        # Do not extract untrusted zip paths.
        local = root / f'profile-{index}.mobileprovision'
        local.write_bytes(archive.read(entry))
        data = subprocess.check_output(['security', 'cms', '-D', '-i', str(local)])
        profile = plistlib.loads(data)
        entitlements = profile['Entitlements']
        app = entitlements['application-identifier'].split('.', 1)[1]
        if app not in required:
            continue
        assert team in profile['TeamIdentifier'], f'Wrong team: {app}'
        assert profile['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), f'Expired: {app}'
        assert 'group.' + bundle in entitlements.get('com.apple.security.application-groups', []), f'Missing App Group: {app}'
        uuid = profile['UUID']
        assert re.fullmatch(r'[A-Fa-f0-9-]+', uuid), 'Invalid UUID'
        assert app not in profiles, f'Duplicate profiles: {app}'
        profiles[app] = uuid
        (install / f'{uuid}.mobileprovision').write_bytes(local.read_bytes())
        with manifest.open('a') as f:
            f.write(uuid + '\n')
assert profiles.keys() == required, f'Missing profiles: {required - profiles.keys()}'
project = Path('ZhouMu.xcodeproj/project.pbxproj')
text = project.read_text()
def configure(match):
    body = match.group(0)
    identifier = re.search(r'PRODUCT_BUNDLE_IDENTIFIER = "\$\(APP_BUNDLE_ID\)([^"\n]*)";', body)
    if identifier:
        app = bundle + identifier.group(1)
        body = re.sub(r'\n\s*CODE_SIGN_STYLE = [^;]+;', '', body)
        body = body.replace('buildSettings = {', 'buildSettings = {\n\t\t\t\tCODE_SIGN_STYLE = Manual;\n'
                            f'\t\t\t\tPROVISIONING_PROFILE_SPECIFIER = "{profiles[app]}";')
    return body
text = re.sub(r'buildSettings = \{[^{}]*\}', configure, text)
assert text.count('PROVISIONING_PROFILE_SPECIFIER') == 8, 'Expected Debug and Release profiles for four targets'
project.write_text(text)
method = os.environ.get('EXPORT_METHOD', 'development')
assert method in ('development', 'ad-hoc', 'app-store'), 'Invalid export method'
Path('build/CIExportOptions.plist').write_bytes(plistlib.dumps({
    'method': method, 'teamID': team, 'signingStyle': 'manual',
    'provisioningProfiles': profiles, 'uploadSymbols': True,
}))
