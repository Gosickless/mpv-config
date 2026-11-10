"""Exercise atomic publication, failure and cancellation with real processes."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'rife'
spec = importlib.util.spec_from_file_location('engine_cache', SOURCE / 'engine_cache.py')
cache = importlib.util.module_from_spec(spec); spec.loader.exec_module(cache)
OPTIONS = {'gpu': 'test-gpu-driver', 'width': 1920, 'height': 1080}

def wait_for(predicate):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if predicate(): return
        time.sleep(.05)
    raise AssertionError('Timed out waiting for cache process')

class EngineCacheTests(unittest.TestCase):
    def test_failed_build_is_not_published_and_can_retry(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(RuntimeError, 'inference failed'):
                with cache.engine_directory(tmp, 'runtime', OPTIONS, 425, build=True) as directory:
                    (directory / 'partial.engine').write_bytes(b'partial')
                    raise RuntimeError('inference failed')
            self.assertFalse(list(Path(tmp).rglob('*.engine')))
            self.assertFalse(list(Path(tmp).rglob('complete.json')))
            with cache.engine_directory(tmp, 'runtime', OPTIONS, 425, build=True) as directory:
                (directory / 'test.engine').write_bytes(b'complete')
            with cache.engine_directory(tmp, 'runtime', OPTIONS, 425) as directory:
                self.assertEqual((directory / 'test.engine').read_bytes(), b'complete')

    def test_second_process_waits_for_complete_publication(self):
        with tempfile.TemporaryDirectory() as tmp:
            builder_code = '''import sys,time
from pathlib import Path
sys.path.insert(0,sys.argv[1])
from engine_cache import engine_directory
root=Path(sys.argv[2])
with engine_directory(root,'runtime',{'gpu':'test-gpu-driver','width':1920,'height':1080},425,build=True) as path:
 (path/'test.engine').write_bytes(b'partial')
 (root/'started').touch()
 while not (root/'release').exists():time.sleep(.05)
 (path/'test.engine').write_bytes(b'complete')
'''
            reader_code = '''import sys
sys.path.insert(0,sys.argv[1])
from engine_cache import engine_directory
with engine_directory(sys.argv[2],'runtime',{'gpu':'test-gpu-driver','width':1920,'height':1080},425) as path:
 assert (path/'test.engine').read_bytes()==b'complete'
'''
            builder = subprocess.Popen([sys.executable, '-B', '-c', builder_code, str(SOURCE), tmp])
            reader = None
            try:
                wait_for(lambda: (Path(tmp) / 'started').exists())
                self.assertFalse(list(Path(tmp).rglob('complete.json')))
                reader = subprocess.Popen([sys.executable, '-B', '-c', reader_code, str(SOURCE), tmp])
                time.sleep(.3)
                self.assertIsNone(reader.poll(), 'Reader entered an unfinished engine directory')
                (Path(tmp) / 'release').touch()
                self.assertEqual(builder.wait(10), 0)
                self.assertEqual(reader.wait(10), 0)
            finally:
                if builder.poll() is None: builder.kill()
                builder.wait()
                if reader and reader.poll() is None: reader.kill()
                if reader: reader.wait()

    def test_killed_builder_leaves_no_reusable_partial_engine(self):
        with tempfile.TemporaryDirectory() as tmp:
            code = '''import sys,time
from pathlib import Path
sys.path.insert(0,sys.argv[1])
from engine_cache import engine_directory
root=Path(sys.argv[2])
with engine_directory(root,'runtime',{'gpu':'test-gpu-driver','width':1920,'height':1080},425,build=True) as path:
 (path/'test.engine').write_bytes(b'partial')
 (root/'started').touch()
 time.sleep(30)
'''
            child = subprocess.Popen([sys.executable, '-B', '-c', code, str(SOURCE), tmp])
            try:
                wait_for(lambda: (Path(tmp) / 'started').exists())
                child.kill(); child.wait(10)
                with cache.engine_directory(tmp, 'runtime', OPTIONS, 425, build=True) as directory:
                    self.assertFalse(list(Path(tmp).rglob('*.engine')))
                    (directory / 'test.engine').write_bytes(b'complete')
            finally:
                if child.poll() is None: child.kill()
                child.wait()

    def test_gpu_and_model_do_not_share_engines(self):
        with tempfile.TemporaryDirectory() as tmp:
            with cache.engine_directory(tmp, 'runtime', OPTIONS, 425, build=True) as directory:
                (directory / 'test.engine').write_bytes(b'complete')
            for options, model in [(dict(OPTIONS, gpu='other-gpu'), 425), (OPTIONS, 4251)]:
                with self.assertRaisesRegex(RuntimeError, '引擎尚未准备完成'):
                    with cache.engine_directory(tmp, 'runtime', options, model): pass

if __name__ == '__main__': unittest.main()
