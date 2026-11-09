#!/usr/bin/env python3
"""
补齐 erofs 头文件里缺失的宏。

★ 背景 (第 33 轮编译失败):
    mt6873-dev (4.14.336) 自带的 fs/erofs 源码是**不完整**的:
      - fs/erofs/erofs_fs.h 里删掉了上游的 `#include <uapi/linux/erofs_fs.h>`
      - 结果 EROFS_SUPER_MAGIC_V1 等常量**无定义**
      - 编译报: super.c:279:40: error: 'EROFS_SUPER_MAGIC_V1' undeclared

    修法: 从上游 (Linux 4.19 staging erofs) 的 erofs_fs.h 里
          提取 mt6873 缺失的宏, 插进 fs/erofs/erofs_fs.h。

用法:
  python3 patch_erofs_hdr.py <uapi erofs_fs.h> <目标 fs/erofs/erofs_fs.h>
"""
import os
import re
import sys


def parse_macros(text):
    """返回 {宏名: (完整定义文本)}，支持反斜杠续行。"""
    out = {}
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        m = re.match(r"#define\s+(EROFS_\w+)\b(.*)", lines[i])
        if m:
            name = m.group(1)
            buf = [lines[i].rstrip()]
            while buf[-1].endswith("\\") and i + 1 < len(lines):
                i += 1
                buf.append(lines[i].rstrip())
            out[name] = "\n".join(buf)
        i += 1
    return out


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    uapi_path, target_path = sys.argv[1], sys.argv[2]

    if not os.path.exists(uapi_path):
        print("[warn] 上游 uapi 头不存在: %s" % uapi_path)
        return 0
    if not os.path.exists(target_path):
        print("[FAIL] 目标头不存在: %s" % target_path)
        return 1

    uapi = open(uapi_path, encoding="utf-8", errors="replace").read()
    tgt = open(target_path, encoding="utf-8", errors="replace").read()

    um = parse_macros(uapi)
    tm = parse_macros(tgt)

    missing = [k for k in sorted(um) if k not in tm]
    if not missing:
        print("[ ok ] 目标头已包含全部上游宏, 无需补齐")
        return 0

    # 依赖检查: 宏定义里引用了其它 EROFS_ 宏时, 那些也必须存在
    deps_ok = True
    add = []
    for name in missing:
        body = um[name]
        refs = set(re.findall(r"\bEROFS_[A-Z0-9_]+\b", body)) - {name}
        unresolved = [r for r in refs if r not in tm and r not in um]
        if unresolved:
            print("[warn] %s 依赖未满足 %s, 跳过" % (name, unresolved))
            continue
        add.append(name)
        deps_ok = True

    if not add:
        print("[warn] 没有可安全补齐的宏")
        return 0

    # 插到 #endif 之前
    idx = tgt.rfind("#endif")
    if idx < 0:
        idx = len(tgt)
    block = ["", "/* ---- 以下宏由 patch_erofs_hdr.py 从上游 erofs 补齐 ---- */",
             "/* mt6873-dev 的 fs/erofs 删掉了上游的 uapi/linux/erofs_fs.h include,",
             "   导致这些常量无定义 (EROFS_SUPER_MAGIC_V1 undeclared)。 */"]
    for name in add:
        block.append(um[name])
    block.append("")

    new = tgt[:idx] + "\n".join(block) + "\n" + tgt[idx:]
    with open(target_path, "w", encoding="utf-8", errors="replace", newline="\n") as f:
        f.write(new)

    print("[ ok ] 已补齐 %d 个宏: %s" % (len(add), ", ".join(add)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
