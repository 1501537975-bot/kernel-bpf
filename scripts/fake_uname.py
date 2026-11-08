#!/usr/bin/env python3
"""
给内核的 newuname 系统调用加"按进程名伪装版本号"的逻辑。

采用 mt6873-dev 的权威实现 (commit 4a452bec7f22):
    Fake uname to 5.4.186 also for netbpfload/bpfloader/netd

背景:
    Android 16 Beta 2 起 Google 要求 5.4+ 内核。
    netbpfload / bpfloader / netd 在加载 BPF 程序前会 uname() 检查主版本号,
    低于 5.4 就拒绝 -> "unsupported kernel" -> 无网络 / SystemUI 崩溃循环。

为什么只对这三个进程伪装:
    · 普通进程看到的 uname 仍是真实版本串
    · 原厂 vendor .ko 的 vermagic 校验不受影响
      (vermagic 比的是内核 UTS_RELEASE, 不是 uname() 的返回值)

用法: python3 fake_uname.py <kernel/sys.c>
"""
import sys


def main():
    if len(sys.argv) < 2:
        print("用法: fake_uname.py <kernel/sys.c>", file=sys.stderr)
        return 2

    path = sys.argv[1]
    try:
        with open(path, encoding="utf-8", errors="ignore") as f:
            src = f.read()
    except OSError as e:
        print(f"ERROR: 读不到 {path}: {e}", file=sys.stderr)
        return 1

    if "FAKE_UNAME_FOR_BPF" in src:
        print("  already patched")
        return 0

    lines = src.split("\n")

    # 定位 SYSCALL_DEFINE1(newuname, ...)
    start = None
    for i, line in enumerate(lines):
        if "SYSCALL_DEFINE1(newuname" in line:
            start = i
            break
    if start is None:
        print("ERROR: 找不到 SYSCALL_DEFINE1(newuname", file=sys.stderr)
        return 1

    # 在该函数内定位 memcpy(&tmp, utsname(), sizeof(tmp));
    anchor = None
    for i in range(start, min(start + 80, len(lines))):
        if "memcpy(&tmp, utsname(), sizeof(tmp));" in lines[i]:
            anchor = i
            break
    if anchor is None:
        print("ERROR: 找不到 memcpy(&tmp, utsname(), ...)", file=sys.stderr)
        return 1

    block = [
        "",
        "\t/* FAKE_UNAME_FOR_BPF: A16+ 的 netbpfload/bpfloader/netd 会检查",
        "\t * uname -r 的主版本号, 低于 5.4 就拒绝加载 BPF 程序。",
        "\t * 这里只对这三个进程伪装版本号, 其他进程看到的仍是真实版本串,",
        "\t * 不影响原厂 vendor .ko 的 vermagic (符号 CRC) 校验。",
        "\t * 参考: mt6873-dev commit 4a452bec7f22",
        "\t */",
        "\tif (!strncmp(current->comm, \"bpfloader\", 9) ||",
        "\t    !strncmp(current->comm, \"netbpfload\", 10) ||",
        "\t    !strncmp(current->comm, \"netd\", 4)) {",
        "\t\tstrcpy(tmp.release, \"5.4.186\");",
        "\t\tpr_debug(\"fake uname: %s release=%s\\n\",",
        "\t\t\t current->comm, tmp.release);",
        "\t}",
    ]
    lines[anchor + 1:anchor + 1] = block
    out = "\n".join(lines)

    # strncmp / strcpy 需要 <linux/string.h>
    if "#include <linux/string.h>" not in out:
        for inc in ("#include <linux/syscalls.h>", "#include <linux/kernel.h>"):
            if inc in out:
                out = out.replace(inc, inc + "\n#include <linux/string.h>", 1)
                break

    try:
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(out)
    except OSError as e:
        print(f"ERROR: 写不了 {path}: {e}", file=sys.stderr)
        return 1

    print(f"  patched OK (inserted after line {anchor + 1})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
