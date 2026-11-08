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

ENABLE_EROFS="${enable_erofs:-yes}"
ENABLE_BPF="${enable_bpf:-yes}"
ENABLE_UNAME="${enable_uname:-yes}"
ENABLE_KSU="${enable_ksu:-no}"
LOCALVERSION="${localversion:--perf-00252-g2f26b5917fd6}"

KERNEL_DIR="${KERNEL_DIR:-kernel}"
OUT="${OUT:-out}"
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

# ─────────────────────────────────────────────────────────────
# 1. 交叉编译工具链
# ─────────────────────────────────────────────────────────────
log "[1/7] 准备交叉编译工具链"
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-android-
export CLANG_TRIPLE=aarch64-linux-gnu-
export CC=clang
export LD=ld.lld
export NM=llvm-nm
export OBJCOPY=llvm-objcopy
export OBJDUMP=llvm-objdump
export STRIP=llvm-strip
export HOSTCC=clang
export HOSTCXX=clang++
export LLVM_IAS=1

if [ -x "${CLANG_PREBUILT_BIN}/clang" ]; then
  export PATH="${CLANG_PREBUILT_BIN}:$PATH"
  ok "使用内核自带 clang: $(clang --version | head -1)"
else
  # 回退：Ubuntu/Debian 的 aarch64-linux-gnu 工具链 + clang
  if ! command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    sudo apt-get update -qq && sudo apt-get install -y -qq \
      gcc-aarch64-linux-gnu gcc-12 clang lld llvm bc bison flex libssl-dev libelf-dev \
      python3 ccache zip kmod || die "工具链安装失败"
  fi
  export CROSS_COMPILE=aarch64-linux-gnu-
  export CC="clang --target=aarch64-linux-gnu-"
  export HOSTCC=clang
  ok "使用系统工具链: $(clang --version | head -1)"
fi

# ─────────────────────────────────────────────────────────────
# 2. 源码准备
# ─────────────────────────────────────────────────────────────
log "[2/7] 准备内核源码"
cd "$KERNEL_DIR"
git config --global --add safe.directory "$KERNEL_DIR" 2>/dev/null || true

# ─────────────────────────────────────────────────────────────
# 3. EROFS 回合（主线 4.19 才有，4.14 缺失）
# ─────────────────────────────────────────────────────────────
if [ "$ENABLE_EROFS" = "yes" ]; then
  log "[3/7] 回合 fs/erofs"
  if [ -d fs/erofs ] && grep -q "CONFIG_EROFS_FS=y" .config 2>/dev/null; then
    ok "erofs 已存在，跳过"
  else
    bash "$SCRIPTS_DIR/fetch_erofs.sh" || die "erofs 移植失败"
    # erofs 需要 lz4 与 zstd 支持
    scripts/config --file .config \
      -e EROFS_FS -e EROFS_FS_XATTR -e EROFS_FS_ZIP \
      -e LZ4 -e LZ4_DECOMPRESS -e ZSTD -e CRYPTO_LZ4 \
      --enable CONFIG_EROFS_FS \
      --enable CONFIG_EROFS_FS_XATTR \
      --enable CONFIG_EROFS_FS_ZIP \
      --enable CONFIG_LZ4_DECOMPRESS || true
    ok "erofs 配置完成"
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
  bash "$SCRIPTS_DIR/backport_bpf.sh" || die "BPF 回合失败"
  # BPF 需要这些内核选项
  scripts/config --file .config \
    --enable CONFIG_BPF_SYSCALL \
    --enable CONFIG_BPF_JIT \
    --enable CONFIG_BPF_JIT_ALWAYS_ON \
    --enable CONFIG_DEBUG_INFO_BTF \
    --enable CONFIG_PAHOLE_VERSION \
    --enable CONFIG_BPF_LSM \
    --disable CONFIG_BPF_UNPRIVILEGED \
    --enable CONFIG_CGROUPS \
    --enable CONFIG_CGROUP_BPF \
    --enable CONFIG_CGROUP_SCHED \
    --enable CONFIG_CGROUP_FREEZER \
    --enable CONFIG_FHANDLE \
    --enable CONFIG_INDIRECT_FD \
    --enable CONFIG_MEMBARRIER || true
  ok "BPF 内核选项配置完成"
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
OUT_ABS="$(cd .. && pwd)/$OUT"
mkdir -p "$OUT_ABS"
log "    输出目录: $OUT_ABS"

make mrproper || true

# 原厂树 (MiCode cezanne-r-oss) 的 defconfig 名为 cezanne_user_defconfig,
# 但部分衍生树用 cezanne_defconfig —— 两者都探测, 取实际存在的一个
DEFCONFIG=""
for d in cezanne_user_defconfig cezanne_defconfig cezanne_defconfig_gki; do
  if [ -f "arch/arm64/configs/$d" ]; then DEFCONFIG="$d"; break; fi
done
[ -n "$DEFCONFIG" ] || die "在 arch/arm64/configs/ 下找不到 cezanne 的 defconfig (实际内容: $(ls arch/arm64/configs/ 2>/dev/null | tr '\n' ' '))"
log "    使用 defconfig: $DEFCONFIG"

make O=../$OUT ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     CC="clang --target=aarch64-linux-gnu-" LD=ld.lld \
     LLVM_IAS=1 LOCALVERSION="$LOCALVERSION" \
     "$DEFCONFIG" || die "defconfig 失败"

# ── 关键: 原厂 defconfig 里 CONFIG_MODVERSIONS 没有 default y (默认 n),
#    但原厂 .ko 的 vermagic 明确带 modversions -> 必须显式打开,
#    否则原厂 10 个 .ko 全部 "disagrees about version of symbol"
log "    强制打开 CONFIG_MODVERSIONS (原厂 .ko 依赖符号 CRC)"
scripts/config --file "$OUT_ABS/.config" --enable CONFIG_MODVERSIONS
# 原厂 defconfig 显式关闭了 FHANDLE, 而 A16+ 的 BPF 需要它
scripts/config --file "$OUT_ABS/.config" --enable CONFIG_FHANDLE
scripts/config --file "$OUT_ABS/.config" --enable CONFIG_INDIRECT_FD
ok "MODVERSIONS / FHANDLE / INDIRECT_FD 已开启"

make O=../$OUT ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     CC="clang --target=aarch64-linux-gnu-" LD=ld.lld \
     LLVM_IAS=1 LOCALVERSION="$LOCALVERSION" \
     -j"$(nproc)" Image.gz-dtb Image.gz || die "编译失败"

# ─────────────────────────────────────────────────────────────
# ★★★ 强制改写版本串 (最关键的一步)
#   原厂 .ko 的 vermagic 必须精确匹配:
#     4.14.186-perf-00252-g2f26b5917fd6 SMP preempt mod_unload modversions aarch64
#   而 Actions 里是浅克隆, setlocalversion 追加的 git hash 与原厂不同
#   (原厂是 g2f26b5917fd6, 我们会得到别的 hash) → 模块全部加载失败
#
#   做法: 用 scripts/setlocalversion 的替代 —— 直接在 Makefile 里写死
#         并关闭 CONFIG_LOCALVERSION_AUTO, 然后重编
# ─────────────────────────────────────────────────────────────
log "强制对齐 kernel-release (原厂要求 $([ -n "$EXPECT_RELEASE" ] && echo "$EXPECT_RELEASE" || echo '4.14.186-perf-00252-g2f26b5917fd6'))"

# 关掉 LOCALVERSION_AUTO (否则 setlocalversion 会用 git hash 覆盖)
sed -i 's/^CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/' "$OUT_ABS/.config"
grep -q "^CONFIG_LOCALVERSION_AUTO" "$OUT_ABS/.config" || echo "# CONFIG_LOCALVERSION_AUTO is not set" >> "$OUT_ABS/.config"
# 写死 LOCALVERSION
if grep -q "^CONFIG_LOCALVERSION=" "$OUT_ABS/.config"; then
  sed -i "s|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION=\"$LOCALVERSION\"|" "$OUT_ABS/.config"
else
  echo "CONFIG_LOCALVERSION=\"$LOCALVERSION\"" >> "$OUT_ABS/.config"
fi
ok "已固定 LOCALVERSION=$LOCALVERSION 且关闭 LOCALVERSION_AUTO"

# 重编一次让版本串生效 (增量, 很快)
make O=../$OUT ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     CC="clang --target=aarch64-linux-gnu-" LD=ld.lld \
     LLVM_IAS=1 LOCALVERSION="$LOCALVERSION" \
     -j"$(nproc)" Image.gz-dtb Image.gz || die "重编失败 (版本串对齐)"

cd ..
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
if [ -f "$OUT_ABS/include/config/auto.conf" ]; then
  grep -q "^CONFIG_MODVERSIONS=y" "$OUT_ABS/include/config/auto.conf" && \
    ok "CONFIG_MODVERSIONS=y (符号 CRC 校验保留)" || \
    warn "CONFIG_MODVERSIONS 未开 —— 原厂 .ko 依赖符号 CRC"
fi

# 提取关键配置留档
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
           CONFIG_MODULES CONFIG_MODVERSIONS CONFIG_LOCALVERSION; do
  val=$(grep -E "^${opt}=" "$OUT_ABS/.config" 2>/dev/null | head -1 | cut -d= -f2)
  [ -z "$val" ] && val="n"
  echo "$opt=$val" | tee -a BUILD-INFO.txt
done

grep -E "^CONFIG_LOCALVERSION" "$OUT_ABS/.config" | tee -a BUILD-INFO.txt
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
