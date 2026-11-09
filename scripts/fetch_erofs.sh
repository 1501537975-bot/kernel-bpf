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
# 之后所有路径都用**相对路径** —— 脚本已经 cd 进内核树了,
# 用 $KERNEL_DIR 反而会因为它未定义 (独立运行时) 触发 set -u 退出。
# 这两个路径由 build.sh export 传入, 但独立跑时可能没设 -> 给默认值
PATCH_DIR="${PATCH_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../patches" 2>/dev/null && pwd)}"
EROFS_TREE="${EROFS_TREE:-$PATCH_DIR/erofs}"

if [ -d fs/erofs ]; then
  ok "fs/erofs 已存在，跳过移植"
  exit 0
fi

log "查找可用的 erofs 源"

# 优先顺序：
#   1) 本仓库 patches/erofs/ 里预置的 erofs 源码（最可靠, 不依赖网络克隆）
#      ★ 2026-11-09 起预置: 来自 mt6873-dev (4.14.336) 的原生 fs/erofs
#        —— 与 cezanne 4.14.186 同代码基, 依赖分析: 26 个头里只缺 2 个
#   2) 外部 EROFS_TREE 目录
#   3) 现场克隆 mt6768 / mt6885
ERDFS_SRC=""
PRESET="$PATCH_DIR/erofs/fs/erofs"

if [ -d "$PRESET" ]; then
  ERDFS_SRC="$PRESET"
  log "使用仓库预置的 erofs 源码 (mt6873-dev 4.14.336 原生版)"
elif [ -d "$EROFS_TREE/fs/erofs" ]; then
  ERDFS_SRC="$EROFS_TREE/fs/erofs"
  log "使用外部 erofs 树"
else
  log "预置源缺失, 尝试现场克隆"
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  if git clone --depth 1 --filter=blob:none --sparse \
      https://github.com/mk7x7/android_kernel_xiaomi_mt6768 "$TMP/mt" 2>/dev/null; then
    (cd "$TMP/mt" && git sparse-checkout set fs/erofs include/uapi/linux include/trace/events 2>/dev/null) || true
    if [ -d "$TMP/mt/fs/erofs" ]; then
      ERDFS_SRC="$TMP/mt/fs/erofs"
      ok "已从 mt6768 取得 erofs"
    fi
  fi
  # 兜底 2: mt6873-dev（分支是 cgroup-v2, 不是 main!）
  if [ -z "$ERDFS_SRC" ]; then
    log "回退到 mt6873-dev (分支 cgroup-v2)"
    if git clone --depth 1 --filter=blob:none --sparse \
        -b cgroup-v2 \
        https://github.com/mt6873-dev/android_kernel_xiaomi_mt6885 "$TMP/mt2" 2>/dev/null; then
      (cd "$TMP/mt2" && git sparse-checkout set fs/erofs include/uapi/linux include/trace/events 2>/dev/null) || true
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
#     ★ 预置源里已经带了 include/trace/events/erofs.h, 优先用它
#     ★ TMP 可能未定义 (走预置分支时没克隆) -> 用 ${TMP:+...} 防 set -u 退出
if [ -f "$PATCH_DIR/erofs/include/trace/events/erofs.h" ]; then
  mkdir -p "include/trace/events"
  cp "$PATCH_DIR/erofs/include/trace/events/erofs.h" "include/trace/events/"
  ok "已复制 include/trace/events/erofs.h (预置)"
elif [ -n "${TMP:-}" ] && [ -f "$TMP/mt/include/trace/events/erofs.h" ]; then
  mkdir -p "include/trace/events"
  cp "$TMP/mt/include/trace/events/erofs.h" "include/trace/events/"
  ok "已复制 include/trace/events/erofs.h"
elif [ -n "${TMP:-}" ] && [ -f "$TMP/mt2/include/trace/events/erofs.h" ]; then
  mkdir -p "include/trace/events"
  cp "$TMP/mt2/include/trace/events/erofs.h" "include/trace/events/"
  ok "已复制 include/trace/events/erofs.h"
fi
if [ ! -f "include/trace/events/erofs.h" ]; then
  warn "include/trace/events/erofs.h 缺失 -- EROFS 编译会失败"
fi

log "复制 fs/erofs"
mkdir -p fs/erofs
cp -r "$ERDFS_SRC"/. fs/erofs/
ok "fs/erofs 已复制（$(find fs/erofs -name '*.c' | wc -l) 个 C 文件）"

# (b) 修正 mt6768 erofs 的上游笔误 (必须在复制之后做, 之前文件还不存在):
#     fs/erofs/internal.h:164 用了未定义的 VAL (应为函数参数 orig_val)
#     报错: internal.h:164:41: error: 'VAL' undeclared (first use in this function)
if [ -f fs/erofs/internal.h ] && grep -q "VAL != EROFS_LOCKED_MAGIC" fs/erofs/internal.h; then
  sed -i 's/VAL != EROFS_LOCKED_MAGIC/orig_val != EROFS_LOCKED_MAGIC/' fs/erofs/internal.h
  ok "已修正 erofs internal.h 的 VAL -> orig_val 笔误"
fi

# (b2) ★ 4.14 兼容: xarray 在 4.14.186 里不存在
#      mt6873 (4.14.336) 的 erofs utils.c 用了 xa_lock(),
#      而 4.14.186 只有 radix_tree_* (4.14 的 radix_tree_root 没有 xarray 那套锁)
#      -> 换成 radix_tree 的等价加锁
if [ -f fs/erofs/utils.c ] && grep -q "xa_lock" fs/erofs/utils.c; then
  # ★ 用 Python 做替换 —— sed 里 & 是"整个匹配"的特殊字符,
  #   直接写 &sbi->... 会被 sed 当成"插入整个匹配", 结果变成 &&sbi->...
  python3 - "$PWD/fs/erofs/utils.c" << 'PYEOF' || warn "python 替换失败"
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8", errors="surrogateescape").read()
before = s
s = s.replace("xa_lock(&sbi->workstn_tree)", "down_write(&sbi->workstn_tree.lock)")
s = s.replace("xa_unlock(&sbi->workstn_tree)", "up_write(&sbi->workstn_tree.lock)")
s = s.replace("#include <linux/xarray.h>\n", "")
open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)
print("  replaced:", before != s)
PYEOF
  if grep -q "xa_lock\|xa_unlock\|xarray" fs/erofs/utils.c; then
    warn "utils.c 里还有残留 xarray 引用, 编译可能失败:"
    grep -n "xa_lock\|xa_unlock\|xarray" fs/erofs/utils.c | sed 's/^/      /' || true
  else
    ok "已把 xa_lock/xa_unlock 换成 radix_tree 的 down_write/up_write (4.14 兼容)"
  fi
fi

# (c) uapi 头文件必须到位 (EROFS_SUPER_MAGIC_V1 / EROFS_SUPER_OFFSET 等宏在这里)
#     ★ mt6873 (4.14.336) 的 erofs 把这些宏定义在自己的 erofs_fs.h / internal.h 里,
#       **不依赖 uapi/linux/erofs_fs.h** —— 实测依赖分析: uapi 依赖数 = 0。
#       所以这一段只在 uapi 头确实存在时才复制, 不再强制要求。
#
# ★★ TMP 可能未定义! 走"仓库预置"分支时根本不会克隆, TMP 永远没被赋值,
#    而本脚本开了 set -u -> 引用未定义变量会**直接退出**, 导致后面的
#    fs/Makefile / fs/Kconfig 注册全部没做 -> CONFIG_EROFS_FS 被 syncconfig 丢掉。
#    (第 32 轮就是这么挂的: "line 154: TMP: unbound variable")
TMP="${TMP:-}"

for src in "${TMP:+$TMP/mt/include/uapi/linux/erofs_fs.h}" \
           "${TMP:+$TMP/mt2/include/uapi/linux/erofs_fs.h}" \
           "$PATCH_DIR/erofs/include/uapi/linux/erofs_fs.h"; do
  [ -n "$src" ] || continue
  if [ -f "$src" ]; then
    mkdir -p include/uapi/linux
    cp "$src" include/uapi/linux/
    ok "已复制 include/uapi/linux/erofs_fs.h ($(wc -c < include/uapi/linux/erofs_fs.h) B)"
    break
  fi
done
# 真正的检查: EROFS_SUPER_MAGIC_V1 在 erofs 自己的头里有没有
if grep -rq "EROFS_SUPER_MAGIC_V1" fs/erofs/ 2>/dev/null; then
  ok "EROFS_SUPER_MAGIC_V1 已由 fs/erofs 自身提供 (无需 uapi 头)"
else
  warn "找不到 EROFS_SUPER_MAGIC_V1 -- EROFS 编译会失败"
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

# ── 硬校验 (第 32 轮教训) ──────────────────────────────
# ★ 第 32 轮: fetch_erofs.sh 在中途因 set -u (TMP 未定义) 退出,
#   导致下面的 fs/Makefile / fs/Kconfig 注册**根本没执行**,
#   而 build.sh 只看到 "EROFS 移植未成功 -> 继续构建" 的警告就放行了,
#   结果 CONFIG_EROFS_FS 被 syncconfig 丢掉 -> 内核里没有 EROFS 驱动。
#   → 这里必须硬校验, 不通过就 exit 1, 让 build.sh 明确失败。
if ! grep -q "obj-\$(CONFIG_EROFS_FS) += erofs" fs/Makefile 2>/dev/null; then
  die "fs/Makefile 没有注册 erofs —— CONFIG_EROFS_FS 会被 syncconfig 丢掉"
fi
if ! grep -q 'source "fs/erofs/Kconfig"' fs/Kconfig 2>/dev/null; then
  die "fs/Kconfig 没有注册 fs/erofs/Kconfig —— CONFIG_EROFS_FS 会被 syncconfig 丢掉"
fi
ok "fs/Makefile 与 fs/Kconfig 注册已确认 ✓"

log "下一步: build.sh 会开启 CONFIG_EROFS_FS / CONFIG_EROFS_FS_XATTR"
log "注意: 实测 K40G A16/A17 移植包的镜像**无压缩** (feature_compat=0x07),"
log "      所以不需要 CONFIG_EROFS_FS_ZIP"
