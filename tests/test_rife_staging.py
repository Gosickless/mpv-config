"""Test real installer failure cleanup without downloading GPU dependencies."""
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

SOURCE = Path(__file__).resolve().parents[1] / 'rife' / 'runtime.ps1'

class StagingTests(unittest.TestCase):
    def cleanup(self, root, target):
        harness = root.parent / 'cleanup.ps1'
        harness.write_text('''param($Source,$Root,$Target)
$ErrorActionPreference='Stop'
$ast=[System.Management.Automation.Language.Parser]::ParseFile($Source,[ref]$null,[ref]$null)
foreach($function in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)){
 . ([scriptblock]::Create($function.Extent.Text))
}
Clear-Staging $Target
''', encoding='utf-8-sig')
        return subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                               str(harness), str(SOURCE), str(root), str(target)], capture_output=True, timeout=15)

    def test_cleans_only_the_owned_staging_job(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'root'
            job = root / 'staging' / ('a' * 32)
            (job / 'nested').mkdir(parents=True)
            (job / 'nested' / '[test].bin').write_bytes(b'temporary')
            download = root / 'downloads' / 'package.part'
            download.parent.mkdir(); download.write_bytes(b'resume-me')
            result = self.cleanup(root, job)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(job.exists())
            self.assertEqual(download.read_bytes(), b'resume-me')

    def test_refuses_paths_outside_staging_or_without_job_id(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'root'
            for target in [Path(tmp) / 'outside', root / 'staging' / 'user-folder']:
                target.mkdir(parents=True)
                protected = target / 'keep.txt'; protected.write_bytes(b'keep')
                self.assertNotEqual(self.cleanup(root, target).returncode, 0)
                self.assertEqual(protected.read_bytes(), b'keep')

    def check_failed_install(self, cancelled):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp); root = base / 'root'; installer = base / 'installer'
            installer.mkdir(); shutil.copyfile(SOURCE, installer / 'runtime.ps1')
            bad = b'not a zip archive'
            if cancelled:
                archive = io.BytesIO()
                with zipfile.ZipFile(archive, 'w') as package: package.writestr('test.txt', 'test')
                bad = archive.getvalue()
            downloads = root / 'downloads'; downloads.mkdir(parents=True)
            (downloads / 'python.zip').write_bytes(bad)
            original = b'{"installed":true,"root":"previous-runtime"}'
            (root / 'active.json').write_bytes(original)
            if cancelled: (root / 'cancel').touch()
            (installer / 'runtime-lock.json').write_text(json.dumps({'id':'test', 'assets':[
                {'name':'python.zip','url':'https://example.invalid/not-used',
                 'size':len(bad),'sha256':hashlib.sha256(bad).hexdigest()}]}))
            result = subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',
                                     str(installer / 'runtime.ps1'),'-Action','Install','-Confirmed','-Root',str(root),'-CancelFile',str(root/'cancel')],
                                    capture_output=True, timeout=20)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((root / 'active.json').read_bytes(), original)
            self.assertEqual((downloads / 'python.zip').read_bytes(), bad)
            self.assertTrue((root / 'staging').is_dir(), 'Test never reached extraction')
            self.assertEqual(list((root / 'staging').iterdir()), [])
            self.assertEqual(json.loads((root / 'progress.json').read_text(encoding='utf-8-sig'))['phase'], 'cancelled' if cancelled else 'error')

    def test_extraction_failure_keeps_old_active_and_downloads(self):
        self.check_failed_install(False)

    def test_cancellation_keeps_old_active_and_downloads(self):
        self.check_failed_install(True)

if __name__ == '__main__': unittest.main()
