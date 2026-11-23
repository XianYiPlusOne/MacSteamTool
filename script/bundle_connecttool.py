#!/usr/bin/env python3
"""Bundle the in-process Steamworks adapter and the privileged utun helper."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'work'
MANIFEST = ROOT / 'Resources/ConnectTool/release.json'
PROTON_REV = '164e0ccd2ea2b1ec2e5d08dc97f65b184c2539ca'
PROTON_SHA = '136aa6600501e279dba0b1efaee9f81e837d043a296f4286e1d3f966ca1e007a'
MAGIC = {bytes.fromhex(value) for value in (
    'feedface', 'cefaedfe', 'feedfacf', 'cffaedfe',
    'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def download(path, url, sha):
    if path.is_file() and digest(path) == sha:
        return path
    partial = path.with_suffix('.download')
    run('curl', '--fail', '--location', '--retry', '3', '--connect-timeout', '20',
        '--max-time', '1200', '--proto', '=https', '--proto-redir', '=https', url, '-o', partial)
    if digest(partial) != sha:
        partial.unlink(missing_ok=True)
        raise RuntimeError('SHA-256 mismatch: ' + url)
    partial.replace(path)
    return path


def extract_subset(archive, destination, prefix):
    """Only regular files inside a pinned prefix; never follow archive links."""
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    with tarfile.open(archive) as source:
        for member in source:
            if not member.isfile() or not member.name.startswith(prefix):
                continue
            relative = Path(member.name[len(prefix):])
            if relative.is_absolute() or '..' in relative.parts:
                raise RuntimeError('Unsafe archive member')
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            with source.extractfile(member) as incoming, target.open('wb') as outgoing:
                shutil.copyfileobj(incoming, outgoing)


def steam_headers():
    proton = download(WORK / ('connecttool-proton-' + PROTON_REV + '.tar.gz'),
                      'https://codeload.github.com/ValveSoftware/Proton/tar.gz/' + PROTON_REV, PROTON_SHA)
    steam = WORK / 'connecttool-steam-headers'
    revision = PROTON_SHA + ':sdk165-cpp-inline-v1'
    if not (steam / '.fluent-sha').is_file() or (steam / '.fluent-sha').read_text() != revision:
        extract_subset(proton, steam, 'Proton-' + PROTON_REV + '/lsteamclient/steamworks_sdk_165/')
        # Proton disables C++ inline helpers and names these unions for its C ABI
        # generator. Restore the SDK C++ spelling without changing binary layouts.
        for name in ['steamnetworkingtypes.h', 'isteamnetworkingutils.h']:
            path = steam / name
            source = path.read_text().replace('#if 0\n', '#if 1 // MacSteamTool: restore SDK C++ inline helpers\n')
            if name == 'steamnetworkingtypes.h':
                assert source.count('\t} data;') == 2
                source = source.replace('\t} data;', '\t};')
            path.write_text(source)
        (steam / '.fluent-sha').write_text(revision)
    return steam


def copy_steam_api(dmg, release, target):
    with tempfile.TemporaryDirectory(prefix='steam-api-mount-', dir=WORK) as temp:
        mount = Path(temp) / 'volume'
        run('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, dmg, stdout=subprocess.DEVNULL)
        try:
            shutil.copy2(mount / release['bundle'] / 'Contents/Frameworks/libsteam_api.dylib', target)
        finally:
            run('hdiutil', 'detach', mount, stdout=subprocess.DEVNULL)


def machos(root):
    for path in root.rglob('*'):
        if path.is_symlink() or not path.is_file(): continue
        with path.open('rb') as stream:
            if stream.read(4) in MAGIC: yield path


def verify(destination, architecture=None):
    destination = destination.resolve()
    binaries = set(machos(destination))
    expected = {destination / name for name in ('Frameworks/libMacMultiplayer.dylib',
                'Frameworks/libsteam_api.dylib', 'Resources/connecttool-tun-daemon')}
    if binaries != expected:
        raise RuntimeError(f'Unexpected multiplayer binaries: {binaries ^ expected}')
    if not (destination / 'Resources/com.connecttool.tunhelper.plist').is_file():
        raise RuntimeError('Missing utun launch daemon configuration')
    frameworks = destination / 'Frameworks'
    for path in sorted(binaries):
        archs = run('lipo', '-archs', path, capture_output=True, text=True).stdout.split()
        required = {architecture} if architecture else {'arm64', 'x86_64'}
        if not required.issubset(archs):
            label = architecture or 'arm64 and x86_64'
            raise RuntimeError(f'Multiplayer component {path.relative_to(destination)} must support {label}; found {archs}')
        listing = run('otool', '-L', path, capture_output=True, text=True).stdout
        for line in listing.splitlines():
            if not line.startswith('\t'): continue  # handles universal architecture headers
            dep = line.strip().split(' (compatibility version', 1)[0]
            if dep.startswith(('/System/', '/usr/lib/')): continue
            if dep.startswith('@rpath/'):
                resolved = frameworks / dep[len('@rpath/'):]
            elif dep.startswith('@loader_path/'):
                resolved = path.parent / dep[len('@loader_path/'):]
            elif dep.startswith('@executable_path/'):
                resolved = destination / 'MacOS' / dep[len('@executable_path/'):]
            else:
                raise RuntimeError(f'External dependency {dep} in {path}')
            if resolved.resolve() not in binaries:
                raise RuntimeError(f'Missing bundled Mach-O dependency {dep} in {path}')
        commands = run('otool', '-l', path, capture_output=True, text=True).stdout
        for rpath in re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', commands):
            if not rpath.startswith(('@loader_path', '@executable_path')):
                raise RuntimeError(f'Build-machine rpath {rpath} in {path}')
        run('codesign', '--verify', '--strict', path, stdout=subprocess.DEVNULL)
    print('Verified in-process Steamworks adapter and signed universal utun helper')


def bundle(destination):
    WORK.mkdir(exist_ok=True)
    release = json.loads(MANIFEST.read_text())
    dmg = download(WORK / ('connecttool-qt-v' + release['version'] + '.dmg'), release['url'], release['sha256'])
    headers = steam_headers()
    native = ROOT / 'Native/ConnectTool'
    upstream = native / 'upstream/src'
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='multiplayer-build-', dir=destination.parent) as scratch:
        stage = Path(scratch) / 'payload'
        frameworks = stage / 'Frameworks'
        resources = stage / 'Resources'
        frameworks.mkdir(parents=True)
        resources.mkdir()
        steam = frameworks / 'libsteam_api.dylib'
        copy_steam_api(dmg, release, steam)
        compiler = ['xcrun', 'clang++', '-std=c++20', '-O2', '-mmacosx-version-min=14.0', '-I', upstream]
        for architecture in release['runtimeArchitectures']:
            compiler.extend(['-arch', architecture])
        tun = upstream / 'platform/tun'
        run(*compiler, '-dynamiclib', '-fvisibility=hidden', '-DMP_APP_BINDINGS',
            '-I', ROOT / 'Sources/CMultiplayer', '-I', headers, native / 'SteamBindings.cpp',
            tun / 'tun_privileged_helper.cpp', steam, '-install_name', '@rpath/libMacMultiplayer.dylib',
            '-o', frameworks / 'libMacMultiplayer.dylib')
        run(*compiler, tun / 'tun_macos_daemon.cpp', tun / 'tun_privileged_helper.cpp',
            '-o', resources / 'connecttool-tun-daemon')
        shutil.copy2(native / 'Resources/com.connecttool.tunhelper.plist', resources)
        shutil.copy2(ROOT / 'Licenses/ConnectTool-MIT.txt', resources)
        shutil.copy2(native / 'PROVENANCE.md', resources)
        shutil.copy2(MANIFEST, resources / 'release.json')
        for path in machos(stage):
            run('codesign', '--force', '--sign', '-', path, stdout=subprocess.DEVNULL)
        verify(stage)
        previous = Path(scratch) / 'previous'
        if destination.exists():
            destination.rename(previous)
        try:
            stage.rename(destination)
        except OSError:
            if previous.exists():
                previous.rename(destination)
            raise


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--verify': verify(Path(sys.argv[2]).resolve())
    elif len(sys.argv) == 2: bundle(Path(sys.argv[1]).resolve())
    else: sys.exit('Usage: bundle_connecttool.py [--verify] <ConnectTool runtime directory>')
