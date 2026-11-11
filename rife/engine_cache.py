"""Serialize engine creation and publish only successfully tested engines."""
from contextlib import contextmanager
import errno
import hashlib
import json
import msvcrt
import os
from pathlib import Path
import re
import shutil
import tempfile
import time

CACHE_LIMIT = 2 * 1024 ** 3
CACHE_TARGET = 1536 * 1024 ** 2

def _engine_key(options, model):
    return hashlib.sha256(json.dumps([options['gpu'], options['width'], options['height'],
                                    model, 'fp16-v2' if model == 425 else 'tf32-v2'], ensure_ascii=True).encode()).hexdigest()[:24]

def retain_engine(directory):
    """Hold a shared usage lock until the VS script is destroyed."""
    handle = directory.with_suffix('.lock').open('r+b')
    try:
        handle.seek(1)
        msvcrt.locking(handle.fileno(), msvcrt.LK_NBRLCK, 1)
    except BaseException:
        handle.close()
        raise
    return handle

def prune_cache(root, protected=None, limit=CACHE_LIMIT, target=CACHE_TARGET):
    """Trim completed engines by last successful use; skip busy entries."""
    base = Path(root) / 'cache'
    if not base.is_dir() or base.is_symlink() or base.is_junction():
        return
    with (base / '.prune.lock').open('a+b') as sweep:
        sweep.seek(0)
        try:
            msvcrt.locking(sweep.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError as exc:
            if exc.errno not in (errno.EACCES, errno.EDEADLK): raise
            return
        try:
            entries = []
            for runtime in base.iterdir():
                if not runtime.is_dir() or runtime.is_symlink() or runtime.is_junction(): continue
                for directory in runtime.iterdir():
                    if not re.fullmatch('[0-9a-f]{24}', directory.name) or not directory.is_dir() or directory.is_symlink() or directory.is_junction(): continue
                    marker = directory / 'complete.json'
                    try:
                        size = sum(p.stat().st_size for p in directory.rglob('*') if p.is_file())
                        entries.append((marker.stat().st_mtime_ns, directory, size))
                    except FileNotFoundError:
                        continue
            total = sum(item[2] for item in entries)
            if total <= limit: return
            for last_used, directory, _ in sorted(entries):
                if total <= target: break
                if directory == protected: continue
                with directory.with_suffix('.lock').open('a+b') as lock:
                    try:
                        lock.seek(0); msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 2)
                    except OSError as exc:
                        if exc.errno not in (errno.EACCES, errno.EDEADLK): raise
                        continue
                    try:
                        # Recheck under the engine lock: a newer access wins over
                        # the scan, and another process may already have removed it.
                        marker = directory / 'complete.json'
                        if not marker.is_file(): continue
                        if marker.stat().st_mtime_ns != last_used: continue
                        size = sum(p.stat().st_size for p in directory.rglob('*') if p.is_file())
                        _discard(directory)
                        total -= size
                    finally:
                        lock.seek(0); msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 2)
        finally:
            sweep.seek(0); msvcrt.locking(sweep.fileno(), msvcrt.LK_UNLCK, 1)

class CachedEngineError(RuntimeError):
    """An existing cache failed its real-frame check and has been discarded."""

def _discard(directory):
    if directory.is_symlink() or directory.is_junction():
        raise RuntimeError('补帧缓存目录异常，请检查组件安装目录')
    if directory.exists():
        shutil.rmtree(directory)

def prepare_engine(root, runtime_id, options, model, create):
    # Only a failed reused engine gets one fresh attempt. New-build failures
    # propagate immediately, including the second failure, without a retry loop.
    try:
        with engine_directory(root, runtime_id, options, model, build=True) as directory:
            create(directory)
    except CachedEngineError:
        with engine_directory(root, runtime_id, options, model, build=True) as directory:
            create(directory)
    prune_cache(root, Path(root) / 'cache' / runtime_id / _engine_key(options, model))

@contextmanager
def engine_directory(root, runtime_id, options, model, build=False):
    # The GPU identity includes its UUID and driver; runtime_id pins the libraries.
    key = _engine_key(options, model)
    base = Path(root) / 'cache' / runtime_id
    base.mkdir(parents=True, exist_ok=True)
    destination = base / key
    with (base / (key + '.lock')).open('a+b') as lock:
        if lock.seek(0, os.SEEK_END) == 0:
            lock.write(b'0'); lock.flush()
        lock.seek(0)
        while True:
            try:
                msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
                break
            except OSError as exc:
                if exc.errno not in (errno.EACCES, errno.EDEADLK):
                    raise
                time.sleep(.1)
        try:
            # A killed preparation process cannot run its finally block. The OS
            # has released its lock, so only abandoned jobs can remain here.
            for abandoned in base.glob(key + '-*'):
                if abandoned.is_dir() and not abandoned.is_symlink() and abandoned.resolve().is_relative_to(base.resolve()):
                    shutil.rmtree(abandoned)
            if (destination / 'complete.json').is_file():
                try:
                    yield destination
                    os.utime(destination / 'complete.json', None)
                except Exception as exc:
                    _discard(destination)
                    raise CachedEngineError('补帧缓存无法使用，已清理，可重新准备') from exc
            elif not build:
                raise RuntimeError('引擎尚未准备完成，请重新开启补帧')
            else:
                # A missing completion marker must not block atomic rename.
                _discard(destination)
                with tempfile.TemporaryDirectory(prefix=key + '-', dir=base) as temporary:
                    working = Path(temporary)
                    yield working
                    # The caller must construct the engine and get a real frame first.
                    (working / 'complete.json').write_text(json.dumps({'model': model}), encoding='utf-8')
                    working.rename(destination)
        finally:
            lock.seek(0)
            msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
