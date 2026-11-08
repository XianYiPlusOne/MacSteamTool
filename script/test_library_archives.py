#!/usr/bin/env python3
"""Real-format fixtures through the async helper, preview, transaction and rollback."""
from pathlib import Path
import hashlib, io, json, os, stat, struct, subprocess, sys, tarfile, tempfile, zlib
root=Path(__file__).resolve().parents[1]
engine=Path(sys.argv[1]) if len(sys.argv)>1 else root/'outputs/Fluent Steam Mac.app/Contents/Resources/Helpers/SteamEngine/FluentSteamEngine'
inspect=root/'.build/debug/FluentInspect'
def header(kind,flags,body):
    data=struct.pack('<BHH',kind,flags,len(body)+7)+body
    return struct.pack('<H',zlib.crc32(data)&0xffff)+data
# Minimal stored RAR 4 fixture, with independent per-file/header CRCs.
def rar(files):
    out=b'Rar!\x1a\x07\x00'+header(0x73,0,b'\x00'*6)
    for name,data in files:
        n=name.encode();body=struct.pack('<IIBIIBBHI',len(data),len(data),3,zlib.crc32(data),0,20,0x30,len(n),0o100644)+n
        out+=header(0x74,0x8000,body)+data
    return out+header(0x7b,0,b'')
def section(kind,data): return struct.pack('<II',kind,len(data))+data
with tempfile.TemporaryDirectory(prefix='FluentLibraryArchives-') as directory:
    temp=Path(directory); source=temp/'source'; source.mkdir()
    manifest=section(0x71f617d0,b'')+section(0x1f4812be,b'\x08\x65\x10\x7b')+section(0x1b81b817,b'')+struct.pack('<I',0x32c415ab)
    files={'nested/100.lua':b'-- Archive integration fixture\naddappid(100)\n','nested/101_123.manifest':manifest,'nested/UserGameStatsSchema_100.bin':b'\x00fixture-schema\x00','a-readme.txt':b'Ignored before solid selected entries'}
    for name,data in files.items():
        p=source/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
    expected=[dict(name=Path(n).name,sha256=hashlib.sha256(d).hexdigest()) for n,d in sorted(files.items()) if Path(n).suffix in ['.lua','.manifest','.bin']]
    expected.sort(key=lambda x:x['name'])
    def run(archive,ok=True,exercise=True):
        p=subprocess.run([str(inspect),'--exercise-library-import' if exercise else '--verify-library-import',str(engine),str(archive)],capture_output=True,text=True,timeout=45)
        assert (p.returncode==0)==ok,(archive.name,p.stderr,p.stdout)
        if ok: assert json.loads(p.stdout)==expected,(archive.name,p.stdout)
    for format,ext in [('ustar','tar'),('7zip','7z')]:
        archive=temp/('valid.'+ext)
        subprocess.run(['/usr/bin/tar','--format='+format,'-cf',str(archive),*sorted(files)],cwd=source,check=True)
        run(archive)
    archive=temp/'valid.rar';archive.write_bytes(rar(list(files.items())))
    listing=subprocess.run(['/usr/bin/tar','-tf',str(archive)],capture_output=True,text=True,check=True).stdout
    assert all(n in listing for n in files);run(archive)
    corrupt=temp/'corrupt.rar';corrupt.write_bytes(archive.read_bytes().replace(b'Archive integration',b'Changed integration'));run(corrupt,False)
    traversal=temp/'traversal.rar';traversal.write_bytes(rar([('../100.lua',b'addappid(100)')]));run(traversal,False)
    for name,link in [('symlink',tarfile.SYMTYPE),('hardlink',tarfile.LNKTYPE)]:
        path=temp/(name+'.tar')
        with tarfile.open(path,'w') as t:
            e=tarfile.TarInfo('escape.lua');e.type=link;e.linkname='../outside.lua';t.addfile(e)
        run(path,False)
    for name,entries in [('traversal',[('../100.lua',b'bad')]),('alias',[('100.lua',b'one'),('100.LUA',b'two')]),('basename-conflict',[('a/100.lua',b'one'),('b/100.lua',b'two')])]:
        path=temp/(name+'.tar')
        with tarfile.open(path,'w') as t:
            for filename,data in entries:
                e=tarfile.TarInfo(filename);e.size=len(data);t.addfile(e,io.BytesIO(data))
        run(path,False)
    empty=temp/'empty.7z'
    subprocess.run(['/usr/bin/tar','--format=7zip','-cf',str(empty),'a-readme.txt'],cwd=source,check=True);run(empty,False)
    print('PASS: TAR, solid 7z and independently listed RAR4 -> Lua/Manifest/Bin -> preview -> isolated library transaction -> verified rollback; nonselected entries, RAR CRC damage, traversal, symlinks, hardlinks, case aliases, flattened name conflicts and no-importable-files rejection')
