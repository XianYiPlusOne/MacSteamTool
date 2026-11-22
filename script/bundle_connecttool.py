#!/usr/bin/env python3
"""Build a windowless ConnectTool service; never bundle or launch the upstream GUI."""
import hashlib
import json
import os
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
QT_VERSION = '6.11.1'
BOOST_SHA = '3621533e820dcab1e8012afd583c0c73cf0f77694952b81352bf38c1488f9cb4'
PROTON_REV = '164e0ccd2ea2b1ec2e5d08dc97f65b184c2539ca'
PROTON_SHA = '136aa6600501e279dba0b1efaee9f81e837d043a296f4286e1d3f966ca1e007a'
MAGIC = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}


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


def dependencies():
    qt = WORK / 'connecttool-qt-sdk' / QT_VERSION / 'macos'
    if not (qt / 'lib/cmake/Qt6/Qt6Config.cmake').is_file():
        venv = WORK / 'connecttool-build-tools'
        if not (venv / 'bin/python').exists():
            run(sys.executable, '-m', 'venv', venv)
        run(venv / 'bin/python', '-m', 'pip', 'install', 'aqtinstall==3.3.0')
        # aqt verifies the Qt repository's archive checksums. Only Qt Base is needed.
        run(venv / 'bin/aqt', 'install-qt', 'mac', 'desktop', QT_VERSION, 'clang_64',
            '--archives', 'qtbase', '--outputdir', WORK / 'connecttool-qt-sdk', cwd=WORK)
    boost_archive = download(WORK / 'connecttool-boost.tar.gz',
                            'https://archives.boost.io/release/1.88.0/source/boost_1_88_0.tar.gz', BOOST_SHA)
    boost = WORK / 'connecttool-boost'
    if not (boost / '.fluent-sha').is_file() or (boost / '.fluent-sha').read_text() != BOOST_SHA:
        # Boost is header-only here. Extract its boost/ subtree and license only.
        extract_subset(boost_archive, boost, 'boost_1_88_0/boost/')
        headers = WORK / 'connecttool-boost-headers'
        if headers.exists(): shutil.rmtree(headers)
        headers.mkdir()
        shutil.move(str(boost), str(headers / 'boost'))
        headers.rename(boost)
        (boost / '.fluent-sha').write_text(BOOST_SHA)
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
    return qt, boost, steam


def copy_runtime(dmg, release):
    destination = WORK / 'connecttool-runtime'
    if destination.exists(): shutil.rmtree(destination)
    destination.mkdir()
    with tempfile.TemporaryDirectory(prefix='connecttool-mount-', dir=WORK) as temp:
        mount = Path(temp) / 'volume'
        run('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, dmg, stdout=subprocess.DEVNULL)
        try:
            source = mount / release['bundle'] / 'Contents'
            for name in ['QtCore.framework', 'QtGui.framework', 'QtNetwork.framework', 'QtDBus.framework',
                         'libsteam_api.dylib', 'libsteamwebrtc.dylib']:
                target = destination / 'Frameworks' / name
                target.parent.mkdir(exist_ok=True)
                run('ditto', source / 'Frameworks' / name, target)
            target = destination / 'PlugIns/tls'
            target.mkdir(parents=True)
            shutil.copy2(source / 'PlugIns/tls/libqsecuretransportbackend.dylib', target)
        finally:
            run('hdiutil', 'detach', mount, stdout=subprocess.DEVNULL)
    return destination


def machos(root):
    for path in root.rglob('*'):
        if path.is_symlink() or not path.is_file(): continue
        with path.open('rb') as stream:
            if stream.read(4) in MAGIC: yield path


def verify(destination):
    for relative in ['MacOS/MacSteamToolConnect', 'Resources/connecttool-tun-daemon',
                     'Resources/com.connecttool.tunhelper.plist', 'MacOS/qt.conf',
                     'Frameworks/libsteam_api.dylib', 'Frameworks/libsteamwebrtc.dylib',
                     'PlugIns/tls/libqsecuretransportbackend.dylib']:
        if not (destination / relative).is_file(): raise RuntimeError('Missing service asset: ' + relative)
    if list(destination.rglob('*.app')) or list(destination.rglob('*QtQuick*')) or list(destination.rglob('connecttool-qt')):
        raise RuntimeError('Independent GUI content must not be bundled')
    frameworks = destination / 'Frameworks'
    for path in machos(destination):
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
            if not resolved.exists(): raise RuntimeError(f'Missing dependency {dep} in {path}')
        commands = run('otool', '-l', path, capture_output=True, text=True).stdout
        for rpath in re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', commands):
            if not rpath.startswith(('@loader_path', '@executable_path')):
                raise RuntimeError(f'Build-machine rpath {rpath} in {path}')
        run('codesign', '--verify', '--strict', path, stdout=subprocess.DEVNULL)
    archs = run('lipo', '-archs', destination / 'Resources/connecttool-tun-daemon', capture_output=True, text=True).stdout.split()
    if set(archs) != {'arm64', 'x86_64'}: raise RuntimeError('The system TUN helper must support both Mac architectures')
    print('Verified windowless ConnectTool runtime, dependencies and signatures')


def bundle(destination):
    WORK.mkdir(exist_ok=True)
    release = json.loads(MANIFEST.read_text())
    dmg = download(WORK / ('connecttool-qt-v' + release['version'] + '.dmg'), release['url'], release['sha256'])
    qt, boost, steam = dependencies()
    runtime = copy_runtime(dmg, release)
    build = WORK / 'connecttool-native-build'
    run('cmake', '-S', ROOT / 'Native/ConnectTool', '-B', build, '-DCMAKE_BUILD_TYPE=Release',
        '-DCMAKE_OSX_ARCHITECTURES=x86_64', '-DCMAKE_PREFIX_PATH=' + str(qt),
        '-DSTEAM_HEADERS=' + str(steam), '-DBOOST_HEADERS=' + str(boost),
        '-DSTEAM_LIBRARY=' + str(runtime / 'Frameworks/libsteam_api.dylib'),
        '-DSTEAM_LIBRARY_DIR=' + str(runtime / 'Frameworks'), '-DQT_LIBRARY_DIR=' + str(qt / 'lib'))
    run('cmake', '--build', build, '-j', '6')
    testenv = dict(os.environ, DYLD_LIBRARY_PATH=str(runtime / 'Frameworks'))
    run('ctest', '--test-dir', build, '--output-on-failure', env=testenv)
    if destination.exists(): shutil.rmtree(destination)
    shutil.copytree(runtime, destination, symlinks=True)
    (destination / 'MacOS').mkdir()
    (destination / 'Resources/licenses').mkdir(parents=True)
    shutil.copy2(build / 'MacSteamToolConnect', destination / 'MacOS')
    shutil.copy2(build / 'connecttool-tun-daemon', destination / 'Resources')
    shutil.copy2(ROOT / 'Native/ConnectTool/Resources/com.connecttool.tunhelper.plist', destination / 'Resources')
    (destination / 'MacOS/qt.conf').write_text('[Paths]\nPrefix=..\nPlugins=PlugIns\n')
    (destination / 'MacOS/steam_appid.txt').write_text('480\n')
    for license in ['ConnectTool-MIT.txt', 'Qt-LGPL-3.0.txt', 'Qt-GPL-3.0.txt', 'Boost-1.0.txt', 'CuteSound-NOTICE.txt']:
        shutil.copy2(ROOT / 'Licenses' / license, destination / 'Resources/licenses')
    shutil.copy2(ROOT / 'Native/ConnectTool/PROVENANCE.md', destination / 'Resources')
    shutil.copy2(MANIFEST, destination / 'Resources/release.json')
    for path in machos(destination): run('codesign', '--force', '--sign', '-', path, stdout=subprocess.DEVNULL)
    for path in (destination / 'Frameworks').glob('*.framework'):
        run('codesign', '--force', '--sign', '-', path, stdout=subprocess.DEVNULL)
    verify(destination)
    print('Bundled source-built ConnectTool ' + release['version'] + ' service (no GUI)')


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--verify': verify(Path(sys.argv[2]).resolve())
    elif len(sys.argv) == 2: bundle(Path(sys.argv[1]).resolve())
    else: sys.exit('Usage: bundle_connecttool.py [--verify] <ConnectTool runtime directory>')
