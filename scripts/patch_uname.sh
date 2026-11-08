#!/usr/bin/env bash
# uname 伪装：让内核对外报告 5.4.186
#
# 原理：
#   A16+ 的 netbpfload / bpfloader / netd 在加载 BPF 程序前会检查
#   uname -r 的主版本号，低于 5.4 就直接拒绝（"unsupported kernel"）。
#   4.14 实际能力够用（BPF 已 backport），只是版本号过不了检查。
#   所以把 uname -r 的 release 字符串改成 5.4.186 即可放行。
#
# 副作用（必须知道）：
#   · 用户空间看到的 uname -r 变成 5.4.186，但实际内核仍是 4.14
#   · 依赖 uname 判断内核版本的 App 可能行为异常（一般无害）
#   · /proc/version 里的内核版本串也会变（部分工具会误判）
#   · 这是「系统侧绕法」，与 tiffanyy 的 system patch bpf 是同一思路的不同实现
#
# 参考：mt6873-dev/android_kernel_xiaomi_mt6885
#       "kernel: Fake uname to 5.4.186 also for netbpfload/bpfloader/netd"
#
set -euo pipefail

log() { echo -e "\033[1;36m[uname]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[ ok ]\033[0m $*"; }

cd "${KERNEL_DIR:-kernel}"

FAKE_VER="${fake_uname_version:-5.4.186}"

# 检查是否已经伪装过
if grep -q "FAKE_UNAME" kernel/Makefile 2>/dev/null; then
  ok "uname 伪装已存在，跳过"
  exit 0
fi

log "注入 uname 伪装（目标 $FAKE_VER）"

# ── 方法：在 init/main.c 里覆盖 UTS_RELEASE ──────────────────
# init/main.c 中 uname_release 来自 init_uts_ns()->uts_release.name，
# 该值由 Makefile 的 UTS_RELEASE 宏生成。内核提供一个官方钩子：
#   #ifdef CONFIG_UTS_NS
#       ... uts_namespace
# 通过自定义宏可以在编译期替换 UTS_RELEASE。
#
# 但更干净的做法是改 Makefile 里的 UTS_RELEASE —— 那会影响 /proc/version，
# 不影响 init/main.c 的 uts_release。后者才是 uname(2) 返回值。
# 所以：两处都改。

# 1) 改 init/main.c：让 uts_release 报 fake 版本
if grep -q "uts_release.name" init/main.c; then
  log "patch init/main.c"
  python3 - << PYEOF
import re
p = "init/main.c"
s = open(p, encoding="utf-8", errors="ignore").read()

marker = "/* FAKE_UNAME_BEGIN */"
if marker in s:
    print("already patched")
    raise SystemExit(0)

# 在 set_uts_ns / init_uts_ns 相关位置注入
# 找到 "uts_release" 初始化点
patterns = [
    (r'(static void __init set_uts_ns\s*\(\)\s*\{)',
     r'\1\n#if defined(CONFIG_FAKE_UNAME)\n\tuts_release.name = "FAKE_UNAME_PLACEHOLDER";\n#endif'),
]

injected = False
for pat, rep in patterns:
    new, n = re.subn(pat, rep, s, count=1)
    if n:
        s = new
        injected = True
        break

if not injected:
    # 兜底：在文件末尾的某个稳定位置插入 init 调用
    # 找 "static int __init populate_rootfs(void)" 之前插入
    anchor = r'(\nstatic int __init populate_rootfs\(void\)\s*\{)'
    helper = r'''
/* FAKE_UNAME_BEGIN */
/* 让 uname(2) 返回伪装版本，以通过 A16+ 的 netbpfload/bpfloader/netd 版本检查 */
static void __init fake_uname_override(void)
{
	uts_release.name = "FAKE_UNAME_PLACEHOLDER";
}
late_initcall(fake_uname_override);
/* FAKE_UNAME_END */
\1'''
    s, n = re.subn(anchor, helper, s, count=1)
    injected = (n > 0)

if injected:
    s = s.replace("FAKE_UNAME_PLACEHOLDER", "$FAKE_VER")
    open(p, "w", encoding="utf-8").write(s)
    print("init/main.c patched")
else:
    print("WARNING: could not patch init/main.c")
PYEOF
  ok "init/main.c 已注入伪装"
else
  warn "init/main.c 中未找到 uts_release，跳过"
fi

# 2) 改 Makefile：让 /proc/version 与 uname 一致
log "patch Makefile (UTS_RELEASE)"
if grep -q "^UTS_RELEASE" Makefile; then
  sed -i.bak "s|^UTS_RELEASE.*|UTS_RELEASE := $FAKE_VER|" Makefile
  rm -f Makefile.bak
  ok "Makefile UTS_RELEASE 已改为 $FAKE_VER"
else
  echo "UTS_RELEASE := $FAKE_VER" >> Makefile
  ok "Makefile 已追加 UTS_RELEASE"
fi

# 3) 定义 CONFIG_FAKE_UNAME 开关
log "定义 CONFIG_FAKE_UNAME"
if ! grep -q "FAKE_UNAME" arch/arm64/Kconfig 2>/dev/null; then
  cat >> arch/arm64/Kconfig << 'EOF'

config FAKE_UNAME
	bool "Fake uname release string"
	help
	  Report a fake kernel release (e.g. 5.4.186) through uname(2),
	  so that Android 16/17 BPF loaders (netbpfload/bpfloader/netd)
	  accept the older 4.14 kernel. The actual kernel stays 4.14.

EOF
  ok "Kconfig 已加入 FAKE_UNAME"
fi

# 4) defconfig 里开启 (原厂树名为 cezanne_user_defconfig, 衍生树可能是 cezanne_defconfig)
for d in cezanne_user_defconfig cezanne_defconfig; do
  f="arch/arm64/configs/$d"
  [ -f "$f" ] || continue
  grep -q "^CONFIG_FAKE_UNAME=y" "$f" || echo "CONFIG_FAKE_UNAME=y" >> "$f"
  ok "$d 已开启 FAKE_UNAME"
done

ok "uname 伪装完成：对外报告 $FAKE_VER（实际仍为 4.14）"
