#!/usr/bin/env python3
"""给 4.14 内核注入最小可用的 sys_clone3 (A17 zygote 硬需求)。

为什么不用 patches/clone3/*.patch:
  那 4 个补丁是从 5.x 树整块搬来的, 混入了 sys_ftruncate 改签名、
  close_range / epoll_pwait2 等无关 syscall, 且没有 clone3 实现本身,
  apply 到 4.14 会造成类型冲突。这里改为定点注入, 只加 4 处:

  1. include/uapi/asm-generic/unistd.h  __NR_clone3 435 + __NR_syscalls 436
  2. include/uapi/linux/sched.h         struct clone_args
  3. kernel/fork.c                     SYSCALL_DEFINE2(clone3) -> _do_fork
  4. arch/arm64/include/asm/unistd.h   __NR_compat_syscalls 435 (保持不变)

映射依据 (本树 4.14.336):
  long _do_fork(unsigned long clone_flags, unsigned long stack_start,
                unsigned long stack_size, int __user *parent_tidptr,
                int __user *child_tidptr, unsigned long tls)
  arm64 直接用 asm-generic/unistd.h 的 __SYSCALL 表, 无 syscall wrapper,
  SYSCALL_DEFINE2 生成的就是 sys_clone3, 与表项匹配。

用法: python3 add_clone3.py <内核树根目录>
"""
import os
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."

# 自带类型定义, 不依赖 __u64 __attribute__((aligned(8))) / 5.x 的 CLONE_LEGACY_FLAGS。
# 用宏守卫, 这样 uapi 头与 fork.c 同时定义也不会冲突。
CLONE_ARGS = """
/* clone3() argument struct (Linux 5.3+ UAPI layout).
 * Android 17 zygote uses flags / exit_signal / stack / stack_size /
 * parent_tid / child_tid / tls; the rest must be zero here.
 */
#ifndef _UAPI_LINUX_CLONE_ARGS_DEFINED
#define _UAPI_LINUX_CLONE_ARGS_DEFINED
struct clone_args {
	__u64 __attribute__((aligned(8))) flags;
	__u64 __attribute__((aligned(8))) pidfd;
	__u64 __attribute__((aligned(8))) child_tid;
	__u64 __attribute__((aligned(8))) parent_tid;
	__u64 __attribute__((aligned(8))) exit_signal;
	__u64 __attribute__((aligned(8))) stack;
	__u64 __attribute__((aligned(8))) stack_size;
	__u64 __attribute__((aligned(8))) tls;
	__u64 __attribute__((aligned(8))) set_tid;
	__u64 __attribute__((aligned(8))) set_tid_size;
	__u64 __attribute__((aligned(8))) cgroup;
};
#endif
"""

CLONE3_IMPL = r"""
/*
 * Minimal sys_clone3 backport for Android 17 zygote.
 * Maps clone_args onto the 4.14 _do_fork() 6-argument signature.
 * Fields we cannot honour (pidfd / set_tid / cgroup) are rejected so
 * bionic can fall back to clone() instead of getting wrong semantics.
 */
#ifndef _UAPI_LINUX_CLONE_ARGS_DEFINED
#define _UAPI_LINUX_CLONE_ARGS_DEFINED
struct clone_args {
	__u64 __attribute__((aligned(8))) flags;
	__u64 __attribute__((aligned(8))) pidfd;
	__u64 __attribute__((aligned(8))) child_tid;
	__u64 __attribute__((aligned(8))) parent_tid;
	__u64 __attribute__((aligned(8))) exit_signal;
	__u64 __attribute__((aligned(8))) stack;
	__u64 __attribute__((aligned(8))) stack_size;
	__u64 __attribute__((aligned(8))) tls;
	__u64 __attribute__((aligned(8))) set_tid;
	__u64 __attribute__((aligned(8))) set_tid_size;
	__u64 __attribute__((aligned(8))) cgroup;
};
#endif

SYSCALL_DEFINE2(clone3, struct clone_args __user *, uargs, size_t, size)
{
	struct clone_args args;
	unsigned long clone_flags;
	int __user *parent_tidptr;
	int __user *child_tidptr;

	if (size < sizeof(args))
		return -EINVAL;
	if (copy_from_user(&args, uargs, sizeof(args)))
		return -EFAULT;
	if (args.pidfd || args.set_tid || args.set_tid_size || args.cgroup)
		return -EINVAL;

	clone_flags = args.flags | (args.exit_signal & CSIGNAL);
	parent_tidptr = (int __user *)(unsigned long)args.parent_tid;
	child_tidptr = (int __user *)(unsigned long)args.child_tid;

	return _do_fork(clone_flags, args.stack, args.stack_size,
			parent_tidptr, child_tidptr, args.tls);
}
"""


def read(rel):
    p = os.path.join(ROOT, rel)
    if not os.path.isfile(p):
        raise SystemExit("[FAIL] 缺少文件: %s" % rel)
    return open(p, "r", encoding="utf-8", errors="surrogateescape").read()


def write(rel, s):
    with open(os.path.join(ROOT, rel), "w",
              encoding="utf-8", errors="surrogateescape") as f:
        f.write(s)


def main():
    # 1) syscall 表
    rel = "include/uapi/asm-generic/unistd.h"
    s = read(rel)
    if "__NR_clone3" in s:
        print("[--] __NR_clone3 已存在")
    else:
        old = "#define __NR_pidfd_open 434\n__SYSCALL(__NR_pidfd_open, sys_pidfd_open)\n"
        if old not in s:
            raise SystemExit("[FAIL] 找不到 pidfd_open 表项, 无法插入")
        s = s.replace(old, old + "#define __NR_clone3 435\n__SYSCALL(__NR_clone3, sys_clone3)\n", 1)
        s = s.replace("#define __NR_syscalls 435", "#define __NR_syscalls 436", 1)
        write(rel, s)
        print("[ok] unistd.h: __NR_clone3=435, __NR_syscalls=436")

    # 2) struct clone_args
    rel = "include/uapi/linux/sched.h"
    s = read(rel)
    # 该 UAPI 头原本没有任何 #include, __u64 不可见; 按 UAPI 惯例补上。
    # asm-offsets.s 会直接包含它, 缺类型会在 prepare0 阶段就编译失败。
    if "#include <linux/types.h>" not in s:
        guard = "#define _UAPI_LINUX_SCHED_H"
        if guard in s:
            s = s.replace(guard, guard + "\n\n#include <linux/types.h>", 1)
        else:
            s = "#include <linux/types.h>\n" + s
        print("[ok] sched.h: 补 #include <linux/types.h>")
    if "struct clone_args" in s:
        print("[--] clone_args 已存在")
    else:
        idx = s.rfind("#endif")
        if idx < 0:
            raise SystemExit("[FAIL] sched.h 找不到 #endif")
        s = s[:idx] + CLONE_ARGS + "\n" + s[idx:]
        print("[ok] sched.h: 注入 struct clone_args")
    write(rel, s)

    # 3) include/linux/syscalls.h 声明
    # 4.14 的 sys_call_table 是静态数组 [nr] = sym, 编译 sys.c 时
    # 必须看到 sys_clone3 的声明, 否则 "undeclared here"。
    rel = "include/linux/syscalls.h"
    s = read(rel)
    if "sys_clone3" in s:
        print("[--] sys_clone3 声明已存在")
    else:
        decl = ("\nstruct clone_args;\n"
                "asmlinkage long sys_clone3(struct clone_args __user *uargs,\n"
                "\t\t\t       size_t size);\n")
        idx = s.rfind("#endif")
        if idx < 0:
            raise SystemExit("[FAIL] syscalls.h 找不到 #endif")
        s = s[:idx] + decl + "\n" + s[idx:]
        write(rel, s)
        print("[ok] syscalls.h: 声明 sys_clone3")

    # 4) SYSCALL_DEFINE2(clone3)
    rel = "kernel/fork.c"
    s = read(rel)
    if "SYSCALL_DEFINE2(clone3" in s:
        print("[--] sys_clone3 实现已存在")
    else:
        # 显式包含 UAPI 头, 保证 struct clone_args / CSIGNAL 在展开时可见
        if "#include <uapi/linux/sched.h>" not in s:
            first = s.find("#include")
            if first >= 0:
                s = s[:first] + "#include <uapi/linux/sched.h>\n" + s[first:]
            else:
                s = "#include <uapi/linux/sched.h>\n" + s
        # 放在 unshare 定义之前; 找不到就追加到文件末尾
        anchor = "SYSCALL_DEFINE1(unshare, unsigned long, unshare_flags)"
        if anchor in s:
            s = s.replace(anchor, CLONE3_IMPL + "\n" + anchor, 1)
        else:
            s += "\n" + CLONE3_IMPL + "\n"
        write(rel, s)
        print("[ok] fork.c: 注入 SYSCALL_DEFINE2(clone3)")

    print("[done] clone3 注入完成")
    return 0


if __name__ == "__main__":
    sys.exit(main())
