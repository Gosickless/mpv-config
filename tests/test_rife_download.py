"""Exercise the real PowerShell downloader over local HTTP; no upstream downloads."""
import hashlib
import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest

SOURCE=Path(__file__).resolve().parents[1]/'rife/runtime.ps1'
DATA=(bytes(range(256))*16384)  # 4 MiB
REQUESTS=[]
class Server(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        start=int(self.headers.get('Range','bytes=0-').split('=')[1].split('-')[0])
        REQUESTS.append((self.path,start))
        resume=start>0 and self.path!='/ignore-range'
        if not resume:start=0
        self.send_response(206 if resume else 200)
        if resume:self.send_header('Content-Range',f'bytes {start}-{len(DATA)-1}/{len(DATA)}')
        self.send_header('Content-Length',str(len(DATA)-start));self.end_headers()
        try:
            for i in range(start,len(DATA),65536):
                self.wfile.write(DATA[i:i+65536]);self.wfile.flush();time.sleep(.02)
        except (BrokenPipeError,ConnectionResetError,ConnectionAbortedError):pass
    def log_message(self,*args):pass

def wait_for(predicate, seconds=15):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        if predicate():return
        time.sleep(.05)
    raise AssertionError('Timed out')

class DownloadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Server)
        cls.thread=threading.Thread(target=cls.server.serve_forever,daemon=True);cls.thread.start()
    @classmethod
    def tearDownClass(cls):cls.server.shutdown();cls.server.server_close()
    def run_transfer(self,ignore_range=False):
        with tempfile.TemporaryDirectory(prefix='rife-download-test-') as tmp:
            root=Path(tmp);pause=root/'pause';progress=root/'progress.json'
            asset={'name':'sample.bin','url':f'http://127.0.0.1:{self.server.server_port}/'+('ignore-range' if ignore_range else 'range'),
                   'size':len(DATA),'sha256':hashlib.sha256(DATA).hexdigest()}
            (root/'asset.json').write_text(json.dumps(asset))
            harness=root/'test.ps1'
            harness.write_text('''param($Source,$Root)
$ErrorActionPreference='Stop'
$ast=[System.Management.Automation.Language.Parser]::ParseFile($Source,[ref]$null,[ref]$null)
foreach($function in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)){
 . ([scriptblock]::Create($function.Extent.Text))
}
$PauseFile=Join-Path $Root 'pause';$CancelFile=Join-Path $Root 'cancel';$ProgressFile=Join-Path $Root 'progress.json'
$asset=Get-Content (Join-Path $Root 'asset.json') -Raw|ConvertFrom-Json
Download-Checked $asset $Root
''',encoding='utf-8-sig')
            child=subprocess.Popen(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(harness),str(SOURCE),str(root)],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            try:
                partial=root/'sample.bin.part'
                def started():
                    if child.poll() is not None:
                        output,error=child.communicate();raise AssertionError(error.decode(errors='replace'))
                    return partial.exists() and partial.stat().st_size>262144
                wait_for(started)
                pause.write_text('pause')
                def paused():
                    if child.poll() is not None:
                        output,error=child.communicate();raise AssertionError(error.decode(errors='replace')+' progress='+progress.read_text(encoding='utf-8-sig'))
                    try:return json.loads(progress.read_text(encoding='utf-8-sig'))['phase']=='paused'
                    except (OSError,ValueError,KeyError):return False
                wait_for(paused)
                stopped=partial.stat().st_size;time.sleep(.5)
                self.assertEqual(stopped,partial.stat().st_size,'paused download kept writing')
                pause.unlink()
                out,err=child.communicate(timeout=20)
                self.assertEqual(child.returncode,0,err.decode(errors='replace'))
                self.assertEqual(hashlib.sha256((root/'sample.bin').read_bytes()).hexdigest(),asset['sha256'])
                self.assertTrue(any(start>0 and path==('/ignore-range' if ignore_range else '/range') for path,start in REQUESTS))
            finally:
                if child.poll() is None:child.kill()
                child.communicate()
    def test_pause_resume(self):self.run_transfer()
    def test_server_ignores_range_restarts_safely(self):self.run_transfer(True)

if __name__=='__main__':unittest.main()
