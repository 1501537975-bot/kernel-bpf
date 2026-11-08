#!/usr/bin/env python3
"""
从公开的同代 MTK 内核树（mk7x7/android_kernel_xiaomi_mt6768, MT6768 天玑700, 4.14）
提取 A16/A17 所需的 BPF 能力，回合成可 apply 到 cezanne 4.14.186 的 patch。

为什么能这样做：
  mt6768 与 cezanne 同为 MTK 4.14 内核（同一 ACK 4.14-stable 基线），
  架构一致（arm64）、内核 API 一致，BPF 子系统改动可跨 SoC 移植。
  mt6768 树里的关键提交（与 mt6873-dev 同源）：
    · net: bpf, sockmap: convert to generic sk_msg interface
    · BACKPORT: bpf, x86_32: add eBPF JIT compiler
    · BACKPORT: bpf: Restrict bpf_probe_read{, str}() only to archs where t…
    · UPSTREAM: bpf: Allow reads from uninit stack
    · BACKPORT: samples/bpf: sample application and documentation for AF_XD…
    · LTS: Update to 4.14.357
    · BACKPORT: iov_iter: Use accessor function
    · net: bpf, sockmap: convert to generic sk_msg interface

本脚本做两件事：
  1. 下载 mt6768 与原厂 cezanne 的相关 BPF 文件
  2. 生成 unified diff，存入 patches/mt6768-bpf/

用法：python3 scripts/gen_bpf_patches.py [输出目录]
"""
import os, sys, subprocess, urllib.request, urllib.error, difflib, shutil

OUT = sys.argv[1] if len(sys.argv) > 1 else "patches/mt6768-bpf"
SRC_BRANCH = "skyron"          # mk7x7 mt6768 的默认分支（master 内容相同）
DST_BRANCH = "cezanne-r-oss"   # MiCode 原厂

MT6768 = f"https://raw.githubusercontent.com/mk7x7/android_kernel_xiaomi_mt6768/{SRC_BRANCH}/"
CEZANNE = f"https://raw.githubusercontent.com/MiCode/Xiaomi_Kernel_OpenSource/{DST_BRANCH}/"

# 需要回合的 BPF 相关文件（按依赖顺序）
FILES = [
    ("include/uapi/linux/bpf.h",        "BPF UAPI 定义（含 BPF_FUNC_* / sk_msg 相关）"),
    ("include/linux/bpf.h",             "内核侧 BPF 定义"),
    ("include/uapi/asm-generic/unistd.h", None),   # clone3 syscall 号（可选）
    ("kernel/bpf/core.c",               "BPF 核心：map / prog / link 创建"),
    ("kernel/bpf/verifier.c",           "验证器：BTF 支持的核心"),
    ("kernel/bpf/syscall.c",            "bpf() 系统调用实现"),
    ("kernel/bpf/btf.c",                "BTF 生成与解析"),
    ("kernel/bpf/hashtab.c",            "map 实现"),
    ("net/core/filter.c",               "sockmap → sk_msg 转换（关键）"),
    ("net/core/sock_map.c",             "sockmap 实现"),
    ("net/core/sock.c",                 "socket 层 sock_map 引用"),
    ("kernel/trace/bpf_trace.c",         "BPF trace 挂载"),
    ("kernel/bpf/sched_cls.c",          None),
]

def fetch(url, dest):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        data = urllib.request.urlopen(req, timeout=60).read()
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as f:
            f.write(data)
        return len(data)
    except urllib.error.HTTPError as e:
        return None
    except Exception as e:
        return None

def main():
    root = os.path.abspath(OUT)
    tmp_a = os.path.join(root, ".tmp", "a")   # 原厂
    tmp_b = os.path.join(root, ".tmp", "b")   # mt6768
    os.makedirs(tmp_a, exist_ok=True)
    os.makedirs(tmp_b, exist_ok=True)

    made = 0
    skipped = []
    for path, desc in FILES:
        if desc is None:
            continue
        a = fetch(CEZANNE + path, os.path.join(tmp_a, path))
        b = fetch(MT6768 + path, os.path.join(tmp_b, path))
        if not a or not b:
            skipped.append(path)
            continue

        ta = open(os.path.join(tmp_a, path), encoding="utf-8", errors="ignore").read().splitlines(keepends=True)
        tb = open(os.path.join(tmp_b, path), encoding="utf-8", errors="ignore").read().splitlines(keepends=True)

        if ta == tb:
            skipped.append(path + "  (内容已相同)")
            continue

        diff = list(difflib.unified_diff(
            ta, tb,
            fromfile=f"a/{path}",
            tofile=f"b/{path}",
            n=3,
        ))
        if not diff:
            continue

        name = path.replace("/", "_") + ".patch"
        hdr = [
            f"From: cezanne-bpf-backport <auto@local>",
            f"Subject: [PATCH] BPF backport: {path}",
            "",
            f"回合自同代 MTK 树 mk7x7/android_kernel_xiaomi_mt6768@{SRC_BRANCH}",
            f"目标：让 4.14 内核具备 Android 16/17 所需的 sk_msg / BTF 能力",
            f"说明：{desc}",
            "",
            "---",
            "",
        ]
        with open(os.path.join(root, name), "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(hdr))
            f.writelines(diff)
        made += 1
        print(f"  [生成] {name}  ({len(diff)} 行, {os.path.getsize(os.path.join(root,name))} 字节)")

    shutil.rmtree(os.path.join(root, ".tmp"), ignore_errors=True)
    print(f"\n共生成 {made} 个 patch")
    if skipped:
        print("跳过：")
        for s in skipped:
            print("  -", s)
    if made == 0:
        print("\n警告：没有生成任何 patch。可能两个树内容已一致，")
        print("      或需要改用 cherry-pick 原始提交而非文件级 diff。")
    else:
        print(f"\npatch 目录：{root}")

if __name__ == "__main__":
    main()
