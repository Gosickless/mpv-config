"""Startup cleanup touches only inactive preparation logs."""
import os
import json
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
        directory=root/'logs';directory.mkdir()
        logs=[directory/('prepare-'+'a'*32+'.jsonl'),directory/('prepare-'+'a'*32+'.jsonl.stderr'),
              directory/('prepare-'+'b'*32+'.jsonl.stderr'),root/('prepare-'+'e'*32+'.jsonl')]
        for path in logs:path.write_bytes(b'completed')
        return root,logs

    def test_only_exact_top_level_log_names_are_removed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root,logs=self.fixture(Path(tmp))
            protected=[root/'active.json',root/'request-123-2.json',root/'prepare-not-a-guid.jsonl',
                       root/('prepare-'+'c'*32+'.jsonl.backup'),root/'cache'/'engine.bin',
                       root/'downloads'/'package.part',root/'jobs'/('prepare-'+'d'*32+'.jsonl'),
                       root/'logs'/'keep.txt',root/'logs'/'nested'/('prepare-'+'f'*32+'.jsonl')]
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

    def test_prepare_writes_output_inside_logs(self):
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp);root=base/'root';runtime=root/'runtime'/'fixture'
            runtime.mkdir(parents=True)
            (root/'active.json').write_text(json.dumps({'root':str(runtime)}))
            (runtime/'runtime.json').write_text(json.dumps({'vsscript':'vsscript.dll'}))
            request=root/'request-1-1.json';request.write_text('{}')
            builder=base/'build.ps1'
            builder.write_text('''param($Target)
Add-Type -OutputAssembly $Target -OutputType ConsoleApplication -TypeDefinition @'
public class PrepareFixture {
 public static void Main(string[] args) {
  System.Console.WriteLine("prepared");
  System.Console.Error.WriteLine("diagnostic");
 }
}
'@
''',encoding='utf-8-sig')
            result=subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(builder),str(runtime/'python.exe')],capture_output=True,timeout=20)
            self.assertEqual(result.returncode,0,result.stderr)
            result=subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(HELPER),
                '-Action','Prepare','-Root',str(root),'-Request',str(request)],capture_output=True,timeout=20)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(list(root.glob('prepare-*')),[])
            logs=list((root/'logs').glob('*.jsonl'))
            self.assertEqual(len(logs),1)
            self.assertIn('prepared',logs[0].read_text())
            self.assertIn('diagnostic',Path(str(logs[0])+'.stderr').read_text())

    @unittest.skipUnless(MPV,'Set RIFE_TEST_MPV for the real startup test')
    def test_player_startup_cleans_logs_without_enabling_interpolation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root,logs=self.fixture(Path(tmp))
            logs.pop().unlink() # Ensure startup discovers logs/ without any legacy root log.
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
