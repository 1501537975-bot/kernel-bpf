#!/usr/bin/env python3
"""
生成 sys_clone3 backport patch（A17 zygote 硬需求）

来源（免费公开）：
  mk7x7/android_kernel_xiaomi_mt6768  (同代 MTK 4.14)
  mt6873-dev/android_kernel_xiaomi_mt6885 (cgroup-v2 分支)

sys_clone3 是 Linux 5.3 引入的新 clone 系统调用，A17 的 zygote 用它做
线程创建。4.14 没有，必须回合。

涉及文件：
  include/uapi/asm-generic/unistd.h    __NR_clone3 编号
  arch/arm64/include/asm/unistd.h       arm64 的 syscalls 表
  arch/arm64/include/uapi/asm/unistd.h
  arch/arm64/entry/common.c             arm64 入口分发
  kernel/sys.c                          __NR_clone3 的系统调用实现
  include/linux/syscalls.h              系统调用表声明
  include/uapi/linux/sched.h            CLONE3 的参数结构 (struct clone_args)

用法：python3 scripts/gen_clone3_patch.py [输出目录]
"""
import os, sys, subprocess, urllib.request, urllib.error, difflib, shutil

OUT = sys.argv[1] if len(sys.argv) > 1 else "patches/clone3"
MT6768 = "https://raw.githubusercontent.com/mk7x7/android_kernel_xiaomi_mt6768/skyron/"
MT6885 = "https://raw.githubusercontent.com/mt6873-dev/android_kernel_xiaomi_mt6885/cgroup-v2/"

FILES = [
    ("kernel/sys.c",                    "clone3 系统调用实现"),
    ("include/linux/syscalls.h",        "系统调用表声明"),
    ("include/uapi/linux/sched.h",      "struct clone_args 定义"),
    ("arch/arm64/entry/common.c",       "arm64 入口分发"),
    ("arch/arm64/include/asm/unistd.h", "arm64 syscall 表"),
    ("arch/arm64/include/uapi/asm/unistd.h", "arm64 uapi syscall 号"),
    ("include/uapi/asm-generic/unistd.h",    "__NR_clone3 编号"),
]

def fetch(url):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        return urllib.request.urlopen(req, timeout=60).read().decode("utf-8", "ignore")
    except Exception:
        return None

def main():
    root = os.path.abspath(OUT)
    os.makedirs(root, exist_ok=True)
    made, skipped = 0, []

    for path, desc in FILES:
        b = fetch(MT6768 + path)
        if b is None:
            b = fetch(MT6885 + path)
        a = fetch(MT6885 + path) if path not in ("kernel/sys.c",) else None
        if b is None:
            skipped.append(path + " (两个源都取不到)")
            continue
        if a is None:
            # 用原厂 cezanne 作为基线
            a = fetch("https://raw.githubusercontent.com/MiCode/Xiaomi_Kernel_OpenSource/cezanne-r-oss/" + path)
        if a is None:
            skipped.append(path + " (原厂基线取不到)")
            continue

        ta = a.splitlines(keepends=True)
        tb = b.splitlines(keepends=True)
        if ta == tb:
            skipped.append(path + " (内容已相同)")
            continue

        diff = list(difflib.unified_diff(ta, tb, fromfile=f"a/{path}", tofile=f"b/{path}", n=3))
        if not diff:
            continue
        name = path.replace("/", "_") + ".patch"
        hdr = [
            "From: cezanne-clone3 <auto@local>",
            f"Subject: [PATCH] clone3 backport: {path}",
            "",
            "回合自同代 MTK 树（mt6768 / mt6885）",
            "目标：Android 17 zygote 需要 sys_clone3",
            f"说明：{desc}",
            "",
            "---",
            "",
        ]
        with open(os.path.join(root, name), "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(hdr))
            f.writelines(diff)
        made += 1
        print(f"  [生成] {name}  ({len(diff)} 行)")

    print(f"\n共生成 {made} 个 clone3 patch")
    for s in skipped:
        print("  跳过:", s)
    if made:
        print(f"\npatch 目录：{root}")

if __name__ == "__main__":
    main()
