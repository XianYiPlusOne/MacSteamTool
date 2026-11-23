"""Steam-loaded libraries must match Steam, independently of the app's CPU."""
STEAM_ARCHITECTURES = ('arm64', 'x86_64')
STEAM_LIBRARY_NAMES = frozenset({
    'macsteam.dylib', 'notproton.dylib', 'overlay-shim.dylib',
    'cloud_redirect.dylib', 'manifest.dylib', 'fluent_manifest.dylib',
})


def preserve_steam_architectures(path):
    return path.name in STEAM_LIBRARY_NAMES
