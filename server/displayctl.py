#!/usr/bin/env python3
"""调节 / 读取内建屏亮度（经 DisplayServices 私有 API）。

用法:
  displayctl.py get          → 打印 0~1 浮点
  displayctl.py set <0~1>    → 设置并打印设置后的值
"""
from __future__ import annotations

import sys
from ctypes import CDLL, POINTER, byref, c_float, c_int, c_uint32


def _load():
    cg = CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    ds = CDLL("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices")
    cg.CGGetActiveDisplayList.argtypes = [c_uint32, POINTER(c_uint32), POINTER(c_uint32)]
    cg.CGGetActiveDisplayList.restype = c_int
    ds.DisplayServicesCanChangeBrightness.argtypes = [c_uint32]
    ds.DisplayServicesCanChangeBrightness.restype = c_int
    ds.DisplayServicesGetBrightness.argtypes = [c_uint32, POINTER(c_float)]
    ds.DisplayServicesGetBrightness.restype = c_int
    ds.DisplayServicesSetBrightness.argtypes = [c_uint32, c_float]
    ds.DisplayServicesSetBrightness.restype = c_int
    return cg, ds


def _controllable_display(cg, ds) -> c_uint32 | None:
    arr = (c_uint32 * 16)()
    count = c_uint32(0)
    if cg.CGGetActiveDisplayList(16, arr, byref(count)) != 0:
        return None
    for d in list(arr)[: count.value]:
        if ds.DisplayServicesCanChangeBrightness(d):
            return d
    return None


def get_brightness() -> float:
    cg, ds = _load()
    d = _controllable_display(cg, ds)
    if d is None:
        raise SystemExit("找不到可调节亮度的显示器")
    val = c_float(0)
    rc = ds.DisplayServicesGetBrightness(d, byref(val))
    if rc != 0:
        raise SystemExit(f"读取亮度失败 rc={rc}")
    return float(val.value)


def set_brightness(level: float) -> float:
    level = max(0.0, min(1.0, level))
    cg, ds = _load()
    d = _controllable_display(cg, ds)
    if d is None:
        raise SystemExit("找不到可调节亮度的显示器")
    rc = ds.DisplayServicesSetBrightness(d, c_float(level))
    if rc != 0:
        raise SystemExit(f"设置亮度失败 rc={rc}")
    return get_brightness()


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] not in ("get", "set"):
        print("用法: displayctl.py get | set <0~1>", file=sys.stderr)
        raise SystemExit(2)
    if sys.argv[1] == "get":
        print(f"{get_brightness():.6f}")
        return
    if len(sys.argv) < 3:
        raise SystemExit("set 需要参数 0~1")
    print(f"{set_brightness(float(sys.argv[2])):.6f}")


if __name__ == "__main__":
    main()
