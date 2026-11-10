#!/usr/bin/env python3
"""为 GCC 11 编译 MTK 4.14 老内核做两处定点兼容修正。

1) 裸 inline 声明 (C99 inline 语义)
   MTK 头文件写成 `inline void ksm_flock(...);` 声明, .c 里写成
   `inline void ksm_flock(...) { ... }` 定义并 EXPORT_SYMBOL。
   GCC 5+ 下 inline 不生成外部符号, 且 4.14 的 compiler-gcc.h 把 inline
   展开成 always_inline, 于是报:
     "inlining failed in call to 'always_inline' 'ksm_flock': function body not available"
   修法: 头文件与 .c 定义都去掉裸 `inline ` 关键字, 保留其他字节不变。

2) subdir-ccflags-y += -Werror
   mtk-vcu / mtk-vcodec 等老驱动有大量 printk 格式与 u64 不匹配,
   GCC 11 会把它变成 -Werror=format 硬错误。降为普通警告即可。

只删关键字, 不重排任何代码。用法: python3 fix_legacy_gcc11.py <内核树>
"""
import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."

# (头文件, 函数名) —— 声明与定义成对处理
INLINE_PAIRS = [
    ("include/linux/keyslot-manager.h", "block/keyslot-manager.c", "ksm_flock"),
    ("include/linux/blk-crypto.h", "block/blk-crypto.c", "blk_crypto_flock"),
]

# 不再用固定清单: MTK 老驱动里带 -Werror 的 Makefile 分布在
# drivers/media / drivers/gpu / sound/soc 等多处, 逐个列会漏。
# 改为全树扫描所有 Makefile 的 ccflags 行。
WERROR_LINE = re.compile(
    r"^(\s*(?:subdir-)?ccflags-y\s*\+=\s*)(.*)$", re.M)


def strip_inline(path, func):
    """只在『裸 inline 声明/定义』这一行删掉 inline 关键字。"""
    if not os.path.isfile(path):
        return 0
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        lines = f.readlines()
    changed = 0
    pat = re.compile(r"^(\s*)inline\s+(.*\b%s\s*\()" % re.escape(func))
    for i, ln in enumerate(lines):
        m = pat.match(ln)
        if m:
            # 只删第一个 "inline ", 其余字节原样保留
            lines[i] = ln.replace("inline ", "", 1)
            changed += 1
    if changed:
        with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
            f.writelines(lines)
    return changed


def main():
    n1 = 0
    for hdr, src, fn in INLINE_PAIRS:
        for p in (hdr, src):
            c = strip_inline(os.path.join(ROOT, p), fn)
            n1 += c
            if c:
                print("[ok] 去掉 inline: %s (%s)" % (p, fn))
    print("[inline] 共修正 %d 处" % n1)

    n2 = 0
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in (".git", "out", "Documentation")]
        if "Makefile" not in filenames:
            continue
        p = os.path.join(dirpath, "Makefile")
        # 跳过内核顶层 Makefile: 那里的 -Werror-implicit-* 是有意保留的
        if os.path.abspath(p) == os.path.abspath(os.path.join(ROOT, "Makefile")):
            continue
        with open(p, "r", encoding="utf-8", errors="surrogateescape") as f:
            s = f.read()

        def fix_line(m):
            flags = m.group(2)
            new = re.sub(r"(?<![\w-])-Werror(?=[\s=]|$)", "-Wno-error", flags)
            return m.group(1) + new

        s2 = WERROR_LINE.sub(fix_line, s)
        if s2 != s:
            with open(p, "w", encoding="utf-8", errors="surrogateescape") as f:
                f.write(s2)
            n2 += 1
            rel = os.path.relpath(p, ROOT)
            if n2 <= 25:
                print("[ok] ccflags -Werror -> -Wno-error: %s" % rel)
    print("[Werror] 共修正 %d 个 Makefile" % n2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
