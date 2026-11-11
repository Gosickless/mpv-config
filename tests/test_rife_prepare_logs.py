"""Startup cleanup touches only inactive preparation logs."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

REPO=Path(__file__).resolve().parents[1]
HELPER=REPO/'rife/runtime.ps1'
MPV=os.environ.get('RIFE_TEST_MPV')

class PrepareLogTests(unittest.TestCase):
    def cleanup(self,root,busy=False):
        args=['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass']
        if busy:
            script=root.parent/'hold.ps1'
            script.write_text('''param($Helper,$Root)
$ast=[System.Management.Automation.Language.Parser]::ParseFile($Helper,[ref]$null,[ref]$null)
foreach($function in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)){
 . ([scriptblock]::Create($function.Extent.Text))
}
$lease=Open-PrepareLogLease
try{& $Helper -Action CleanLogs -Root $Root}finally{$lease.Dispose()}
''',encoding='utf-8-sig')
            args+=['-File',str(script),str(HELPER),str(root)]
        else:args+=['-File',str(HELPER),'-Action','CleanLogs','-Root',str(root)]
        result=subprocess.run(args,capture_output=True,timeout=15)
        self.assertEqual(result.returncode,0,result.stderr.decode(errors='replace'))

    def fixture(self,base):
        root=base/'组件 日志';root.mkdir()
        logs=[root/('prepare-'+'a'*32+'.jsonl'),root/('prepare-'+'a'*32+'.jsonl.stderr'),
              root/('prepare-'+'b'*32+'.jsonl.stderr')]
        for path in logs:path.write_bytes(b'completed')
        return root,logs

    def test_only_exact_top_level_log_names_are_removed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root,logs=self.fixture(Path(tmp))
            protected=[root/'active.json',root/'request-123-2.json',root/'prepare-not-a-guid.jsonl',
                       root/('prepare-'+'c'*32+'.jsonl.backup'),root/'cache'/'engine.bin',
                       root/'downloads'/'package.part',root/'jobs'/('prepare-'+'d'*32+'.jsonl')]
            for path in protected:
                path.parent.mkdir(exist_ok=True);path.write_bytes(b'keep')
            self.cleanup(root)
            self.assertTrue(all(not path.exists() for path in logs))
            self.assertTrue(all(path.read_bytes()==b'keep' for path in protected))

    def test_active_preparation_lease_defers_cleanup(self):
        with tempfile.TemporaryDirectory() as tmp:
            root,logs=self.fixture(Path(tmp))
            self.cleanup(root,busy=True)
            self.assertTrue(all(path.exists() for path in logs))
            self.cleanup(root)
            self.assertTrue(all(not path.exists() for path in logs))

    def test_missing_root_is_not_created(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)/'absent'
            self.cleanup(root)
            self.assertFalse(root.exists())

    @unittest.skipUnless(MPV,'Set RIFE_TEST_MPV for the real startup test')
    def test_player_startup_cleans_logs_without_enabling_interpolation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root,logs=self.fixture(Path(tmp))
            process=subprocess.Popen([MPV,'--config-dir='+str(REPO),'--load-scripts=no',
                '--script='+str(REPO/'scripts/rife.lua'),'--script-opts=rife-runtime_root='+str(root),
                '--idle=yes','--vo=null','--ao=null','--save-position-on-quit=no','--save-watch-history=no'],
                stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            try:
                deadline=time.monotonic()+10
                while any(path.exists() for path in logs) and time.monotonic()<deadline:time.sleep(.1)
                self.assertTrue(all(not path.exists() for path in logs),'Startup did not clear preparation logs')
                self.assertFalse((root/'active.json').exists(),'Startup initialized the runtime')
            finally:
                process.terminate();process.wait(timeout=10)

if __name__=='__main__':unittest.main()
