"""Shared model and rational frame-rate policy for preparation and playback."""
from fractions import Fraction
MODELS = {"lite": 4251, "standard": 425, "heavy": 4252}
def selection(options, fps):
    name = options.get("model", "standard")
    if name not in MODELS:
        raise ValueError("请选择有效的补帧画质")
    target = options.get("target_fps", 0)
    if isinstance(target, bool) or not isinstance(target, int) or target != 0 and not 24 <= target <= 360:
        raise ValueError("目标帧率应为24–360之间的整数，或选择自动两倍")
    if target == 0:
        factor = Fraction(2)
    else:
        desired = Fraction(target) / fps
        # Match the reference's half-step rule; exact ties choose the lower factor.
        factor = min((Fraction(n, 2) for n in range(3, 31)), key=lambda x: (abs(x-desired), x))
    return MODELS[name], factor
