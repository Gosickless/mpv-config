"""Small real-file tests for LRU eviction and Windows usage locks."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'rife'
spec = importlib.util.spec_from_file_location('engine_cache', SOURCE / 'engine_cache.py')
cache = importlib.util.module_from_spec(spec); spec.loader.exec_module(cache)
OPTIONS = {'gpu':'test-gpu', 'width':1920, 'height':1080}

def engine(root, model, stamp, runtime='runtime'):
    with cache.engine_directory(root, runtime, OPTIONS, model, build=True) as working:
        (working / 'test.engine').write_bytes(b'x' * 80)
    path = Path(root) / 'cache' / runtime / cache._engine_key(OPTIONS, model)
    os.utime(path / 'complete.json', (stamp, stamp))
    return path

def size(path):
    return sum(p.stat().st_size for p in path.rglob('*') if p.is_file())

class CacheLimitTests(unittest.TestCase):
    def test_lru_uses_successful_access_not_creation_order(self):
        with tempfile.TemporaryDirectory() as tmp:
            first = engine(tmp, 425, 100)
            second = engine(tmp, 4251, 200)
            third = engine(tmp, 4252, 300, runtime='older-runtime')
            with cache.engine_directory(tmp, 'runtime', OPTIONS, 425): pass
            cache.prune_cache(tmp, limit=size(first)+size(second), target=size(first))
            self.assertTrue(first.exists())
            self.assertFalse(second.exists())
            self.assertFalse(third.exists())

    def test_below_limit_does_not_delete_or_touch_downloads(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = engine(tmp, 425, 100)
            downloads = Path(tmp) / 'downloads'; downloads.mkdir()
            (downloads / 'sample.part').write_bytes(b'keep')
            cache.prune_cache(tmp, limit=size(path), target=0)
            self.assertTrue(path.exists())
            self.assertEqual((downloads / 'sample.part').read_bytes(), b'keep')

    def test_busy_reader_and_current_engine_can_temporarily_exceed_limit(self):
        with tempfile.TemporaryDirectory() as tmp:
            active = engine(tmp, 425, 100)
            current = engine(tmp, 4251, 200)
            with cache.retain_engine(active):
                cache.prune_cache(tmp, protected=current, limit=1, target=0)
                self.assertTrue(active.exists())
                self.assertTrue(current.exists())
            cache.prune_cache(tmp, protected=current, limit=1, target=0)
            self.assertFalse(active.exists())
            self.assertTrue(current.exists())

    def test_preparation_lock_and_incomplete_work_are_not_deleted(self):
        with tempfile.TemporaryDirectory() as tmp:
            active = engine(tmp, 425, 100)
            with cache.engine_directory(tmp, 'runtime', OPTIONS, 425):
                cache.prune_cache(tmp, limit=1, target=0)
                self.assertTrue(active.exists())
            with cache.engine_directory(tmp, 'runtime', OPTIONS, 4251, build=True) as working:
                (working / 'partial.engine').write_bytes(b'x' * 1000)
                cache.prune_cache(tmp, limit=1, target=0)
                self.assertTrue((working / 'partial.engine').exists())

    def test_other_process_cannot_evict_live_playback_lease(self):
        with tempfile.TemporaryDirectory() as tmp:
            active = engine(tmp, 425, 100)
            code = "import sys;sys.path.insert(0,sys.argv[1]);from engine_cache import prune_cache;prune_cache(sys.argv[2],limit=1,target=0)"
            with cache.retain_engine(active):
                result = subprocess.run([sys.executable,'-B','-c',code,str(SOURCE),tmp],capture_output=True,timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(active.exists())
            cache.prune_cache(tmp, limit=1, target=0)
            self.assertFalse(active.exists())

    def test_public_prepare_triggers_pruning_and_keeps_new_engine(self):
        with tempfile.TemporaryDirectory() as tmp:
            old = engine(tmp, 4251, 100)
            original = cache.prune_cache
            cache.prune_cache = lambda root, protected: original(root, protected, limit=1, target=0)
            try:
                cache.prepare_engine(tmp,'runtime',OPTIONS,425,lambda p: (p/'test.engine').write_bytes(b'new'))
            finally:
                cache.prune_cache = original
            self.assertFalse(old.exists())
            with cache.engine_directory(tmp,'runtime',OPTIONS,425) as current:
                self.assertEqual((current/'test.engine').read_bytes(), b'new')

if __name__ == '__main__': unittest.main()
