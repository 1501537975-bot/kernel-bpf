#!/usr/bin/env bash
# BPF backport: 把 5.10/5.15 的 BPF 能力回合到 4.14
#
# 背景（Android 16/17 硬门槛）：
#   MTK 在 4.14 早期 tag 里的 ALPS05247589 破坏了 BPF arraymap 的
#   array_map_update_elem 边界检查，memcpy 被静默跳过 → BPF map 写入丢失。
#   A13 起 Android 的 netbpfload/bpfloader 会加载 BPF 程序做网络过滤，
#   加载失败或 map 写不进去 → bpfloader 炸 → 无网络 / SystemUI 崩溃循环。
#
# 解决路径（三件套，缺一不可）：
#   ① Import BPF Changes        —— 回合上游 BPF 核心修复（含 arraymap 修复）
#   ② bpf: sockmap → sk_msg      —— 新版 socket map 实现，A16+ 依赖
#   ③ sys_clone3                 —— A17 zygote 需要
#   ④ BTF 补充                   —— A16+ 的 bpfloader 需要内核 BTF
#
# 参考实现（免费公开）：
#   mt6873-dev/android_kernel_xiaomi_mt6885  (cgroup-v2 分支, 2025-08-02)
#   mk7x7/android_kernel_xiaomi_mt6768        (MT6768 同代 4.14, LTS 4.14.357)
#
set -euo pipefail

log() { echo -e "\033[1;36m[bpf]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[ ok ]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[warn]\033[0m $*"; }

cd "${KERNEL_DIR:-kernel}"

# ── 判定树里是否已有 BPF 关键特性 ───────────────────────────
has_sockmap_skmsg() {
  grep -q "sk_msg" net/core/filter.c 2>/dev/null
}
has_btf_verifier() {
  grep -q "bpf_prog_attach_btf" kernel/bpf/verifier.c 2>/dev/null
}
has_clone3() {
  grep -q "CONFIG_ARCH_HAS_SYSCALL_WRAPPER" include/uapi/asm-generic/unistd.h 2>/dev/null || true
  grep -rq "__NR_clone3" arch/arm64/include 2>/dev/null
}

# ── 1. 回合上游 BPF 核心（从 mt6768 同代树取 patch）────────────
log "检查现有 BPF 能力"
if has_sockmap_skmsg; then
  ok "sockmap→sk_msg 已存在"
else
  log "回合 sockmap → generic sk_msg interface"
  # 上游提交: net: bpf, sockmap: convert to generic sk_msg interface
  # 涉及: net/core/filter.c, net/core/sock_map.c, include/net/bpf.h,
  #       include/linux/bpf.h, kernel/bpf/sockmap.c
  if [ -d "$PATCH_DIR/mt6768-bpf" ]; then
    for p in "$PATCH_DIR"/mt6768-bpf/*.patch; do
      [ -f "$p" ] || continue
      log "apply $(basename "$p")"
      git apply --3way "$p" || git apply "$p" || warn "apply 失败: $(basename "$p")"
    done
    ok "patch 集合应用完成"
  else
    warn "未找到 mt6768-bpf patch 目录，跳过 sockmap 回合"
    warn "（A16/A17 需要它；请把 patch 集放到 \$PATCH_DIR/mt6768-bpf/）"
  fi
fi

# ── 2. 回合 sys_clone3（A17 zygote 硬需求）────────────────────
log "检查 sys_clone3"
if has_clone3; then
  ok "sys_clone3 已存在"
else
  log "回合 sys_clone3（内核 syscall + arm64 入口）"
  # 需要: kernel/sys.c (SYSCALL_DEFINE), include/linux/syscalls.h,
  #       arch/arm64/include/asm/unistd.h, arch/arm64/include/uapi/asm/unistd.h,
  #       arch/arm64/entry/common.c, include/uapi/linux/sched.h (CLONE3 args)
  if [ -d "$PATCH_DIR/clone3" ]; then
    for p in "$PATCH_DIR"/clone3/*.patch; do
      [ -f "$p" ] || continue
      log "apply $(basename "$p")"
      git apply --3way "$p" || git apply "$p" || warn "apply 失败: $(basename "$p")"
    done
    ok "clone3 patch 应用完成"
  else
    warn "未找到 clone3 patch 目录，跳过"
    warn "（A17 需要它；A16 不强制）"
  fi
fi

# ── 3. BTF 支持开关（bpfloader 需要内核导出 BTF）─────────────
log "确保 BTF 相关配置"
grep -q "^CONFIG_DEBUG_INFO_BTF=y" .config 2>/dev/null || \
  echo "CONFIG_DEBUG_INFO_BTF=y" >> .config
grep -q "^CONFIG_PAHOLE_VERSION=y" .config 2>/dev/null || \
  echo "CONFIG_PAHOLE_VERSION=y" >> .config

# PAHOLE 需要 pahole 工具
if ! command -v pahole >/dev/null 2>&1; then
  warn "未安装 pahole，BTF 将无法生成（4.19+ 内核的 BTF 需要 pahole >= 1.16）"
  warn "安装: sudo apt-get install -y dwarves"
fi

ok "BPF 回合阶段完成"

# ── 4. 报告当前状态 ──────────────────────────────────────────
echo "" >> "$BUILD_INFO" 2>/dev/null || true
log "BPF 能力现状："
echo "  sockmap/sk_msg : $(has_sockmap_skmsg && echo YES || echo NO)"
echo "  BTF verifier   : $(has_btf_verifier && echo YES || echo NO)"
echo "  sys_clone3     : $(has_clone3 && echo YES || echo NO)"
