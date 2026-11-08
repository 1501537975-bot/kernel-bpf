#!/usr/bin/env bash
# 从 MTK 同代内核树移植 fs/erofs 到 4.14
#
# 背景：
#   EROFS 是 Linux 4.19 引入的只读文件系统。Android 15+ 的 system/product/
#   system_ext 分区大量使用 erofs，而 cezanne 原厂内核 4.14 没有该驱动，
#   挂载时直接失败 → 卡开机。
#   解决：从同为 4.14 的 MTK 内核树取 fs/erofs 目录过来（代码基版本一致，
#         移植冲突极少），并打开相关 config。
#
# 参考实现：
#   孤独不能 71570411「从 5.10 移植 EROFS（实测可用）」
#   71594152「更新 lz4 版本以修复在开机时 EROFS 无法解压的问题」
#   mt6873-dev 的 erofs 提交链（2025-08-03）：
#     erofs: move erofs out of staging
#     erofs: Add a bunch of missing includes
#     BACKPORT: erofs: fix lz4 inplace decompression
#     BACKPORT: erofs: add per-cpu threads for decompression as an option
#     BACKPORT: erofs: fix use-after-free of on-stack io[]
#     erofs: Switch to attach/detach_page_private
#     UPSTREAM: erofs: fix an error code in z_erofs_init_zip_subsystem()
#     erofs: fix compact 4B support for 16k block size
#
set -euo pipefail

log() { echo -e "\033[1;36m[erofs]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[ ok ]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[warn]\033[0m $*"; }

cd "${KERNEL_DIR:-kernel}"
# 这两个路径由 build.sh export 传入, 但独立跑时可能没设 -> 给默认值
PATCH_DIR="${PATCH_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../patches" 2>/dev/null && pwd)}"
EROFS_TREE="${EROFS_TREE:-$PATCH_DIR/erofs}"

if [ -d fs/erofs ]; then
  ok "fs/erofs 已存在，跳过移植"
  exit 0
fi

log "查找可用的 erofs 源"

# 优先顺序：
#   1) 本地 patch 目录里预置的 erofs 源码（最可靠）
#   2) 从同代 MTK 树克隆（MT6768 / MT6885）
ERDFS_SRC=""

if [ -d "$PATCH_DIR/erofs/fs/erofs" ]; then
  ERDFS_SRC="$PATCH_DIR/erofs/fs/erofs"
  log "使用本地预置 erofs 源码"
elif [ -d "$EROFS_TREE/fs/erofs" ]; then
  ERDFS_SRC="$EROFS_TREE/fs/erofs"
  log "使用外部 erofs 树"
else
  log "克隆 MT6768 (同代 4.14) 取 erofs"
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  if git clone --depth 1 --filter=blob:none --sparse \
      https://github.com/mk7x7/android_kernel_xiaomi_mt6768 "$TMP/mt" 2>/dev/null; then
    (cd "$TMP/mt" && git sparse-checkout set fs/erofs include/uapi/linux/erofs_fs.h include/trace/events 2>/dev/null) || true
    if [ -d "$TMP/mt/fs/erofs" ]; then
      ERDFS_SRC="$TMP/mt/fs/erofs"
      ok "已从 mt6768 取得 erofs"
    fi
  fi
  # 兜底 2: mt6873-dev（已有整理好的 erofs 提交）
  if [ -z "$ERDFS_SRC" ]; then
    log "回退到 mt6873-dev (mt6885)"
    if git clone --depth 1 --filter=blob:none --sparse \
        https://github.com/mt6873-dev/android_kernel_xiaomi_mt6885 "$TMP/mt2" 2>/dev/null; then
      (cd "$TMP/mt2" && git sparse-checkout set fs/erofs include/uapi/linux/erofs_fs.h include/trace/events 2>/dev/null) || true
      if [ -d "$TMP/mt2/fs/erofs" ]; then
        ERDFS_SRC="$TMP/mt2/fs/erofs"
        ok "已从 mt6873-dev 取得 erofs"
      fi
    fi
  fi
fi

if [ -z "$ERDFS_SRC" ]; then
  warn "无法取得 erofs 源码"
  warn "请手动把 fs/erofs 目录放到内核树，或放到 \$PATCH_DIR/erofs/fs/erofs"
  exit 1
fi

# ── 补齐依赖 ──────────────────────────────────────────
# (a) include/trace/events/erofs.h —— fs/erofs/super.c 需要它
#     (fs/erofs/super.c:15: fatal error: trace/events/erofs.h: No such file)
if [ -f "$TMP/mt/include/trace/events/erofs.h" ]; then
  mkdir -p "$KERNEL_DIR/include/trace/events"
  cp "$TMP/mt/include/trace/events/erofs.h" "$KERNEL_DIR/include/trace/events/"
  ok "已复制 include/trace/events/erofs.h"
fi

# (b) 修正 mt6768 erofs 的上游笔误:
#     fs/erofs/internal.h:164 用了未定义的 VAL (应为函数参数 orig_val)
#     报错: internal.h:164:41: error: 'VAL' undeclared (first use in this function)
if [ -f "$KERNEL_DIR/fs/erofs/internal.h" ] && grep -q "VAL != EROFS_LOCKED_MAGIC" "$KERNEL_DIR/fs/erofs/internal.h"; then
  sed -i 's/VAL != EROFS_LOCKED_MAGIC/orig_val != EROFS_LOCKED_MAGIC/' "$KERNEL_DIR/fs/erofs/internal.h"
  ok "已修正 erofs internal.h 的 VAL -> orig_val 笔误"
fi

log "复制 fs/erofs"
mkdir -p fs/erofs
cp -r "$ERDFS_SRC"/. fs/erofs/
ok "fs/erofs 已复制（$(find fs/erofs -name '*.c' | wc -l) 个 C 文件）"

# erofs 需要的头文件
if [ ! -f include/uapi/linux/erofs_fs.h ]; then
  for src in "$ERDFS_SRC"/../../include/uapi/linux/erofs_fs.h \
             "$TMP/mt/include/uapi/linux/erofs_fs.h" \
             "$TMP/mt2/include/uapi/linux/erofs_fs.h"; do
    if [ -f "$src" ]; then
      mkdir -p include/uapi/linux
      cp "$src" include/uapi/linux/
      ok "已复制 erofs_fs.h"
      break
    fi
  done
fi

# fs/Makefile 注册
if ! grep -q "erofs" fs/Makefile 2>/dev/null; then
  log "注册 fs/Makefile"
  # 插入到 obj-$(CONFIG_EROFS_FS) += erofs/ 附近
  if grep -q "^obj-\$(CONFIG_EXT4_FS)" fs/Makefile; then
    sed -i '/^obj-\$(CONFIG_EXT4_FS)/i obj-$(CONFIG_EROFS_FS) += erofs/' fs/Makefile
  else
    echo 'obj-$(CONFIG_EROFS_FS) += erofs/' >> fs/Makefile
  fi
  ok "fs/Makefile 已注册 erofs"
fi

# Kconfig 注册
if ! grep -q "EROFS_FS" fs/Kconfig 2>/dev/null; then
  log "注册 fs/Kconfig"
  if [ -f fs/erofs/Kconfig ]; then
    # 在 fs/Kconfig 末尾追加 source
    grep -q "source \"fs/erofs/Kconfig\"" fs/Kconfig || \
      echo 'source "fs/erofs/Kconfig"' >> fs/Kconfig
    ok "fs/Kconfig 已注册"
  else
    warn "fs/erofs/Kconfig 不存在，需手动注册"
  fi
fi

ok "erofs 移植完成"
log "下一步: build.sh 会开启 CONFIG_EROFS_FS / CONFIG_EROFS_FS_XATTR / CONFIG_EROFS_FS_ZIP"
log "注意: 若 OS4 分区为压缩格式，需同时确认 CONFIG_LZ4_DECOMPRESS=y 与 CONFIG_CRYPTO_LZ4=y"
