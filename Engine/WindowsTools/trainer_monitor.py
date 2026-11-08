"""NotProton trainer helper. Runs inside the game's Wine prefix.
Only starts the explicitly configured trainer, and only sends configured keys
while a matching game process and the trainer are both alive.
"""
import ctypes as c
from ctypes import wintypes as w
import json, os, subprocess, sys, time

k = c.WinDLL('kernel32', use_last_error=True)
u = c.WinDLL('user32', use_last_error=True)
class PROCESSENTRY32W(c.Structure):
    _fields_ = [('dwSize',w.DWORD),('cntUsage',w.DWORD),('th32ProcessID',w.DWORD),('th32DefaultHeapID',c.c_size_t),('th32ModuleID',w.DWORD),('cntThreads',w.DWORD),('th32ParentProcessID',w.DWORD),('pcPriClassBase',w.LONG),('dwFlags',w.DWORD),('szExeFile',w.WCHAR*260)]
k.CreateToolhelp32Snapshot.argtypes=[w.DWORD,w.DWORD]; k.CreateToolhelp32Snapshot.restype=w.HANDLE
k.Process32FirstW.argtypes=[w.HANDLE,c.POINTER(PROCESSENTRY32W)]; k.Process32FirstW.restype=w.BOOL
k.Process32NextW.argtypes=[w.HANDLE,c.POINTER(PROCESSENTRY32W)]; k.Process32NextW.restype=w.BOOL
k.OpenProcess.argtypes=[w.DWORD,w.BOOL,w.DWORD]; k.OpenProcess.restype=w.HANDLE
k.QueryFullProcessImageNameW.argtypes=[w.HANDLE,w.DWORD,w.LPWSTR,c.POINTER(w.DWORD)]; k.QueryFullProcessImageNameW.restype=w.BOOL
k.CloseHandle.argtypes=[w.HANDLE]; k.CloseHandle.restype=w.BOOL

def norm(path): return os.path.normcase(os.path.realpath(path))
def processes():
    snapshot=k.CreateToolhelp32Snapshot(2,0)
    if snapshot==c.c_void_p(-1).value: raise c.WinError(c.get_last_error())
    result={}
    try:
        entry=PROCESSENTRY32W(); entry.dwSize=c.sizeof(entry)
        ok=k.Process32FirstW(snapshot,c.byref(entry))
        while ok:
            handle=k.OpenProcess(0x1000,False,entry.th32ProcessID)
            if handle:
                try:
                    buf=c.create_unicode_buffer(32768); size=w.DWORD(len(buf))
                    if k.QueryFullProcessImageNameW(handle,0,buf,c.byref(size)):
                        result[entry.th32ProcessID]=norm(buf.value)
                finally: k.CloseHandle(handle)
            ok=k.Process32NextW(snapshot,c.byref(entry))
    finally: k.CloseHandle(snapshot)
    return result

class KEYBDINPUT(c.Structure):
    _fields_=[('wVk',w.WORD),('wScan',w.WORD),('dwFlags',w.DWORD),('time',w.DWORD),('dwExtraInfo',c.c_size_t)]
class MOUSEINPUT(c.Structure):
    _fields_=[('dx',w.LONG),('dy',w.LONG),('mouseData',w.DWORD),('dwFlags',w.DWORD),('time',w.DWORD),('dwExtraInfo',c.c_size_t)]
class INPUTUNION(c.Union): _fields_=[('ki',KEYBDINPUT),('mi',MOUSEINPUT)]
class INPUT(c.Structure): _fields_=[('type',w.DWORD),('value',INPUTUNION)]
u.SendInput.argtypes=[w.UINT,c.POINTER(INPUT),c.c_int]; u.SendInput.restype=w.UINT
u.GetForegroundWindow.restype=w.HWND
u.GetWindowThreadProcessId.argtypes=[w.HWND,c.POINTER(w.DWORD)]; u.GetWindowThreadProcessId.restype=w.DWORD

def parse_key(value):
    value=value.split(' - ',1)[0].strip().upper().replace(' ','')
    parts=value.split('+'); keys=[]
    named={'CTRL':0x11,'CONTROL':0x11,'SHIFT':0x10,'ALT':0x12,'INSERT':0x2d,'DELETE':0x2e,'HOME':0x24,'END':0x23,'PAGEUP':0x21,'PAGEDOWN':0x22,'NUMMULTIPLY':0x6a,'NUMADD':0x6b,'NUMSUBTRACT':0x6d,'NUMDECIMAL':0x6e,'NUMDIVIDE':0x6f}
    for part in parts:
        if part in named: keys.append(named[part])
        elif len(part)==1 and part.isascii() and part.isalnum(): keys.append(ord(part))
        elif part.startswith('F') and part[1:].isdigit() and 1<=int(part[1:])<=24: keys.append(0x70+int(part[1:])-1)
        elif part.startswith('NUM') and len(part)==4 and part[3].isdigit(): keys.append(0x60+int(part[3]))
        else: raise ValueError('Unsupported shortcut: '+value)
    if not 1<=len(keys)<=4: raise ValueError('Invalid shortcut')
    return keys

def send_key(keys):
    def event(vk,up):
        item=INPUT(); item.type=1; item.value.ki=KEYBDINPUT(vk,0,2 if up else 0,0,0)
        if u.SendInput(1,c.byref(item),c.sizeof(item))!=1: raise c.WinError(c.get_last_error())
    down=[]
    try:
        for key in keys: event(key,False); down.append(key); time.sleep(.05)
    finally:
        for key in reversed(down): event(key,True); time.sleep(.05)

def log(state,**kw): print(json.dumps(dict(state=state,**kw)),flush=True)
def stopping(cfg):
    if cfg.get('stop') and os.path.exists(cfg['stop']): return True
    if cfg.get('lease'):
        try: return time.time()-os.path.getmtime(cfg['lease'])>20
        except FileNotFoundError: return True
    return False

def foreground_matches(current, game, trainer):
    pid=w.DWORD(); window=u.GetForegroundWindow()
    if window: u.GetWindowThreadProcessId(window,c.byref(pid))
    return current.get(pid.value) in (game,trainer)
def main():
    if len(sys.argv)==2 and sys.argv[1]=='--self-test':
        assert c.sizeof(INPUT)==40
        assert parse_key('Ctrl+Num1')==[0x11,0x61]
        assert parse_key('F12')==[0x7b]
        assert os.getpid() in processes()
        log('self-test-passed',processEnumeration=True,inputSize=40,keysSent=0); return
    if len(sys.argv)!=2: raise ValueError('Expected a private configuration file')
    with open(sys.argv[1],encoding='utf8') as f: cfg=json.load(f)
    game,trainer=norm(cfg['game']),norm(cfg['trainer'])
    if not game.endswith('.exe') or not trainer.endswith('.exe') or not os.path.isfile(game) or not os.path.isfile(trainer): raise ValueError('Executable missing')
    if game==trainer: raise ValueError('Game and trainer must be different executables')
    shortcuts=[parse_key(key) for key in cfg.get('keys',[])]
    delay=max(1,min(int(cfg.get('delay',5)),120))
    last_games=set(); owned=None
    log('watching')
    try:
        while True:
            if stopping(cfg): return
            current=processes(); games={pid for pid,path in current.items() if path==game}
            if games and not last_games:
                existing=any(path==trainer for path in current.values())
                if not existing:
                    owned=subprocess.Popen([trainer],cwd=os.path.dirname(trainer))
                    log('trainer-started',pid=owned.pid)
                    for _ in range(delay*4):
                        time.sleep(.25)
                        if stopping(cfg): return
                    current=processes()
                    if any(path==game for path in current.values()) and any(path==trainer for path in current.values()):
                        sent=0
                        for key in shortcuts:
                            current=processes()
                            if stopping(cfg) or not foreground_matches(current,game,trainer): break
                            send_key(key); sent+=1; time.sleep(.4)
                        log('shortcuts-sent',count=sent,skipped=len(shortcuts)-sent)
                else: log('existing-trainer-kept')
            if not games and last_games and owned and owned.poll() is None:
                owned.terminate(); owned.wait(timeout=5); owned=None; log('trainer-stopped')
            last_games=games; time.sleep(1)
    finally:
        if owned and owned.poll() is None: owned.terminate()
if __name__=='__main__':
    try: main()
    except Exception as exc: log('error',message=str(exc)); sys.exit(1)
