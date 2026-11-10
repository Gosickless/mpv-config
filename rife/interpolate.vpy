"""Experimental standard-mpv RIFE bridge. No Tigerest-only filter options."""
import json
from fractions import Fraction
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from policy import validate
from settings import selection
from probe import load_runtime
from engine_cache import engine_directory

options = json.loads(user_data)
w, h, fps, hdr = validate(options)
model, factor = selection(options, fps)
vs, _dll_handles, runtime, layout = load_runtime(options['root'])
from vsmlrt import RIFE, RIFEModel, Backend
core = vs.core
source = video_in
if source.width != w or source.height != h or source.format is None:
    raise ValueError('输入尺寸或格式与探测结果不一致')
# Standard mpv supplies per-frame durations with an unspecified node frame rate.
if not source.fps_num or not source.fps_den:
    nominal = Fraction(str(options['fps'])).limit_denominator(1001)
    source = core.std.AssumeFPS(source, fpsnum=nominal.numerator, fpsden=nominal.denominator)
input_fps = source.fps
if abs(float(source.fps) - float(fps)) > .02:
    raise ValueError('输入帧率与探测结果不一致')
if hdr and source.format.bits_per_sample < 10:
    raise ValueError('HDR输入位深不足10位')
def validate_frame(n, f):
    if f.props.get('_FieldBased', 0):
        raise ValueError('不支持交错帧')
    num=f.props.get('_DurationNum', 0)
    den=f.props.get('_DurationDen', 0)
    if num > 0 and den > 0 and abs((num/den)*float(input_fps)-1) > .05:
        raise ValueError('检测到非恒定帧时长，停止补帧')
    return f
source=core.std.ModifyFrame(source,clips=source,selector=validate_frame)
matrix = {'bt.709': 1, 'bt.2020-ncl': 9}[options['matrix']]
transfer = {'bt.1886': 1, 'srgb': 13, 'pq': 16}[options['transfer']]
primaries = 9 if options.get('primaries') == 'bt.2020' else 1
range_value = 0 if options.get('range') == 'full' else 1
# HDR candidate deliberately keeps PQ coded RGB; it does not tone-map to SDR.
# Accuracy and static metadata round-trip remain experimental.
rgb = core.resize.Bicubic(source, format=vs.RGBS, matrix_in=matrix, range_in=range_value)
# Small luma comparison for a basic, explicit scene-cut threshold.
gray = core.resize.Bilinear(source, width=64, height=36, format=vs.GRAYS, range_in=range_value)
next_gray = gray[1:] + gray[-1:]
stats = core.std.PlaneStats(gray, next_gray)
def mark_cut(n, f):
    image = f[0].copy()
    image.props['_SceneChangeNext'] = int(f[1].props['PlaneStatsDiff'] > .15)
    return image
rgb = core.std.ModifyFrame(rgb, clips=[rgb, stats], selector=mark_cut)
with engine_directory(options['root'], layout['id'], options, model) as cache:
    backend = Backend.TRT(fp16=True, num_streams=1, use_cuda_graph=False,
                          engine_folder=str(cache), short_path=True)
    result = RIFE(rgb, multi=factor, model=RIFEModel(model), backend=backend, video_player=True, _implementation=2)
result = core.resize.Bicubic(result, format=vs.YUV420P10, matrix=matrix, range=range_value)
# Standard mpv restores its native image attributes from this opaque property.
# Carry it from the corresponding original frame; never parse its binary layout.
if factor == 2:
    props = core.std.Interleave([source, source])
else:
    template = core.std.BlankClip(result, keep=True)
    props = core.std.FrameEval(template, lambda n: source[min(n * factor.denominator // factor.numerator, source.num_frames - 1)])
result = core.std.CopyFrameProps(result, props)
result = core.std.SetFrameProps(result, _Matrix=matrix, _Transfer=transfer,
                               _Primaries=primaries, _ColorRange=range_value)
# Stamp every output frame with the selected rational frame duration.
def stamp(n, f):
    output = f.copy()
    duration = 1 / (source.fps * factor)
    output.props['_DurationNum'] = duration.numerator
    output.props['_DurationDen'] = duration.denominator
    return output
result = core.std.ModifyFrame(result, clips=result, selector=stamp)
result.set_output()
