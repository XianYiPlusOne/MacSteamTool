#!/usr/bin/env python3
"""Swift orchestration + real native WebDAV/S3/R2 against loopback-only fixtures."""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, unquote, quote, parse_qs
from xml.sax.saxutils import escape
import base64,hashlib,hmac,json,os,re,subprocess,tempfile,threading

ROOT=Path(__file__).resolve().parents[1]
INSPECT=ROOT/'.build/debug/FluentInspect';CLI=ROOT/'work/cloud-build/FluentCloudCLI'
USER,PASSWORD,BEARER='fixture-user','fixture-password','fixture-bearer'
ACCESS,SECRET='fixture-access','fixture-secret'
# Reuse the exact, already-tested protocol implementation without running its scenarios.
text=(ROOT/'script/test_cloud_online.py').read_text()
exec(compile(text[text.index('class State:'):text.index('\ndef client(')],'cloud-protocol-fixture','exec'),globals())
class DeletionHandler(Handler):
    def object_request(self,path,body,require_parent=False):
        state=self.server.state
        if self.command=='GET' and state.mode=='read-denied':return self.reply(403)
        if self.command=='DELETE':
            state.delete_calls+=1
            if state.mode=='fail-second-delete' and state.delete_calls==2:return self.reply(403)
            if state.mode=='no-op-delete':return self.reply(204)
        return super().object_request(path,body,require_parent)
    def s3(self,path,parsed,body):
        if self.server.state.mode=='partial-list' and 'list-type' in parse_qs(parsed.query):
            return self.reply(200,'<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>')
        return super().s3(path,parsed,body)

def run(root,phase,ok=True):
    p=subprocess.run([str(INSPECT),'--exercise-cloud-delete',str(root),str(CLI),phase],capture_output=True,text=True,timeout=100)
    assert (p.returncode==0)==ok,(phase,p.returncode,p.stdout,p.stderr[-3000:])
    return p

def scenario(parent,provider,case):
    root=parent/(provider+'-'+case);root.mkdir();(root/'.fluent-cloud-delete-fixture').touch()
    state=State('webdav' if provider=='webdav' else 's3');state.delete_calls=0
    server=ThreadingHTTPServer(('127.0.0.1',0),DeletionHandler);server.state=state
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    endpoint=f'http://127.0.0.1:{server.server_port}';base='/dav/CloudRedirect/' if provider=='webdav' else '/bucket/CloudRedirect/'
    payload={'12345/900001/blobs/中文 save.bin':bytes(range(256)),'12345/900001/blobs/empty.bin':b'','12345/900001/manifest.json':b'{"synthetic":true}', '12345/900002/blobs/sentinel':b'other-game','54321/900001/blobs/sentinel':b'other-account','12345/0/stats.json':b'account-statistics-keep'}
    for relative,data in payload.items():
        path=base+relative;state.files[path]=data
        parts=path.strip('/').split('/')[:-1]
        for n in range(1,len(parts)+1):state.dirs.add('/'+'/'.join(parts[:n])+'/')
    cfg=root/'Data/CloudRedirect';cfg.mkdir(parents=True)
    fields={'url':endpoint+'/dav','username':USER,'password':PASSWORD,'auth':'basic','timeout_sec':2,'allow_insecure_http':True,'key_prefix':''}
    if provider!='webdav':fields={'endpoint':endpoint,'region':'us-east-1','bucket':'bucket','access_key_id':ACCESS,'secret_access_key':SECRET,'account_id':'a'*32,'timeout_sec':2,'allow_insecure_http':True,'sign_payload':True,'key_prefix':'CloudRedirect'}
    credential=cfg/(provider+'_credentials.json');credential.write_text(json.dumps(fields));credential.chmod(0o600)
    config=cfg/'config.json';config.write_text(json.dumps({'enabled':False,'provider':provider,'token_paths':{provider:str(credential)}}))
    steam=root/'Library/Application Support/Steam'
    local=[cfg/'storage/12345/900001',cfg/'blobs/12345/900001',steam/'userdata/12345/900001']
    for path in local:
        path.mkdir(parents=True);(path/'progress.bin').write_bytes(b'local-synthetic-save\x00\xff');(path/'empty').mkdir()
    foreign=steam/'userdata/54321/900001/sentinel';foreign.parent.mkdir(parents=True);foreign.write_bytes(b'keep-local')
    baseline=dict(state.files);config_bytes=config.read_bytes();credential_bytes=credential.read_bytes()
    try:
        if case in ('list-denied','partial-list'):
            state.mode=case;run(root,'preview',False);assert state.delete_calls==0 and state.files==baseline
            assert not (root/'Data/CloudDeleteBackups').exists();print('PASS:',provider,case,'fails closed before backup/deletion');return
        run(root,'preview');preview=json.loads((root/'preview.json').read_text());backup=Path(preview['directory'].removeprefix('file://')) if isinstance(preview['directory'],str) else None
        # URL encoding is intentionally decoded only for fixture bookkeeping.
        backup=Path(unquote(str(backup)))
        assert len(preview['local'])==3 and len(preview['remote'])==3,(preview, state.requests)
        if case=='local-change-before-backup':
            (local[0]/'progress.bin').write_bytes(b'changed');run(root,'backup',False)
            assert state.delete_calls==0 and state.files==baseline;print('PASS:',provider,case,'no source deleted');return
        if case=='read-denied':
            state.mode=case;run(root,'backup',False)
            assert state.delete_calls==0 and state.files==baseline and (backup/'.INCOMPLETE').exists()
            print('PASS:',provider,case,'partial backup retained, zero deletes');return
        run(root,'backup')
        assert state.files==baseline and all(p.exists() for p in local)
        ready=json.loads((root/'ready.json').read_text());receipt=json.loads((backup/'remote/receipt.json').read_text())
        assert len(receipt['files'])==3
        for i,entry in enumerate(receipt['files']):
            data=(backup/f'remote/objects/{i}.bin').read_bytes();assert data==baseline[base+entry['path']]
            assert hashlib.sha256(data).hexdigest()==entry['sha256']
        assert not (backup/'.INCOMPLETE').exists()
        if case=='corrupt-backup':(backup/'remote/objects/0.bin').write_bytes(b'bad')
        if case=='remote-change':
            path=base+'12345/900001/manifest.json';state.files[path]=state.files[path].replace(b'true',b'null') # same length, fixed remote mtime
        if case=='config-change':config.write_text(config.read_text()+' ')
        if case=='new-remote-object':state.files[base+'12345/900001/new.bin']=b'new'
        if case in ('fail-second-delete','no-op-delete'):state.mode=case
        should_succeed=case=='success'
        before_delete=dict(state.files);run(root,'delete',should_succeed)
        if should_succeed:
            assert not any(p.startswith(base+'12345/900001/') for p in state.files)
            assert all(not p.exists() for p in local)
            assert json.loads((backup/'deletion-status.json').read_text())['state']=='complete'
        else:
            assert all(p.exists() for p in local),'remote failure removed a local cache'
            if case not in ('fail-second-delete','no-op-delete'):assert state.delete_calls==0 and state.files==before_delete
            if case=='fail-second-delete':
                assert state.delete_calls==2 and len(before_delete)-len(state.files)==1
                assert json.loads((backup/'deletion-status.json').read_text())['state']=='failed-or-partial'
            if case=='no-op-delete':assert state.files==before_delete
            assert (backup/'backup.json').exists()
        for relative in ['12345/900002/blobs/sentinel','54321/900001/blobs/sentinel','12345/0/stats.json']:assert state.files[base+relative]==payload[relative]
        assert foreign.read_bytes()==b'keep-local'
        if case!='config-change':assert config.read_bytes()==config_bytes
        assert credential.read_bytes()==credential_bytes
        print('PASS:',provider,case,'scope isolated; all backup bytes checked; expected deletion/failure and cache retention verified')
    finally:
        server.shutdown();server.server_close();thread.join(timeout=2)

with tempfile.TemporaryDirectory(prefix='cloud-delete-http-',dir=ROOT/'work') as folder:
    root=Path(folder)
    for provider in ['webdav','s3']:
        for case in ['success','list-denied','read-denied','corrupt-backup','remote-change','config-change','new-remote-object','fail-second-delete','no-op-delete','local-change-before-backup']:
            scenario(root,provider,case)
    scenario(root,'s3','partial-list');scenario(root,'r2','success')
print('PASS: only loopback HTTP providers, synthetic accounts/apps and temporary local directories were used; real saves and credentials were not accessed.')
