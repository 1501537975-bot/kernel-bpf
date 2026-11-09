#!/usr/bin/env python3
"""
校验 erofs 源码里的 EROFS_ 宏/枚举是否都有定义。

背景 (第 33 轮): mt6873 的 fs/erofs 删掉了上游的 uapi/linux/erofs_fs.h
  include, 导致 EROFS_SUPER_MAGIC_V1 无定义, 编译 20 分钟后才炸。
  这个检查放在编译之前, 几秒内就能发现。

用法:
  python3 check_erofs_macros.py <fs/erofs 目录>
退出码 0 = 通过, 1 = 有未定义
"""
import os
import re
import sys

NOT_MACROS = {
    "EROFS_SB", "EROFS_I", "EROFS_MOUNT_", "EROFS_FEATURE_",
    "EROFS_FEATURE_FUNCS", "EROFS_BLKSIZ",
    "EROFS_ZIP_CACHE_DISABLED", "EROFS_ZIP_CACHE_READAHEAD",
    "EROFS_ZIP_CACHE_READAROUND",
    "EROFS_MAP_MAPPED", "EROFS_MAP_META", "EROFS_MAP_ZIPPED",
    "EROFS_MAP_FULL_MAPPED", "EROFS_GET_BLOCKS_RAW",
    "EROFS_INODE_DATALAYOUT_MAX", "EROFS_LOCKED_MAGIC",
}


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    d = sys.argv[1]
    if not os.path.isdir(d):
        print("[FAIL] 目录不存在: %s" % d)
        return 1

    defined = set()
    used = set()

    for fn in sorted(os.listdir(d)):
        if not fn.endswith((".c", ".h")):
            continue
        t = open(os.path.join(d, fn), encoding="utf-8", errors="replace").read()

        for m in re.finditer(r"#define\s+(EROFS_\w+)", t):
            defined.add(m.group(1))

        # enum { EROFS_A, EROFS_B = 1 } —— 枚举成员不是 #define
        for em in re.finditer(r"enum\s*\{([^}]*)\}", t, re.S):
            body = re.sub(r"/\*.*?\*/", "", em.group(1), flags=re.S)
            body = re.sub(r"//.*", "", body)
            for part in body.split(","):
                m = re.match(r"(EROFS_\w+)\b", part.strip())
                if m:
                    defined.add(m.group(1))

        for m in re.finditer(r"\bEROFS_[A-Z0-9_]{2,}\b", t):
            used.add(m.group(0))

    undef = sorted(x for x in used - defined - NOT_MACROS)
    if undef:
        print("  [FAIL] 这些 EROFS_ 标识符没有定义:")
        for x in undef:
            print("      %s" % x)
        return 1

    print("  erofs 标识符完整性 OK (%d 个定义, %d 个被引用)" % (len(defined), len(used)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
