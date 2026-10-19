#!/usr/bin/env bash
set -euo pipefail

# Official Android command-line tools 19.0, verified against Google's repository
# metadata SHA-1 before recording this SHA-256. TLS and archive checks stay enabled.
export ANDROID_HOME="${ANDROID_HOME:-/workspace/.tooling/android-sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_USER_HOME="${ANDROID_USER_HOME:-/workspace/.cache/android}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/workspace/.cache/config}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/workspace/.cache}"

python3 - <<'PY'
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import urlopen
import hashlib
import os
import shutil
import subprocess
import tempfile
import zipfile

sdk = Path(os.environ['ANDROID_HOME'])
latest = sdk / 'cmdline-tools' / 'latest'
pinned = sdk / 'cmdline-tools' / '19.0'
latest_properties = latest / 'source.properties'
if latest_properties.exists() and 'Pkg.Revision=19.0' in latest_properties.read_text():
    tools = latest
else:
    tools = pinned

if not (tools / 'bin' / 'sdkmanager').exists():
    url = 'https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip'
    sha256 = '7ec965280a073311c339e571cd5de778b9975026cfcbe79f2b1cdcb1e15317ee'
    with tempfile.TemporaryDirectory(prefix='ma3ak-android-') as scratch:
        archive = Path(scratch) / 'commandline-tools.zip'
        digest = hashlib.sha256()
        with urlopen(url, timeout=120) as response, archive.open('wb') as output:
            while chunk := response.read(1024 * 1024):
                digest.update(chunk)
                output.write(chunk)
        if digest.hexdigest() != sha256:
            raise SystemExit('Android command-line tools checksum verification failed.')
        extracted = Path(scratch) / 'extracted'
        with zipfile.ZipFile(archive) as compressed:
            for member in compressed.infolist():
                target = (extracted / member.filename).resolve()
                if not target.is_relative_to(extracted.resolve()):
                    raise SystemExit('Unexpected Android archive path.')
            compressed.extractall(extracted)
        tools.parent.mkdir(parents=True, exist_ok=True)
        if tools.exists():
            raise SystemExit(f'Refusing to overwrite existing Android tools: {tools}')
        shutil.move(str(extracted / 'cmdline-tools'), str(tools))
        for executable in (tools / 'bin').iterdir():
            executable.chmod(0o755)

command = [str(tools / 'bin' / 'sdkmanager'), '--sdk_root=' + str(sdk)]
# sdkmanager's Java HTTP client needs explicit proxy flags. No secrets are printed.
proxy = urlsplit(os.environ.get('HTTPS_PROXY') or os.environ.get('https_proxy') or '')
if proxy.hostname:
    command += ['--proxy=http', '--proxy_host=' + proxy.hostname,
                '--proxy_port=' + str(proxy.port or 80)]

# Accept standard Android SDK package licenses required by this environment.
subprocess.run(command + ['--licenses'], input='y\n' * 100, text=True, check=True)
subprocess.run(command + ['platform-tools', 'platforms;android-35', 'build-tools;35.0.0',
                          'platforms;android-36', 'build-tools;36.0.0',
                          'ndk;27.0.12077973', 'cmake;3.22.1'],
               input='y\n' * 100, text=True, check=True)
print('Android SDK platforms/build tools 35 and 36, NDK 27.0.12077973, CMake 3.22.1 and platform tools are installed.')
PY
