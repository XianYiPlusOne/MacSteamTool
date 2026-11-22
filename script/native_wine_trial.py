#!/usr/bin/env python3
"""Reversible manager-free live trial, retaining native Steam login and game downloads.

Parks all managers, their caches, MacSteamTool's data, compatibility tools and the test
save prefix. MacSteamTool must initialize its own components and fetch Wine afresh.
Original configuration and saves are restored by the journal, never overwritten.
"""
import fresh_machine_trial as trial
import json, os, shutil, sys, time, uuid, subprocess
from pathlib import Path
trial.EVIDENCE = trial.ROOT/'work/native-wine-e2e'
trial.STATE = trial.EVIDENCE/'state.json'

def stage():
    if trial.STATE.exists() and json.loads(trial.STATE.read_text())['phase']!='restored':
        raise RuntimeError('Restore the previous trial first')
    trial.idle();trial.EVIDENCE.mkdir(mode=0o700,parents=True,exist_ok=True)
    trial.EVIDENCE.chmod(0o700)
    vault=trial.SUPPORT/('FluentNativeWineTrial-'+uuid.uuid4().hex);vault.mkdir(mode=0o700)
    assets=trial.EVIDENCE/'assets';assets.mkdir(mode=0o700,exist_ok=True)
    lua=trial.app_data()/f'Lua/{trial.APP_ID}.lua'
    shutil.copy2(lua,assets/lua.name);(assets/lua.name).chmod(0o600)
    paths=[Path('/Applications')/n for n in ['Steam.app','macSteam Config.app','NotProton.app','CrossOver.app']]
    paths += [trial.SUPPORT/n for n in ['macsteam','notproton','FluentSteamMac','MacSteamTool','CrossOver']]
    paths += [trial.SUPPORT/'Steam/compatibilitytools.d',trial.SUPPORT/f'Steam/steamapps/compatdata/{trial.APP_ID}']
    # Steam's existing login and installed games stay in place; ordinary game
    # preferences are snapshotted because Steam writes them during the trial.
    saved=[]
    for n in ['config/config.vdf',f'steamapps/appmanifest_{trial.APP_ID}.acf']:
        src=trial.SUPPORT/'Steam'/n
        if src.is_file():
            dest=vault/('pref-'+str(len(saved)));shutil.copy2(src,dest)
            saved.append(dict(source=str(src),stored=str(dest),sha=trial.sha(src)))
    entries=[dict(source=str(p),stored=str(vault/str(i)),moved=False,existed=p.exists()) for i,p in enumerate(paths)]
    state=dict(phase='staged',created=time.time(),vault=str(vault),assets=str(assets),entries=entries,
               protected=trial.protected_files(),preferences=saved)
    trial.save(state);print('Staged reversible native Steam + blank MacSteamTool/Wine trial. Original login retained in place.')

def seed_game():
    state=json.loads(trial.STATE.read_text())
    if state['phase']!='parked':raise RuntimeError('Requires parked trial')
    rows=subprocess.check_output(['/bin/ps','-axo','comm'],text=True)
    if any(row.endswith('/steam_osx') for row in rows.splitlines()):raise RuntimeError('Quit Steam first')
    previous=json.loads((trial.ROOT/'work/fresh-machine-e2e/state.json').read_text())
    if previous['phase']!='restored':raise RuntimeError('Previous game trial is not restored')
    assets=Path(previous['assets'])
    pairs=[(assets/'ForgeTax',trial.SUPPORT/'Steam/steamapps/common/ForgeTax'),
           (assets/f'appmanifest_{trial.APP_ID}.acf',trial.SUPPORT/f'Steam/steamapps/appmanifest_{trial.APP_ID}.acf')]
    for source,target in pairs:
        if target.exists():raise RuntimeError('Refusing to overwrite game content')
        state.setdefault('extra_generated',[]).append(str(target));trial.save(state)
        target.parent.mkdir(parents=True,exist_ok=True)
        subprocess.run(['/bin/cp','-cRp',str(source),str(target)],check=True)
    print('Seeded only the preserved game files and manifest. No prefix or manager data reused.')

def restore():
    trial.idle();state=json.loads(trial.STATE.read_text())
    if state['phase']=='restored': print('Already restored');return
    Path(state['vault']).chmod(0o700)
    for i,entry in enumerate(state['entries']):
        path=Path(entry['source'])
        if not entry['existed'] and path.exists():
            os.rename(path,trial.EVIDENCE/('generated-new-'+str(i)))
    for i,name in enumerate(state.get('extra_generated',[])):
        path=Path(name)
        if path.exists():os.rename(path,trial.EVIDENCE/('retained-game-'+str(i)))
    for item in state['preferences']:
        # Preserve the trial's ordinary Steam config before restoring the original.
        dest=trial.EVIDENCE/(Path(item['stored']).name+'-trial')
        if Path(item['source']).exists():shutil.copy2(item['source'],dest);dest.chmod(0o600)
        shutil.copy2(item['stored'],item['source'])
    trial.restore()

if __name__=='__main__':
    action=sys.argv[1] if len(sys.argv)==2 else ''
    if action=='stage':stage()
    elif action=='park':trial.park()
    elif action=='restore':restore()
    elif action=='seed-game':seed_game()
    elif action=='status':
        state=json.loads(trial.STATE.read_text());print(json.dumps({k:state.get(k) for k in ['phase','created','restored','generated']},indent=2))
    else:raise SystemExit('Usage: native_wine_trial.py stage|park|seed-game|restore|status')
