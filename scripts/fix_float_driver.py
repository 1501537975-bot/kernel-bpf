#!/usr/bin/env python3
"""把 MTK 充电驱动里的浮点 ADC 系数改成定点整数。

背景:
  drivers/power/supply/ti_cezanne/bq2597x_charger.c 里
    static float sc8551_adc_lsb[] = { ... };
    *result = (int)(t * sc8551_adc_lsb[channel]);
  并用 kernel_neon_begin/end 包住。arm64 内核全局带
  -mgeneral-regs-only, GCC 11 会在编译期直接拒绝任何浮点类型:
    error: '-mgeneral-regs-only' is incompatible with the use of floating-point types

做法 (不改数值语义):
  - float 数组 -> long long 数组, 每个系数乘 1e6 取整
  - 乘法改成 (s64)t * coeff / 1000000
  - 去掉 kernel_neon_begin/end (整数运算不需要 NEON 上下文)

只做这三处定点替换, 其余字节不动。
用法: python3 fix_float_driver.py <内核树>
"""
import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
REL = "drivers/power/supply/ti_cezanne/bq2597x_charger.c"
HDR = "drivers/power/supply/ti_cezanne/bq25970_reg.h"
SCALE = 1000000


def parse_macros():
    """从头文件把 SC8551_*_ADC_LSB 的浮点常量算成放大后的整数。"""
    p = os.path.join(ROOT, HDR)
    if not os.path.isfile(p):
        return {}
    with open(p, "r", encoding="utf-8", errors="surrogateescape") as f:
        text = f.read()
    out = {}
    for m in re.finditer(r"^\s*#define\s+(SC8551_\w+_ADC_LSB)\s+(.+?)\s*$",
                         text, re.M):
        name, expr = m.group(1), m.group(2)
        expr = expr.split("/*")[0].strip()
        if not re.fullmatch(r"[0-9.+\-*/()\s]+", expr):
            continue
        try:
            val = eval(expr, {"__builtins__": {}}, {})  # 仅数字表达式
            out[name] = int(round(float(val) * SCALE))
        except Exception:
            continue
    return out


def main():
    macro_vals = parse_macros()
    print("[info] 解析到 %d 个 ADC 系数" % len(macro_vals))
    p = os.path.join(ROOT, REL)
    if not os.path.isfile(p):
        print("[skip] %s 不存在" % REL)
        return 0
    with open(p, "r", encoding="utf-8", errors="surrogateescape") as f:
        s = f.read()
    orig = s

    # 1) float 数组声明 -> long long, 每个初值乘 1e6
    m = re.search(r"(static\s+)float(\s+sc8551_adc_lsb\s*\[\]\s*=\s*\{)(.*?)(\n\};)",
                  s, re.S)
    if m:
        body = m.group(3)

        def repl(x):
            name = x.group(2)
            if name in macro_vals:
                return "%s%dLL%s" % (x.group(1), macro_vals[name], x.group(3))
            return "%s((long long)(%s * %d))%s" % (
                x.group(1), name, SCALE, x.group(3))

        body2 = re.sub(r"(=\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*,)", repl, body)
        s = s[:m.start()] + (m.group(1) + "long long" + m.group(2) +
                             body2 + m.group(4)) + s[m.end():]
        print("[ok] float 数组 -> long long 整数常量 (x%d)" % SCALE)
    else:
        print("[warn] 未找到 float 数组声明")

    # 2) 浮点乘法 -> 64 位定点乘除
    s2, n = re.subn(
        r"\(\s*int\s*\)\s*\(\s*t\s*\*\s*sc8551_adc_lsb\s*\[\s*channel\s*\]\s*\)",
        "(int)((long long)t * sc8551_adc_lsb[channel] / %d)" % SCALE, s)
    if n:
        print("[ok] 浮点乘法 -> 定点乘除 (%d 处)" % n)
        s = s2
    else:
        print("[warn] 未找到浮点乘法表达式")

    # 3) 去掉 NEON 保护 (整数运算不需要)
    s, n1 = re.subn(r"^\s*kernel_neon_begin\(\);\s*\n", "", s, flags=re.M)
    s, n2 = re.subn(r"^\s*kernel_neon_end\(\);\s*\n", "", s, flags=re.M)
    print("[ok] 去掉 kernel_neon_begin/end: %d/%d" % (n1, n2))

    if s != orig:
        with open(p, "w", encoding="utf-8", errors="surrogateescape") as f:
            f.write(s)
        print("[info] 已写回 %s" % REL)
    return 0


if __name__ == "__main__":
    sys.exit(main())
