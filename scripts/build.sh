#!/usr/bin/env bash
# cezanne 内核 BPF backport 构建脚本
#
# 目标：在 4.14.186 基础上补齐 A16/A17 所需的 BPF / sys_clone3 / BTF 能力，
#       同时保留 EROFS 驱动，使 cezanne 可运行 Android 16/17 移植包。
#
# 输入参数（环境变量）：
#   enable_erofs   yes/no   是否移植 fs/erofs        （默认 yes）
#   enable_bpf     yes/no   是否回合 5.10 BPF + clone3 （默认 yes）
#   enable_uname   yes/no   是否伪装 uname 5.4.186   （默认 yes）
#   enable_ksu     yes/no   是否内置 KernelSU         （默认 no）
#   localversion   str      内核版本后缀（默认保持原厂，不改）
#
# 关键不变量（改了就加载不了原厂 vendor 的 10 个 .ko）：
#   LOCALVERSION 必须等于 -perf-00252-g2f26b5917fd6

set -euo pipefail

# ── 真值归一化 ────────────────────────────────────────
# GitHub Actions 的 boolean input 传进来是字符串 "true"/"false",
# 而本地默认用的是 "yes"/"no"。两种都必须认, 否则
#   if [ "$ENABLE_BPF" = "yes" ]  ← 永远不成立, 关键步骤全被跳过!
# (踩过这个坑: 前几轮实际编译的是没打任何 patch 的原厂内核)
_truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|y|yes|true|on)  return 0 ;;
    *)                return 1 ;;
  esac
}

ENABLE_EROFS="${enable_erofs:-yes}"
ENABLE_BPF="${enable_bpf:-yes}"
ENABLE_UNAME="${enable_uname:-yes}"
ENABLE_KSU="${enable_ksu:-no}"

# 归一化到 yes/no
_truthy "$ENABLE_EROFS" && ENABLE_EROFS=yes || ENABLE_EROFS=no
_truthy "$ENABLE_BPF"   && ENABLE_BPF=yes   || ENABLE_BPF=no
_truthy "$ENABLE_UNAME" && ENABLE_UNAME=yes || ENABLE_UNAME=no
_truthy "$ENABLE_KSU"   && ENABLE_KSU=yes   || ENABLE_KSU=no
LOCALVERSION="${localversion:--perf-00252-g2f26b5917fd6}"

# ── 路径统一绝对化 ──────────────────────────────────────
# 本脚本会在多个目录间 cd (buildrepo -> kernel -> buildrepo),
# 相对路径会在 cd 之后失效。所有外部传入的路径在此一次性转成绝对路径。
_abspath() {
  local t="$1" d b
  case "$t" in
    /*|[A-Za-z]:[\\/]*)
      # 已是绝对路径 —— 用 realpath 归一化 (去掉 .. 与重复斜杠)
      if command -v realpath >/dev/null 2>&1; then
        realpath -m "$t" 2>/dev/null && return 0
      fi
      printf '%s\n' "$t"
      return 0
      ;;
  esac
  d="$(dirname "$t")"; b="$(basename "$t")"
  # 目标可能还不存在 (如 out/), 所以只 realpath 父目录
  d="$(cd "$d" 2>/dev/null && pwd)" || d="$PWD/$d"
  printf '%s\n' "${d%/}/$b"
}

# 脚本自身所在目录 = <repo>/scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

KERNEL_DIR="$(_abspath "${KERNEL_DIR:-$REPO_DIR/../kernel}")"
OUT="$(_abspath "${OUT:-$REPO_DIR/../out}")"
SCRIPTS_DIR="$(_abspath "${SCRIPTS_DIR:-$SCRIPT_DIR}")"
PATCH_DIR="$(_abspath "${PATCH_DIR:-$REPO_DIR/patches}")"
EROFS_TREE="$(_abspath "${EROFS_TREE:-$PATCH_DIR/erofs}")"
# 必须 export —— 子脚本 (fetch_erofs.sh / backport_bpf.sh / pack_anykernel.sh)
# 靠环境变量继承这些路径, 否则 set -u 下直接 unbound variable 退出
export SCRIPTS_DIR PATCH_DIR EROFS_TREE KERNEL_DIR OUT

log_path() {
  echo "    KERNEL_DIR : $KERNEL_DIR"
  echo "    OUT        : $OUT"
  echo "    SCRIPTS_DIR: $SCRIPTS_DIR"
  echo "    PATCH_DIR  : $PATCH_DIR"
  echo "    EROFS_TREE : $EROFS_TREE"
}
export KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-Sat Nov  8 00:00:00 UTC 2026}"

# ★ 原厂模块 vermagic 必须精确匹配这个字符串 (实测自 /vendor/lib/modules/*.ko)
EXPECT_RELEASE="4.14.186-perf-00252-g2f26b5917fd6"

log()  { echo -e "\033[1;36m[build]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[ ok ]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
die()  { echo -e "\033[1;31m[FAIL]\033[0m $*" >&2; exit 1; }

log "==== cezanne BPF 内核构建 ===="
log "erofs=$ENABLE_EROFS  bpf=$ENABLE_BPF  uname=$ENABLE_UNAME  ksu=$ENABLE_KSU"
log "localversion=$LOCALVERSION"
log_path

# ─────────────────────────────────────────────────────────────
# 1. 交叉编译工具链
# ─────────────────────────────────────────────────────────────
log "[1/7] 准备交叉编译工具链"
export ARCH=arm64
export SUBARCH=arm64

# ── 探测可用的交叉编译器 ──────────────────────────────────
# 原厂 MTK 树用的是 aarch64-linux-androidkernel- (AOSP 预编译 clang),
# 但 GitHub Actions 上没有。Ubuntu 的 gcc-aarch64-linux-gnu / clang 都能编 4.14。
# 依次尝试, 谁能用上谁。
CROSS=""
CC_CMD=""
LD_CMD=""

if [ -n "${CLANG_PREBUILT_BIN:-}" ] && [ -x "${CLANG_PREBUILT_BIN}/clang" ]; then
  export PATH="${CLANG_PREBUILT_BIN}:$PATH"
  CROSS="aarch64-linux-android-"
  CC_CMD="clang"
  LD_CMD="ld.lld"
  ok "使用内核自带 clang: $(clang --version | head -1)"
elif command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
  CROSS="aarch64-linux-gnu-"
  CC_CMD="aarch64-linux-gnu-gcc"
  # 注意: GCC 路径下不能用 ld.lld!
  # 内核的 prepare-compiler-check 会用 $(CC) ... -c 试编译来探测
  # -fstack-protector-strong 是否可用 (Makefile:1284), 而 cc-option 里
  # 带的是 $(LD) —— GCC 配 lld 会让这个探测失败:
  #   "Cannot use CONFIG_CC_STACKPROTECTOR_STRONG: -fstack-protector-strong
  #    not supported by compiler"
  # 用 GCC 自带的 ld, 它支持 -fstack-protector-strong。
  LD_CMD="aarch64-linux-gnu-ld"
  ok "使用 GCC 交叉工具链: $($CC_CMD --version | head -1) (ld=$LD_CMD)"
elif command -v clang >/dev/null 2>&1; then
  CROSS="aarch64-linux-gnu-"
  CC_CMD="clang --target=aarch64-linux-gnu"
  LD_CMD="ld.lld"
  ok "使用 clang 交叉: $(clang --version | head -1)"
else
  die "找不到可用的交叉编译器 (需要 gcc-aarch64-linux-gnu 或 clang)"
fi

export CROSS_COMPILE="$CROSS"
export CC="$CC_CMD"
export LD="$LD_CMD"
export NM=llvm-nm
export OBJCOPY=llvm-objcopy
export OBJDUMP=llvm-objdump
export STRIP=llvm-strip
export HOSTCC=gcc
export HOSTCXX=g++
export CLANG_TRIPLE=aarch64-linux-gnu-

# ── ccache (编译缓存) ─────────────────────────────────────
# ★ 完整编译一轮要 80 分钟, ccache 命中后只要 10 分钟上下。
#   第 31 轮开始 CI 会缓存 ~/.cache/ccache, 后续改一行代码重编极快。
if command -v ccache >/dev/null 2>&1; then
  export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache}"
  export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-5G}"
  mkdir -p "$CCACHE_DIR"
  # ccache 需要包在编译器外面: aarch64-linux-gnu-gcc -> ccache aarch64-linux-gnu-gcc
  case "$CC_CMD" in
    *clang*)
      export CC="ccache $CC_CMD"
      ;;
    *)
      export CC="ccache ${CROSS}gcc"
      ;;
  esac
  ok "启用 ccache (缓存目录 $CCACHE_DIR, 上限 $CCACHE_MAXSIZE)"
else
  warn "未安装 ccache -> 本轮会完整编译 (约 80 分钟)"
fi

# 用 clang 时才启用 LLVM_IAS (集成汇编器), GCC 下必须关
if echo "$CC_CMD" | grep -q clang; then
  export LLVM_IAS=1
else
  export LLVM_IAS=0
fi

# GCC 对 K&R 式函数声明 (如 `static char *hw_item_dump()`) 会报
# -Werror=strict-prototypes, 而原厂内核是 clang 编译的 (clang 不报)。
#
# 根因: 4.14 的 Makefile 第 420 行自带
#   KBUILD_CFLAGS := -Wall -Wundef -Wstrict-prototypes ...
# 解决: 通过 make 的 CFLAGS_KERNEL 变量追加覆盖标志。
#   scripts/Makefile.build:124 用的是
#     $(KBUILD_CFLAGS_KERNEL) $(CFLAGS_KERNEL)
#   CFLAGS_KERNEL 追加在内核标志之后 -> 覆盖 -Wstrict-prototypes。
# 注意: 4.14 不认 KCFLAGS (那是 5.x 才有的), 别用。
# 4.14 的 Makefile 在 936-948 行用 $(call cc-option,...) 加了这些 -Werror:
#   -Werror-implicit-int / -Werror-strict-prototypes / -Werror-date-time
#   -Werror-incompatible-pointer-types / -Werror-designated-init
#   以及 422 行的 -Werror-implicit-function-declaration
# 原厂用 clang 编译 (对 format 字符串等更宽容), 换 GCC 后这些老代码会大量
# 报 "all warnings being treated as errors"。
# CFLAGS_KERNEL 追加在 KBUILD_CFLAGS 之后 -> 可以后置覆盖。
# ★ 必须写成单行! 双引号内的 "反斜杠+换行" 是字面量, 不会被 bash 续行,
#   传给 make 的就是一个带反斜杠和换行的乱码 -> 里面的 flag 全部失效
#   (2026-11-08 实测: -fgnu89-inline 这么写就是不生效)
EXTRA_CFLAGS="-fgnu89-inline -Wno-strict-prototypes -Wno-old-style-definition -Wno-implicit-fallthrough -Wno-maybe-uninitialized -Wno-unused-but-set-variable -Wno-unused-function -Wno-unused-variable -Wno-sign-compare -Wno-misleading-indentation -Wno-address-of-packed-member -Wno-pointer-arith -Wno-attribute-alias -Wno-array-bounds -Wno-stringop-overflow -Wno-stringop-overread -Wno-format-overflow -Wno-format-truncation -Wno-format-security -Wno-incompatible-pointer-types -Wno-int-conversion -Wno-implicit-int -Wno-implicit-function-declaration -Wno-return-type -Wno-date-time -Wno-designated-init -Wno-missing-field-initializers -Wno-type-limits -Wno-tautological-compare -Wno-cpp -Wno-error"
export EXTRA_CFLAGS

# 说明:
#   -fgnu89-inline —— MTK 内核大量使用 "inline xxx(); / extern inline xxx() {...}" 模式
#     (如 include/linux/keyslot-manager.h 的 ksm_flock)。这是 C89 的 inline 语义,
#     clang 一直容忍, 但 GCC 5+ 用更严格的 C99 语义 ->
#       error: inlining failed in call to 'always_inline' 'ksm_flock':
#              function body not available
#     -fgnu89-inline 恢复 C89 语义, 这是 MTK/clang 内核用 GCC 编译的标准做法。
#   去掉 -Wno-dangling-pointer / -Wno-compare-distinct-pointer-types
#     (GCC 11 不认识这两个选项, 只会刷 "unrecognized command-line option" 噪音)

# 编译器自检 —— 前缀与实际二进制不匹配是 4.14 编译最常见的坑
log "    编译器自检..."
if ! command -v "${CROSS}gcc" >/dev/null 2>&1 && ! echo "$CC_CMD" | grep -q "^clang"; then
  die "编译器前缀与实际不匹配: CROSS_COMPILE=$CROSS 但找不到 ${CROSS}gcc"
fi
"$CC_CMD" --version 2>/dev/null | head -1 | sed 's/^/      /' || true

# BPF 需要 pahole 生成 BTF
if command -v pahole >/dev/null 2>&1; then
  ok "pahole: $(pahole --version 2>&1 | head -1)"
else
  warn "未安装 pahole -> CONFIG_DEBUG_INFO_BTF 无法生效 (A16+ 需要 BTF!)"
fi

# ─────────────────────────────────────────────────────────────
# 2. 源码准备
# ─────────────────────────────────────────────────────────────
log "[2/7] 准备内核源码"
# 注意: 不在这里 cd, 各子脚本自己 cd 进内核树 (见 backport_bpf.sh / fetch_erofs.sh)
git config --global --add safe.directory "$KERNEL_DIR" 2>/dev/null || true

# ─────────────────────────────────────────────────────────────
# 3. EROFS 回合（主线 4.19 才有，4.14 缺失）
# ─────────────────────────────────────────────────────────────
if [ "$ENABLE_EROFS" = "yes" ]; then
  log "[3/7] 回合 fs/erofs"
  if [ -d fs/erofs ] && grep -q "CONFIG_EROFS_FS=y" .config 2>/dev/null; then
    ok "erofs 已存在，跳过"
  else
    # EROFS 也是**可选**: 
    #   实测手机当前跑的 A16 (SDK36) 的 /system 和 /vendor 都是 ext4, 0 个 erofs 挂载
    #   -> Android 14/15/16 的 GSI 镜像基本都是 ext4, EROFS 并非必需
    #   -> 而且 mt6768/mt6873-dev 的 fs/erofs 代码从未真正编译过
    #      (它们的树没开 CONFIG_EROFS_FS), 存在上游笔误与配套头文件缺失
    if bash "$SCRIPTS_DIR/fetch_erofs.sh"; then
      ok "EROFS 移植完成"
    else
      warn "EROFS 移植未成功 -> 继续构建 (ext4 镜像不受影响)"
    fi
    # config 不在这里设置 —— 此时 .config 还没生成 (defconfig 在第 7 步),
    # EROFS 的 config 统一由后面的 "设置内核选项" 段处理。
    ok "erofs 源码就绪, config 稍后统一设置"
  fi
else
  log "[3/7] 跳过 erofs"
fi

# ─────────────────────────────────────────────────────────────
# 4. BPF backport（5.10 → 4.14）
#    这是 Android 16/17 的硬门槛：netbpfload / bpfloader / netd 会检查
#    内核提供的 BTF 与 BPF 特性，缺了就炸 bpfloader（网络过滤器失效）
# ─────────────────────────────────────────────────────────────
if [ "$ENABLE_BPF" = "yes" ]; then
  log "[4/7] 回合 5.10 BPF + sys_clone3"
  # BPF 回合是**可选增强**:
  #   A14 (ColorOS 14 / OneUI 6 / OriginOS 4) 最低要求就是 4.14, 原厂 BPF 够用,
  #   不需要 BPF 回合 -> 失败不该阻断整个构建。
  #   A16/A17 才需要 4.16+ 的 socket filter, 那时再单独攻。
  if bash "$SCRIPTS_DIR/backport_bpf.sh"; then
    ok "BPF 回合完成"
  else
    warn "BPF 回合未完全成功 (不影响 A14 档; A16/A17 需要它)"
    warn "继续构建 -- 产出的内核可用于 ColorOS 14 / OneUI 6 / OriginOS 4"
  fi
  # BPF 需要这些内核选项
  # config 稍后统一设置 (此时 .config 尚未生成)
  ok "BPF 源码回合完成, config 稍后统一设置"
else
  log "[4/7] 跳过 BPF（注意：A16/A17 需要 BPF）"
fi

# ─────────────────────────────────────────────────────────────
# 5. uname 伪装（让 netbpfload/bpfloader/netd 的版本检查放行）
# ─────────────────────────────────────────────────────────────
if [ "$ENABLE_UNAME" = "yes" ]; then
  log "[5/7] 伪装 uname 为 5.4.186"
  bash "$SCRIPTS_DIR/patch_uname.sh" || die "uname 伪装失败"
  ok "uname 伪装完成"
else
  log "[5/7] 跳过 uname 伪装"
fi

# ─────────────────────────────────────────────────────────────
# 6. KernelSU（可选）
# ─────────────────────────────────────────────────────────────
if [ "$ENABLE_KSU" = "yes" ]; then
  log "[6/7] 集成 KernelSU"
  bash "$SCRIPTS_DIR/setup_ksu.sh" || warn "KernelSU 集成失败，继续无 root 构建"
else
  log "[6/7] 跳过 KernelSU"
fi

# ─────────────────────────────────────────────────────────────
# 7. 编译
# ─────────────────────────────────────────────────────────────
log "[7/7] 编译内核"
cd "$KERNEL_DIR"

# 绝对化 OUT, 避免 cd 之后相对路径错位
# (make O=../$OUT 输出到 buildrepo/out, 而后续 scripts/config --file $OUT/.config
#  必须在同一位置, 否则会写到 kernel/out/.config 而 config 根本不生效)
mkdir -p "$OUT"
OUT_ABS="$OUT"

make mrproper || true

# 原厂树 (MiCode cezanne-r-oss) 的 defconfig 名为 cezanne_user_defconfig,
# 但部分衍生树用 cezanne_defconfig —— 两者都探测, 取实际存在的一个
DEFCONFIG=""
for d in cezanne_user_defconfig cezanne_defconfig cezanne_defconfig_gki; do
  if [ -f "arch/arm64/configs/$d" ]; then DEFCONFIG="$d"; break; fi
done
[ -n "$DEFCONFIG" ] || die "在 arch/arm64/configs/ 下找不到 cezanne 的 defconfig (实际内容: $(ls arch/arm64/configs/ 2>/dev/null | tr '\n' ' '))"
log "    使用 defconfig: $DEFCONFIG"

make O="$OUT" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
     CFLAGS_KERNEL="$EXTRA_CFLAGS" \
     CC="$CC" LD="$LD" HOSTCC="$HOSTCC" \
     LLVM_IAS="$LLVM_IAS" LOCALVERSION="$LOCALVERSION" \
     "$DEFCONFIG" || die "defconfig 失败"

# ── 彻底移除内核里的 -Werror ─────────────────────────────
# 原厂内核用 clang 编译 (clang 对 K&R 原型、format 字符串等更宽容),
# 换 GCC 交叉编译时老代码会大量触发:
#   error: function declaration isn't a prototype [-Werror=strict-prototypes]
#   error: format '%x' expects a matching 'unsigned int' argument [-Werror=format=]
#   cc1: all warnings being treated as errors
#
# 这些 -Werror 的来源不止一处 (顶层 Makefile 936-948 的 $(call cc-option,-Werror=...),
# 以及 scripts/Kbuild.include 的 cc-disable-warning 探测机制), 单靠追加
# -Wno-xxx 标志不能保证覆盖所有情况 —— 顺序一旦变化就又 fatal。
# 最稳的做法: 直接把内核 Makefile 里的 -Werror 去掉, 全部警告降级为警告。
log "    移除内核源码中的 -Werror (GCC 比 clang 严格)..."
if [ -f "$KERNEL_DIR/Makefile" ]; then
  BEFORE=$(grep -c -- '-Werror' "$KERNEL_DIR/Makefile" 2>/dev/null || echo 0)
  # 内核 Makefile 里所有 -Werror 形式 (已实测共 7 种):
  #   -Werror-implicit-function-declaration   (短横线型, 第422行)
  #   -Werror=date-time / =designated-init / =implicit-int
  #   -Werror=incompatible-pointer-types / =strict-prototypes
  #   -Werror=unknown-warning-option          (clang 专用, 第498行)
  # 全部降级为 -Wno-error 形式
  # 注意: 短横线型的 -Werror-implicit-function-declaration 不能改成
  # "-Wno-error-implicit-function-declaration" —— GCC 不认这个选项名, 会报
  #   error: unrecognized command-line option '-Wno-error-implicit-function-declaration'
  # 正确写法是直接关掉该警告: -Wno-implicit-function-declaration
  sed -i 's/-Werror-implicit-function-declaration/-Wno-implicit-function-declaration/g' "$KERNEL_DIR/Makefile"
  sed -i 's/-Werror=date-time/-Wno-error=date-time/g' "$KERNEL_DIR/Makefile"
  sed -i 's/-Werror=designated-init/-Wno-error=designated-init/g' "$KERNEL_DIR/Makefile"
  sed -i 's/-Werror=implicit-int/-Wno-error=implicit-int/g' "$KERNEL_DIR/Makefile"
  sed -i 's/-Werror=incompatible-pointer-types/-Wno-error=incompatible-pointer-types/g' "$KERNEL_DIR/Makefile"
  sed -i 's/-Werror=strict-prototypes/-Wno-error=strict-prototypes/g' "$KERNEL_DIR/Makefile"
  sed -i 's/-Werror=unknown-warning-option/-Wno-error=unknown-warning-option/g' "$KERNEL_DIR/Makefile"
  AFTER=$(grep -c -- '-Werror' "$KERNEL_DIR/Makefile" 2>/dev/null || echo 0)
  ok "顶层 Makefile: -Werror 出现次数 $BEFORE -> $AFTER"
  [ "$AFTER" != "0" ] && grep -n -- '-Werror' "$KERNEL_DIR/Makefile" | head -5 | sed 's/^/      /' || true
fi
# scripts/Kbuild.include 的 cc-disable-warning 用 -Werror 探测支持性,
# 那里保持原样 (只是探测, 不影响编译), 但把 -Werror 探测改为不致命
#
# ★ grep 无匹配返回 1, 在 set -e 下会杀掉整个脚本 —— 必须 || true
if [ -f "$KERNEL_DIR/scripts/Kbuild.include" ]; then
  grep -n "cc-disable-warning" "$KERNEL_DIR/scripts/Kbuild.include" 2>/dev/null | head -2 | sed 's/^/      /' || true
fi

# ── 统一设置 config (必须在此处: defconfig 之后 .config 才存在) ──
log "    设置内核选项..."

# ① MODVERSIONS: 原厂 defconfig 里没有 default y (默认 n),
#    但原厂 .ko 的 vermagic 明确带 modversions -> 必须开,
#    否则原厂 10 个 .ko 全部 "disagrees about version of symbol"
"$KERNEL_DIR/scripts/config" --file "$OUT_ABS/.config" --enable CONFIG_MODVERSIONS

# ② FHANDLE: 原厂 defconfig 显式关闭, 而 A16+ 的 BPF 需要它
"$KERNEL_DIR/scripts/config" --file "$OUT_ABS/.config" --enable CONFIG_FHANDLE
"$KERNEL_DIR/scripts/config" --file "$OUT_ABS/.config" --enable CONFIG_INDIRECT_FD

# ③ EROFS: ★必需 (2026-11-09 实测)
#    K40G A16/A17 移植包的 system/product/system_ext/vendor **全部是 EROFS 格式**
#    (magic 0xE0F5E1E2), 原厂内核没这个驱动 -> 挂载 system 直接失败 -> 卡开机。
#    ★ 但实测这些镜像 **没有压缩** (feature_compat=0x07, 无 COMPRESS 位),
#      所以 **不需要 CONFIG_EROFS_FS_ZIP** —— 省掉 LZ4 解压那一整套依赖, 编译风险大降。
"$KERNEL_DIR/scripts/config" --file "$OUT_ABS/.config" \
  --enable CONFIG_EROFS_FS \
  --enable CONFIG_EROFS_FS_XATTR \
  --disable CONFIG_EROFS_FS_ZIP \
  --enable CONFIG_LZ4 \
  --enable CONFIG_LZ4_DECOMPRESS \
  --enable CONFIG_CRYPTO \
  --enable CONFIG_CRYPTO_LZ4

# ③-b 关闭 STRONG 栈保护 (规避 prepare-compiler-check 的探测失败)
#
# 原因: 4.14 的 scripts/Kbuild.include:115 硬编码了
#     __cc-option = $(call try-run,$(1) -Werror $(2) $(3) -c -x c /dev/null ...)
# 这个 -Werror 是命令行直接加的, 改 Makefile 改不到它。
# 于是 cc-option 探测 -fstack-protector-strong 时带着全局 -Werror,
# 任何警告都致命 -> 探测返回空 ->
#     "Cannot use CONFIG_CC_STACKPROTECTOR_STRONG:
#      -fstack-protector-strong not supported by compiler"
#
# 栈保护只是安全加固项, 关掉不影响功能 (内核会回落到 REGULAR),
# 而原厂 .ko 不依赖它。直接关掉 STRONG 最省事。
# 栈保护的两个变体都要关掉:
#   CONFIG_CC_STACKPROTECTOR_STRONG  -> -fstack-protector-strong
#   CONFIG_CC_STACKPROTECTOR_REGULAR -> -fstack-protector
# prepare-compiler-check 通过 cc-option 试编译探测它们, 而 scripts/Kbuild.include:115
# 的 __cc-option 硬编码了 -Werror, 探测必然失败:
#   Cannot use CONFIG_CC_STACKPROTECTOR_STRONG:  -fstack-protector-strong not supported
#   Cannot use CONFIG_CC_STACKPROTECTOR_REGULAR: -fstack-protector not supported
# 两个都关 -> 内核走 "Force off for distro compilers" 分支, 编译正常。
# 栈保护只是安全加固, 与 vendor .ko 的 vermagic 无关, 关掉不影响加载。
"$KERNEL_DIR/scripts/config" --file "$OUT_ABS/.config" --disable CONFIG_CC_STACKPROTECTOR_STRONG
"$KERNEL_DIR/scripts/config" --file "$OUT_ABS/.config" --disable CONFIG_CC_STACKPROTECTOR_REGULAR
# 还要关掉总开关 CONFIG_CC_STACKPROTECTOR:
#   Makefile: "ifdef CONFIG_CC_STACKPROTECTOR" -> stackp-check ->
#   scripts/gcc-<arch>-has-stack-protector.sh, 那也是 GCC 专有脚本, clang 树里没有
"$KERNEL_DIR/scripts/config" --file "$OUT_ABS/.config" --disable CONFIG_CC_STACKPROTECTOR
ok "已关闭栈保护 (STRONG/REGULAR/总开关), 规避 compiler-check 探测失败"

# ④ BPF + BTF: 本机内核已自带 BPF 主体, 但缺 BTF (A16+ 的 bpfloader 需要)
"$KERNEL_DIR/scripts/config" --file "$OUT_ABS/.config" \
  --enable CONFIG_BPF_SYSCALL \
  --enable CONFIG_BPF_JIT \
  --enable CONFIG_BPF_JIT_ALWAYS_ON \
  --enable CONFIG_BPF_EVENTS \
  --enable CONFIG_DEBUG_INFO \
  --enable CONFIG_DEBUG_INFO_BTF \
  --enable CONFIG_PAHOLE_VERSION \
  --enable CONFIG_CGROUP_BPF \
  --enable CONFIG_CGROUP_FREEZER \
  --enable CONFIG_BPF_STREAM_PARSER

# ③-c 关掉 CONFIG_BLK_INLINE_ENCRYPTION
#     MTK 的这个特性用 C99 inline 语义定义了两个导出符号:
#       block/keyslot-manager.c:684  inline void ksm_flock(...)  + EXPORT_SYMBOL_GPL
#       block/blk-crypto.c          inline void blk_crypto_flock(...) + EXPORT_SYMBOL_GPL
#     clang 接受, GCC 5+ 拒绝:
#       error: inlining failed in call to 'always_inline' 'ksm_flock':
#              function body not available
#     这功能是 UFS 硬件内联加密 (hardware-wrapped keys), 本机用不到,
#     关掉后 block/Makefile 的 obj-$(CONFIG_BLK_INLINE_ENCRYPTION) 不再编译这两个文件。
"$KERNEL_DIR/scripts/config" --file "$OUT_ABS/.config" \
  --disable CONFIG_BLK_INLINE_ENCRYPTION \
  --disable CONFIG_BLK_INLINE_ENCRYPTION_FALLBACK
ok "已关闭 CONFIG_BLK_INLINE_ENCRYPTION (规避 GCC inline 语义冲突)"

# ③-d 豁免 MTK 充电驱动的 -mgeneral-regs-only
#     drivers/power/supply/ti_cezanne/bq2597x_charger.c 用 kernel_neon_begin()/
#     kernel_neon_end() 做定点浮点换算, 但 arm64 内核给所有文件默认加
#     -mgeneral-regs-only (禁止内核态用 FP/SIMD), clang 容忍而 GCC 报错:
#       error: '-mgeneral-regs-only' is incompatible with the use of
#              floating-point types
#     内核标准豁免机制: CFLAGS_REMOVE_<file>.o
CHG="$KERNEL_DIR/drivers/power/supply/ti_cezanne/Makefile"
if [ -f "$CHG" ] && ! grep -q "CFLAGS_REMOVE_bq2597x_charger.o" "$CHG"; then
  cat >> "$CHG" << 'CHGEOF'

# cezanne: 该驱动用 kernel_neon_begin() 做浮点换算, 需移除 -mgeneral-regs-only
CFLAGS_REMOVE_bq2597x_charger.o += -mgeneral-regs-only
CFLAGS_REMOVE_pd_policy_manager.o += -mgeneral-regs-only
CFLAGS_REMOVE_cp_qc30.o += -mgeneral-regs-only
CHGEOF
  ok "ti_cezanne/Makefile 已豁免 -mgeneral-regs-only"
fi

# ③-e 修正 MTK 头文件里多余的 "extern inline" 声明
#     GCC 5+ 用严格 C99 inline 语义: 头文件写 "extern inline int f(...);"
#     而 .c 里是普通定义 (为了 EXPORT_SYMBOL) 时, GCC 会尝试内联却找不到函数体 ->
#       error: inlining failed in call to 'always_inline' 'f':
#              function body not available
#     典型位置: include/linux/keyslot-manager.h、drivers/misc/mediatek/typec/*/inc/tcpci_typec.h
#     脚本只删除 "inline" 关键字本身, 其余字节原样保留。
if [ -f "$SCRIPTS_DIR/fix_extern_inline.py" ] && command -v python3 >/dev/null 2>&1; then
  log "    修正 extern inline 声明 (GCC inline 语义)"
  if python3 "$SCRIPTS_DIR/fix_extern_inline.py" "$KERNEL_DIR" 2>&1 | tail -20 | sed 's/^/      /'; then
    ok "extern inline 修正完成"
  else
    warn "extern inline 修正脚本执行异常"
  fi
fi

# ④-b net/core/Makefile 必须登记 sock_map.o
#     mt6768 把 sockmap 实现从 kernel/bpf/sockmap.c 移到了 net/core/sock_map.c,
#     而原厂的 net/core/Makefile 没有这条规则 -> 不补会链接失败
NETMK="$KERNEL_DIR/net/core/Makefile"
if [ -f "$NETMK" ] && ! grep -q "sock_map.o" "$NETMK"; then
  if grep -q "^obj-" "$NETMK"; then
    sed -i '0,/^obj-/s//obj-$(CONFIG_BPF_STREAM_PARSER) += sock_map.o\nobj-/' "$NETMK"
    ok "net/core/Makefile 已加入 sock_map.o"
  else
    echo "obj-\$(CONFIG_BPF_STREAM_PARSER) += sock_map.o" >> "$NETMK"
    ok "net/core/Makefile 已追加 sock_map.o"
  fi
fi

# ⑤ Cgroup v2 (Android 11+ 需要)
"$KERNEL_DIR/scripts/config" --file "$OUT_ABS/.config" \
  --enable CONFIG_CGROUPS \
  --enable CONFIG_CGROUP_SCHED \
  --enable CONFIG_MEMBARRIER

ok "内核选项已设置 (MODVERSIONS/FHANDLE/EROFS/BPF/BTF/CGROUP)"

# ─────────────────────────────────────────────────────────────
# ★★★ 强制对齐 kernel-release (最关键的一步, 必须在编译之前做)
#
#   原厂 .ko 的 vermagic 必须精确匹配:
#     4.14.186-perf-00252-g2f26b5917fd6 SMP preempt mod_unload modversions aarch64
#   不一致 → 相机/蓝牙/GPS/热管理全部失效, 刷了等于变砖。
#
#   ★★★ 根因 (第 28 轮实测, 只差这一个字) ★★★
#   内核 scripts/setlocalversion 第 96 行:
#       res="${res}${CONFIG_LOCALVERSION}${LOCALVERSION}"
#   这两个是**相加**关系, 不是二选一!
#     - CONFIG_LOCALVERSION : 来自 .config → include/config/auto.conf
#     - LOCALVERSION         : make 命令行变量, make 会导出到 recipe 环境
#   第 28 轮两者都被写成 -perf-00252-g2f26b5917fd6, 于是后缀出现两次:
#       4.14.186-perf-00252-g2f26b5917fd6-perf-00252-g2f26b5917fd6
#
#   ★ 正确做法 (与原厂 MTK 构建方式等价):
#       CONFIG_LOCALVERSION_AUTO = not set   ← 否则 git describe 追加 -g<hash>
#       CONFIG_LOCALVERSION      = ""        ← 必须为空, 只留一个来源
#       LOCALVERSION             = -perf-...  ← 只通过 make 命令行传一次
#
#   ★ 为什么传了 LOCALVERSION 就不会多出 "+":
#       setlocalversion 里 `if test "${LOCALVERSION+set}" != "set"` —
#       环境里存在 LOCALVERSION 就不追加 scm 短哈希/加号。
#
#   ★ 先做秒级预检 (make kernelrelease), 不通过直接 die ——
#     避免白编译 40 分钟后才发现版本串错了。
# ─────────────────────────────────────────────────────────────
log "对齐 kernel-release (原厂要求 $EXPECT_RELEASE)"

# ① 关掉 LOCALVERSION_AUTO (否则 setlocalversion 用 git describe 追加 -g<hash>)
sed -i 's/^CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/' "$OUT_ABS/.config"
grep -q "^CONFIG_LOCALVERSION_AUTO" "$OUT_ABS/.config" || echo "# CONFIG_LOCALVERSION_AUTO is not set" >> "$OUT_ABS/.config"

# ② CONFIG_LOCALVERSION 必须置空 —— 这是第 28 轮失败的关键
#    setlocalversion 会把 CONFIG_LOCALVERSION 与 make 命令行传入的 LOCALVERSION
#    **相加**, 两者同值就会让后缀翻倍。空串 = 只有一个来源。
if grep -q "^CONFIG_LOCALVERSION=" "$OUT_ABS/.config"; then
  sed -i 's|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION=""|' "$OUT_ABS/.config"
else
  echo 'CONFIG_LOCALVERSION=""' >> "$OUT_ABS/.config"
fi
ok "CONFIG_LOCALVERSION_AUTO=off, CONFIG_LOCALVERSION=\"\" (后缀只由 make 命令行注入一次)"

# ③ 秒级预检 —— 编译前就确认版本串, 不通过立刻 die
#    用 include/config/kernel.release (内核真正使用的那个文件), 而不是
#    kernelrelease 目标 —— 后者不依赖 auto.conf, 会读到过期的 config 值。
probe_release() {
  make O="$OUT" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
       CFLAGS_KERNEL="$EXTRA_CFLAGS" \
       CC="$CC" LD="$LD" HOSTCC="$HOSTCC" \
       LLVM_IAS="$LLVM_IAS" LOCALVERSION="$LOCALVERSION" \
       include/config/kernel.release >/dev/null 2>&1 || true
  cat "$OUT_ABS/include/config/kernel.release" 2>/dev/null | tr -d '\r\n'
}
PROBE="$(probe_release)"
log "预检 kernel-release = ${PROBE:-<空>}"

if [ "$PROBE" != "$EXPECT_RELEASE" ]; then
  warn "预检不通过 (得到 '${PROBE:-空}', 期望 '$EXPECT_RELEASE') -> 启用 setlocalversion 强制改写"
  if bash "$SCRIPTS_DIR/force_release.sh" "$KERNEL_DIR/scripts/setlocalversion" "$LOCALVERSION"; then
    PROBE="$(probe_release)"
    log "fallback 后 kernel-release = ${PROBE:-<空>}"
  else
    warn "fallback 改写失败"
  fi
  if [ "$PROBE" != "$EXPECT_RELEASE" ]; then
    die "版本串预检失败: 得到 '${PROBE:-空}', 期望 '$EXPECT_RELEASE' —— 拒绝进入编译"
  fi
fi
ok "版本串预检通过 ✓ ($PROBE)"

make O="$OUT" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
     CFLAGS_KERNEL="$EXTRA_CFLAGS" \
     CC="$CC" LD="$LD" HOSTCC="$HOSTCC" \
     LLVM_IAS="$LLVM_IAS" LOCALVERSION="$LOCALVERSION" \
     -j"$(nproc)" Image.gz-dtb Image.gz || die "编译失败"

cd "$REPO_DIR"
ok "编译完成"

# ─────────────────────────────────────────────────────────────
# 产物校验与打包
# ─────────────────────────────────────────────────────────────
log "校验产物"
REL=$(cat "$OUT_ABS/include/config/kernel.release" 2>/dev/null || echo "unknown")
echo "$REL" > kernel-release.txt
echo "kernel-release = $REL"
echo "期望           = $EXPECT_RELEASE"

if [ "$REL" != "$EXPECT_RELEASE" ]; then
  warn "kernel-release 与原厂不一致！"
  warn "  实际: $REL"
  warn "  期望: $EXPECT_RELEASE"
  warn "  这会导致 vendor 里所有 .ko 报 'disagrees about version of symbol'"
  warn "  → 相机/蓝牙/GPS/热管理全部失效, 不能刷!"
  FAILED_RELEASE=1
else
  ok "kernel-release 与原厂完全一致 ✓ (可加载原厂 .ko)"
  FAILED_RELEASE=0
fi

# 同时校验 vermagic 里必须的 modversions
#
# ★ 用 if 而不是 A && B || C:
#   `grep -q ... && ok ... || warn ...` 这种写法在 ok 失败时会被 || 分支接管,
#   语义脆弱; 而且 grep 无匹配时返回 1, 若不在 if 条件里会直接杀掉脚本。
if [ -f "$OUT_ABS/include/config/auto.conf" ]; then
  if grep -q "^CONFIG_MODVERSIONS=y" "$OUT_ABS/include/config/auto.conf"; then
    ok "CONFIG_MODVERSIONS=y (符号 CRC 校验保留)"
  else
    warn "CONFIG_MODVERSIONS 未开 —— 原厂 .ko 依赖符号 CRC"
  fi
fi

# 提取关键配置留档
#
# ★ 陷阱 (第 29 轮踩到): 本脚本开了 `set -euo pipefail`,
#   而 `grep` 找不到匹配时返回 1 —— 管道整体失败, 脚本会**静默退出**。
#   第 29 轮就是这样在版本串校验通过之后突然挂掉的 (日志里连报错都没有,
#   BUILD-INFO.txt 也没生成)。所以这里所有 grep 管道都必须兜住。
{
  echo "# 编译信息"
  echo "kernel-release: $REL"
  echo "localversion:   $LOCALVERSION"
  echo "erofs:          $ENABLE_EROFS"
  echo "bpf:            $ENABLE_BPF"
  echo "uname_fake:     $ENABLE_UNAME"
  echo "ksu:            $ENABLE_KSU"
  echo "date:           $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "== 关键 config 项 =="
} > BUILD-INFO.txt

for opt in CONFIG_EROFS_FS CONFIG_EROFS_FS_XATTR CONFIG_BPF_SYSCALL CONFIG_DEBUG_INFO_BTF \
           CONFIG_CGROUP_BPF CONFIG_CGROUP_FREEZER CONFIG_FHANDLE CONFIG_INDIRECT_FD \
           CONFIG_MODULES CONFIG_MODVERSIONS CONFIG_LOCALVERSION CONFIG_LOCALVERSION_AUTO; do
  # grep 无匹配返回 1, 必须 || true 兜住, 否则 set -e 会杀掉脚本
  val="$(grep -E "^${opt}=" "$OUT_ABS/.config" 2>/dev/null | head -1 | cut -d= -f2 || true)"
  # ★ 注意: 不能写成 [ -z "$val" ] && val="n"
  #   —— 当 $val 非空时 test 返回 1, 在 set -e 下**整行失败直接退出脚本**!
  if [ -z "$val" ]; then val="n"; fi
  echo "$opt=$val" | tee -a BUILD-INFO.txt
done

grep -E "^CONFIG_LOCALVERSION" "$OUT_ABS/.config" 2>/dev/null | tee -a BUILD-INFO.txt || true
echo "EROFS 生效: $(grep -c '^CONFIG_EROFS_FS=y' "$OUT_ABS/.config" 2>/dev/null || echo 0)" | tee -a BUILD-INFO.txt

cp "$OUT_ABS/.config" config.txt
cp "$OUT_ABS/System.map" System.map 2>/dev/null || true

# ── 硬保护: 版本串不匹配就不打包, 避免刷进去变砖 ──
if [ "$FAILED_RELEASE" != "0" ]; then
  echo "" | tee -a BUILD-INFO.txt
  echo "!! 打包已取消: kernel-release 与原厂不一致" | tee -a BUILD-INFO.txt
  echo "!! 详见上方提示, 修好 LOCALVERSION 后重跑" | tee -a BUILD-INFO.txt
  die "kernel-release 不匹配, 拒绝打包"
fi

# AnyKernel3 打包
bash "$SCRIPTS_DIR/pack_anykernel.sh" || warn "AnyKernel3 打包失败"

ok "==== 全部完成 ===="
ls -la *.zip 2>/dev/null || true
echo "kernel-release.txt / BUILD-INFO.txt / config.txt / System.map 已生成"
