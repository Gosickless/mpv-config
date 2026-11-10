"""Serialize engine creation and publish only successfully tested engines."""
from contextlib import contextmanager
import errno
import hashlib
import json
import msvcrt
import os
from pathlib import Path
import shutil
import tempfile
import time

@contextmanager
def engine_directory(root, runtime_id, options, model, build=False):
    # The GPU identity includes its UUID and driver; runtime_id pins the libraries.
    key = hashlib.sha256(json.dumps([options['gpu'], options['width'], options['height'],
                                    model, 'fp16-v2'], ensure_ascii=True).encode()).hexdigest()[:24]
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
                yield destination
            elif not build:
                raise RuntimeError('引擎尚未准备完成，请重新开启补帧')
            else:
                with tempfile.TemporaryDirectory(prefix=key + '-', dir=base) as temporary:
                    working = Path(temporary)
                    yield working
                    # The caller must construct the engine and get a real frame first.
                    (working / 'complete.json').write_text(json.dumps({'model': model}), encoding='utf-8')
                    working.rename(destination)
        finally:
            lock.seek(0)
            msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
