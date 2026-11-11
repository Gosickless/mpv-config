"""Independent runtime probe; never builds an engine or changes global Python."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

def runtime_layout(root):
    root = Path(root).resolve()
    active = json.loads((root / 'active.json').read_text(encoding='utf-8-sig'))
    runtime = Path(active['root']).resolve()
    if not runtime.is_relative_to(root / 'runtime'):
        raise ValueError('运行环境目录越界')
    layout = json.loads((runtime / 'runtime.json').read_text(encoding='utf-8-sig'))
    for key in ('python', 'vsscript', 'plugin', 'scripts'):
        item = (runtime / layout[key]).resolve()
        if not item.is_relative_to(runtime) or not item.exists():
            raise ValueError('运行环境路径缺失或越界: ' + key)
    return runtime, layout

def load_runtime(root):
    runtime, layout = runtime_layout(root)
    # Retain the handles for the lifetime of this VS script/session.
    directories = sorted({p.parent for p in runtime.rglob('*.dll')})
    handles = [os.add_dll_directory(str(p)) for p in directories]
    os.environ['PATH'] = os.pathsep.join(dict.fromkeys([str(p) for p in directories] + os.environ.get('PATH', '').split(os.pathsep)))
    sys.path.insert(0, str(runtime / layout['scripts']))
    import vapoursynth as vs
    if not hasattr(vs.core, 'trt'):
        vs.core.std.LoadPlugin(path=str(runtime / layout['plugin']))
    return vs, handles, runtime, layout

def gpu_identity():
    result = subprocess.run(['nvidia-smi', '--query-gpu=name,driver_version,uuid', '--format=csv,noheader'],
                            capture_output=True, text=True, timeout=15, creationflags=0x08000000)
    if result.returncode or not result.stdout.strip():
        raise RuntimeError('未检测到可用NVIDIA驱动')
    return result.stdout.strip()

def probe(root):
    gpu = gpu_identity()
    vs, handles, runtime, layout = load_runtime(root)
    import vsmlrt
    return {'ok': True, 'gpu': gpu, 'runtime': str(runtime),
            'activation': {'runtime': str(runtime), 'python': str(runtime / 'python313.dll'),
                           'vsscript': str(runtime / layout['vsscript']),
                           'pythonpath': str(runtime / 'Lib/site-packages'),
                           'directories': [str(runtime)] + [str(p) for p in sorted({p.parent for p in runtime.rglob('*.dll')})]},
            'vapoursynth': str(vs.__version__), 'vsmlrt': vsmlrt.__version__,
            'inference_verified': False, 'hdr_verified': False}

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(probe(args.root), ensure_ascii=True))
    except Exception as exc:
        print(json.dumps({'ok': False, 'error': str(exc)}, ensure_ascii=True))
        sys.exit(1)
