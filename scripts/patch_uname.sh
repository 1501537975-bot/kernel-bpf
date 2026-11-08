#!/usr/bin/env bash
# uname 伪装: 让 A16+ 的 BPF 加载器接受 4.14 内核
#
# 原理 (采用 mt6873-dev 的权威实现, commit 4a452bec7f22):
#   Android 16 Beta 2 起, Google 要求 5.4 以上内核。
#   netbpfload / bpfloader / netd 在加载 BPF 程序前会 uname() 检查主版本号,
#   低于 5.4 就直接拒绝 -> "unsupported kernel" -> 无网络 / SystemUI 崩溃循环。
#
#   官方做法: 在 kernel/sys.c 的 SYSCALL_DEFINE1(newuname, ...) 里,
#   **只对这三个进程** 把 release 字符串改成 "5.4.186"。
#
# 为什么这个方案比"全局改版本串"好:
#   · 用户空间普通进程看到的 uname 仍是真实的 4.14.186-perf-00252-g2f26b5917fd6
#   · 原厂 vendor 的 10 个 .ko 的 vermagic 校验完全不受影响
#     (vermagic 比的是内核的 UTS_RELEASE, 不是 uname 系统调用的返回值)
#   · 改动面极小: 只改 kernel/sys.c 一个函数
#
# 注意: kernel/sys.c 同时是 clone3 patch 的目标文件,
#       所以本脚本必须在 backport_bpf.sh (打 clone3 patch) 之后运行,
#       否则注入的代码会被 patch 覆盖。
#
set -euo pipefail

log()   { echo -e "\033[1;36m[uname]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[ ok ]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[warn]\033[0m $*"; }
die()   { echo -e "\033[1;31m[FAIL]\033[0m $*" >&2; exit 1; }

SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
KERNEL_DIR="${KERNEL_DIR:-kernel}"

log "注入 uname 伪装 (仅对 bpfloader/netbpfload/netd)"

SYSC="$KERNEL_DIR/kernel/sys.c"
[ -f "$SYSC" ] || die "找不到 $SYSC"

if grep -q "FAKE_UNAME_FOR_BPF" "$SYSC"; then
  ok "kernel/sys.c 已含伪装逻辑, 跳过"
else
  python3 "$SCRIPTS_DIR/fake_uname.py" "$SYSC"
  rc=$?
  [ "$rc" -eq 0 ] || die "kernel/sys.c 伪装 patch 失败 (python 退出码 $rc)"
  grep -q "FAKE_UNAME_FOR_BPF" "$SYSC" || die "伪装 patch 未生效 (未找到标记)"
  ok "kernel/sys.c 已注入伪装逻辑"
fi

# ── defconfig 里开启 CONFIG_FAKE_UNAME (仅作标记, 实际逻辑无条件编译) ──
for d in cezanne_user_defconfig cezanne_defconfig; do
  f="$KERNEL_DIR/arch/arm64/configs/$d"
  [ -f "$f" ] || continue
  grep -q "^CONFIG_FAKE_UNAME=y" "$f" || echo "CONFIG_FAKE_UNAME=y" >> "$f"
  ok "$d 已开启 FAKE_UNAME"
done

# ── 验证注入结果 ──
if grep -q 'strcpy(tmp.release, "5.4.186")' "$SYSC"; then
  ok "验证: 伪装代码已就位 (5.4.186)"
else
  die "验证失败: 未找到 strcpy(tmp.release, \"5.4.186\")"
fi

log "注入片段:"
grep -n -A8 "FAKE_UNAME_FOR_BPF" "$SYSC" | head -14 | sed 's/^/      /'
