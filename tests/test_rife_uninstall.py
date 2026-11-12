"""Exercise uninstall against disposable roots only, without GPU dependencies."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'rife'

class UninstallTests(unittest.TestCase):
    def run_uninstall(self, root, config, confirmed=True):
        args = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                str(SOURCE / 'runtime.ps1'), '-Action', 'Uninstall', '-Root', str(root), '-ConfigDir', str(config)]
        if confirmed: args.append('-Confirmed')
        return subprocess.run(args, capture_output=True, timeout=20)

    def fixture(self, base):
        root = base / '补帧组件'; config = base / 'player-config'
        config.mkdir(); (config / 'mpv.conf').write_text('keep-me')
        for name in ['runtime/old', 'runtime/current', 'cache/key', 'downloads', 'staging', 'jobs', 'logs']:
            folder = root / name; folder.mkdir(parents=True)
            (folder / '[test].bin').write_bytes(b'test')
        (root / 'active.json').write_text(json.dumps({'installed': True}))
        return root, config

    def test_removes_components_and_old_versions_preserves_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, config = self.fixture(Path(tmp))
            result = self.run_uninstall(root, config)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(root.exists())
            self.assertEqual((config / 'mpv.conf').read_text(), 'keep-me')

    def test_requires_confirmation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, config = self.fixture(Path(tmp))
            self.assertNotEqual(self.run_uninstall(root, config, False).returncode, 0)
            self.assertTrue((root / 'active.json').exists())

    def test_refuses_unknown_files_before_deleting_components(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, config = self.fixture(Path(tmp))
            (root / 'personal.txt').write_text('keep')
            self.assertNotEqual(self.run_uninstall(root, config).returncode, 0)
            self.assertEqual((root / 'personal.txt').read_text(), 'keep')
            self.assertTrue((root / 'runtime/current/[test].bin').exists())

    def test_refuses_config_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, config = self.fixture(Path(tmp))
            self.assertNotEqual(self.run_uninstall(root, root).returncode, 0)
            self.assertTrue((root / 'runtime/current/[test].bin').exists())

    def test_busy_install_lock_preserves_everything(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp); root, config = self.fixture(base)
            harness = base / 'busy.ps1'
            harness.write_text('''param($Root,$Runtime,$Config)
$lock=[IO.File]::Open((Join-Path $Root 'install.lock'),'OpenOrCreate','ReadWrite','None')
try{& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Runtime -Action Uninstall -Confirmed -Root $Root -ConfigDir $Config;exit $LASTEXITCODE}finally{$lock.Dispose()}
''', encoding='utf-8-sig')
            result = subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                                     str(harness), str(root), str(SOURCE / 'runtime.ps1'), str(config)], capture_output=True, timeout=20)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((root / 'runtime/current/[test].bin').exists())

    def test_loaded_runtime_library_blocks_uninstall(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp); root, config = self.fixture(base)
            library = root / 'runtime/current/version.dll'
            shutil.copyfile(Path(os.environ['WINDIR']) / 'System32/version.dll', library)
            ready = base / 'ready'
            code = 'import ctypes,sys,time;from pathlib import Path;lib=ctypes.WinDLL(sys.argv[1]);Path(sys.argv[2]).touch();time.sleep(30)'
            child = subprocess.Popen([sys.executable, '-B', '-c', code, str(library), str(ready)])
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and child.poll() is None and time.monotonic() < deadline:
                    time.sleep(.05)
                self.assertTrue(ready.exists(), 'Fixture failed to load DLL')
                result = self.run_uninstall(root, config)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue((root / 'active.json').exists())
                self.assertTrue(library.exists())
            finally:
                child.terminate(); child.wait(5)

if __name__ == '__main__': unittest.main()
