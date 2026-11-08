#!/usr/bin/env bash
# KernelSU / SukiSU-Ultra 集成
#
# cezanne 用的是 KernelSU（Ty_1224 的 HyperOS4 包即「内置 ksu」），
# 兼容 KernelSU / KernelSU-Next / SukiSU-Ultra 三种管理器。
#
# 参考：
#   mt6873-dev  "add KernelSU" + "Import SukiSU-Ultra changes" (2025-08-03)
#   仓库使用 .gitmodules 方式挂 KernelSU 子模块
#
set -euo pipefail

log() { echo -e "\033[1;36m[ksu]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[ ok ]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[warn]\033[0m $*"; }

cd "${KERNEL_DIR:-kernel}"

KSU_REPO="${ksu_repo:-https://github.com/tiann/KernelSU}"
KSU_BRANCH="${ksu_branch:-main}"

if [ -d KernelSU ] && [ -f KernelSU/kernel/Makefile ]; then
  ok "KernelSU 已存在，跳过"
  exit 0
fi

log "克隆 KernelSU ($KSU_BRANCH)"
rm -rf KernelSU
if git clone --depth 1 --branch "$KSU_BRANCH" "$KSU_REPO" KernelSU 2>/dev/null; then
  ok "KernelSU 克隆完成"
else
  warn "KernelSU 克隆失败（网络问题？）"
  warn "可手动下载后解压到内核树根目录的 KernelSU/ 下"
  exit 1
fi

# KernelSU 的 setup 需要在 defconfig 阶段被调用
# 官方做法: 在 <vendor>_defconfig 里加 CONFIG_KSU=y
# MTK 体系则需要在 kernel/Makefile 里加 EXTRA_SRC

for d in cezanne_user_defconfig cezanne_defconfig; do
  f="arch/arm64/configs/$d"
  [ -f "$f" ] || continue
  log "开启 CONFIG_KSU in $d"
  grep -q "^CONFIG_KSU=y" "$f" || echo "CONFIG_KSU=y" >> "$f"
  ok "$d 已加入 CONFIG_KSU=y"
done

# 非 defconfig 体系（MTK build.config）：追加 EXTRA_SRC
if grep -q "EXTRA_SRC" build.config.mtk.aarch64 2>/dev/null; then
  if ! grep -q "KernelSU" build.config.mtk.aarch64; then
    sed -i 's|^EXTRA_SRC=.*|EXTRA_SRC+= KernelSU|' build.config.mtk.aarch64
    ok "build.config.mtk.aarch64 已加入 KernelSU"
  fi
fi

# KernelSU 官方 setup 脚本（会向 defconfig 注入配置）
if [ -f KernelSU/kernel/setup.sh ]; then
  ok "KernelSU kernel/setup.sh 就绪（编译时会自动调用）"
else
  warn "未找到 KernelSU/kernel/setup.sh，可能需要手动集成"
fi

ok "KernelSU 集成完成"
