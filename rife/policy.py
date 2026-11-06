"""Pure input policy; imports no GPU/runtime libraries."""
from fractions import Fraction

def validate(options):
    w, h = int(options['width']), int(options['height'])
    fps = Fraction(str(options['fps']))
    if not (16 <= w <= 3840 and 16 <= h <= 2160) or w % 2 or h % 2:
        raise ValueError('仅支持偶数尺寸、最高3840x2160的逐行视频')
    if not 1 <= fps <= 30:
        raise ValueError('首版仅接受1–30 fps输入')
    if options.get('interlaced'):
        raise ValueError('不支持交错视频')
    if options.get('dolby_vision'):
        raise ValueError('暂不支持杜比视界')
    hdr = options.get('transfer') in ('pq', 'hlg')
    if options.get('transfer') == 'hlg':
        raise ValueError('暂不支持HLG')
    if hdr and not options.get('experimental_hdr', False):
        raise ValueError('HDR10处理链待5070验证，需显式启用实验模式')
    if options.get('matrix') not in ('bt.709', 'bt.2020-ncl'):
        raise ValueError('未知或不支持的颜色矩阵，拒绝猜测')
    if options.get('transfer') not in ('bt.1886', 'srgb', 'pq'):
        raise ValueError('未知或不支持的传递函数，拒绝猜测')
    return w, h, fps, hdr
