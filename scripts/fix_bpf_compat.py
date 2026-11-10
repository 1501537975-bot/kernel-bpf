#!/usr/bin/env python3
"""
修正「5.10/5.15 BPF 头文件」回合到 cezanne 4.14.186 后的 API 不兼容。

背景:
  patches/mt6768-bpf/ 来自 mk7x7/android_kernel_xiaomi_mt6768 (4.14.357),
  其中混入了若干 5.10 时代的 API。cezanne 原厂树是 4.14.186, 没有这些
  符号/签名, 导致编译报:
    - 'SHA1_BLOCK_SIZE' undeclared
    - 'struct net' has no member named 'bpf'
    - 'NETNS_BPF_SK_LOOKUP' undeclared
    - too many arguments to function 'dst->ops->negative_advice'

  修正策略是「降级到 4.14 可用的等价写法」, 不删功能:
    - SHA1_BLOCK_SIZE  -> SHA_MESSAGE_BYTES (4.14 本来的名字)
    - net->bpf.run_array[NETNS_BPF_SK_LOOKUP] -> NULL
      (4.14 没有 netns BPF, 也没有 BPF_SK_LOOKUP prog type;
       该分支本就不该命中, 置空等价于「不运行 sk_lookup 程序」)
    - negative_advice(sk, dst) -> 恢复 4.14 单参数实现

用法: python3 fix_bpf_compat.py <KERNEL_DIR>
"""
import os
import re
import sys

KERNEL_DIR = sys.argv[1] if len(sys.argv) > 1 else "."


def apply(rel, rules):
    path = os.path.join(KERNEL_DIR, rel)
    if not os.path.isfile(path):
        print("[skip] %s 不存在" % rel)
        return 0
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()
    before = src
    for label, old, new in rules:
        if old in src:
            src = src.replace(old, new)
            print("[ ok ] %s" % label)
        else:
            print("[ -- ] %s (未找到, 可能已修正)" % label)
    if src != before:
        with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
            f.write(src)
        print("[info] 已写回 %s" % rel)
    return 1 if src != before else 0


FILTER_RULES = [
    (
        "filter.h: SHA1_BLOCK_SIZE -> SHA_MESSAGE_BYTES",
        "sizeof(__be64) + 1, SHA1_BLOCK_SIZE)",
        "sizeof(__be64) + 1, SHA_MESSAGE_BYTES)",
    ),
    (
        "filter.h: 屏蔽 net->bpf / NETNS_BPF_SK_LOOKUP",
        "run_array = rcu_dereference(net->bpf.run_array[NETNS_BPF_SK_LOOKUP]);",
        "run_array = NULL; /* 4.14: no netns BPF, no SK_LOOKUP prog type */",
    ),
    (
        "filter.h: 兜底替换残余 SHA1_BLOCK_SIZE",
        "SHA1_BLOCK_SIZE",
        "SHA_MESSAGE_BYTES",
    ),
]

SOCK_RULES = [
    (
        "sock.h: negative_advice 恢复 4.14 单参数签名",
        "\tif (dst && dst->ops->negative_advice)\n"
        "\t\tdst->ops->negative_advice(sk, dst);",
        "\tif (dst && dst->ops->negative_advice) {\n"
        "\t\tstruct dst_entry *ndst = dst->ops->negative_advice(dst);\n"
        "\t\tif (ndst != dst) {\n"
        "\t\t\trcu_assign_pointer(sk->sk_dst_cache, ndst);\n"
        "\t\t\tsk_tx_queue_clear(sk);\n"
        "\t\t\tsk->sk_dst_pending_confirm = 0;\n"
        "\t\t}\n"
        "\t}",
    ),
]


def main():
    print("=== 4.14 BPF 兼容修正, KERNEL_DIR=%s ===" % KERNEL_DIR)
    apply("include/linux/filter.h", FILTER_RULES)
    apply("include/net/sock.h", SOCK_RULES)

    # 正则兜底: 若 patch 里的 net->bpf 写法与上面略有出入(空格/换行),
    # 仍然把整条赋值降级成 NULL, 避免编译期残留 5.10 结构引用。
    p = os.path.join(KERNEL_DIR, "include/linux/filter.h")
    if os.path.isfile(p):
        with open(p, "r", encoding="utf-8", errors="surrogateescape") as f:
            s = f.read()
        s2, n = re.subn(
            r"run_array\s*=\s*rcu_dereference\(\s*net->bpf[^;]*\);",
            "run_array = NULL; /* 4.14 compat: no netns BPF */", s)
        if n:
            with open(p, "w", encoding="utf-8", errors="surrogateescape") as f:
                f.write(s2)
            print("[ ok ] filter.h: 正则兜底替换 %d 处 net->bpf" % n)
        left = s2.count("net->bpf") + s2.count("NETNS_BPF_SK_LOOKUP") + s2.count("SHA1_BLOCK_SIZE")
        print("[info] filter.h 残余 5.10 符号: %d" % left)
    print("=== 完成 ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
