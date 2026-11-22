#!/usr/bin/env python3
"""Exercise the native archive reader on isolated archives, including malformed inputs."""
from pathlib import Path
import json, os, stat, struct, subprocess, sys, tempfile, zipfile

root=Path(__file__).resolve().parents[1]
inspect=Path(sys.argv[1]) if len(sys.argv)>1 else root/'.build/debug/MacSteamToolInspect'
with tempfile.TemporaryDirectory(prefix='FluentPatchTests-') as folder:
    temp=Path(folder)
    def extract(archive,success=True,password=''):
        dest=temp/('extract-'+str(len(list(temp.iterdir()))))
        completed=subprocess.run([str(inspect),'--extract-archive',str(archive),str(dest)],
                                 input=password.encode(),timeout=30,capture_output=True)
        assert (completed.returncode==0)==success,(archive.name,completed.stderr)
        assert dest.exists()==success
        assert not list(temp.glob('.archive-*'))
        return dest
    valid=temp/'valid.zip'
    with zipfile.ZipFile(valid,'w',zipfile.ZIP_DEFLATED) as z:
        z.writestr('folder/test.dll',b'fixture\x00binary'*100)
        z.writestr('empty.txt',b'')
    dest=extract(valid); assert (dest/'folder/test.dll').read_bytes()==b'fixture\x00binary'*100
    for name,paths in [('traversal',['../outside.dll']),('absolute',['/outside.dll']),('windows',['C:\\outside.dll']),('alias',['A.dll','a.dll']),('trailing',['file.dll.'])]:
        archive=temp/(name+'.zip')
        with zipfile.ZipFile(archive,'w') as z:
            for path in paths: z.writestr(path,b'test')
        extract(archive,False)
    link=temp/'symlink.zip'
    with zipfile.ZipFile(link,'w') as z:
        item=zipfile.ZipInfo('escape'); item.create_system=3; item.external_attr=(stat.S_IFLNK|0o777)<<16
        z.writestr(item,'../../outside')
    extract(link,False)
    damaged=temp/'crc.zip'
    with zipfile.ZipFile(damaged,'w',zipfile.ZIP_STORED) as z: z.writestr('file.dll',b'UNIQUE_CRC_PAYLOAD')
    data=damaged.read_bytes().replace(b'UNIQUE_CRC_PAYLOAD',b'CHANGED_CRC_BYTES!'); damaged.write_bytes(data)
    extract(damaged,False)
    plain=temp/'password.txt'; plain.write_text('encrypted fixture')
    encrypted=temp/'encrypted.zip'
    subprocess.run(['/usr/bin/zip','-q','-P','fixture-password',str(encrypted),plain.name],cwd=temp,check=True)
    extract(encrypted,False,'wrong'); dest=extract(encrypted,True,'fixture-password')
    assert (dest/'password.txt').read_text()=='encrypted fixture'
    seven=temp/'fixture.7z'
    subprocess.run(['/usr/bin/tar','--format=7zip','-cf',str(seven),plain.name],cwd=temp,check=True)
    dest=extract(seven); assert (dest/'password.txt').read_text()=='encrypted fixture'
    print('PASS: native archive extraction, password-protected ZIP, 7z, unsafe names, links, CRC and failure cleanup')
