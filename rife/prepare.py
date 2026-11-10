"""Prepare/cache an engine outside the mpv process; requires the target NVIDIA GPU."""
import argparse
import json
from pathlib import Path
from policy import validate
from probe import load_runtime
from settings import selection

def prepare(root, request):
    options = json.loads(Path(request).read_text(encoding='utf-8-sig'))
    w,h,fps,hdr = validate(options)
    model, factor = selection(options, fps)
    vs, handles, runtime, layout = load_runtime(root)
    from vsmlrt import RIFE, RIFEModel, Backend
    cache = Path(root) / 'cache' / layout['id']
    cache.mkdir(parents=True, exist_ok=True)
    clip = vs.core.std.BlankClip(width=w,height=h,length=3,format=vs.RGBS,
                                 fpsnum=fps.numerator,fpsden=fps.denominator)
    backend = Backend.TRT(fp16=True,num_streams=1,use_cuda_graph=False,
                          engine_folder=str(cache),short_path=True)
    result = RIFE(clip,multi=factor,model=RIFEModel(model),backend=backend,video_player=True)
    result.get_frame(1)
    return {'ok':True,'engine_prepared':True,'hdr_verified':False}

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--root',required=True);parser.add_argument('--request',required=True)
    args=parser.parse_args()
    try:print(json.dumps(prepare(args.root,args.request)))
    except Exception as exc:
        print(json.dumps({'ok':False,'error':str(exc)}));raise SystemExit(1)
