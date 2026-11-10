#!/usr/bin/env bash
# 把 lib/lz4 的解压器换成修复版（upstream LZ4 1.8.2+ 语义）
#
# ── 根因 ────────────────────────────────────────────────────────────────
# cezanne-r-oss (4.14.186) 自带的 lib/lz4 是 2017 年 Sven Schmidt 移植的
# pre-LZ4-1.8.2 版本，其 LZ4_decompress_safe_partial() 在 partialDecoding
# 路径上直接 goto _output_error（返回 -1），而上游在
#   a4c3a1dd8ebd ("lib/lz4: apply upstream LZ4 1.8.2 decompressor fixes")
# 中改成了 「clamp 到 oend 并正常返回」。四处语义差异：
#   1) 字面量段收尾: 旧 `if (cpy > oend) goto _output_error;`
#                    新 `if (cpy > oend) { cpy = oend; length = oend - op; }`
#                    并且 `if (!partialDecoding || (cpy == oend)) break;`
#   2) 重叠 in-place: 旧 LZ4_wildCopy() 用 memcpy（读脏数据）
#                    新用 LZ4_memmove()
#   3) 旧在 partialDecoding 下仍无条件 LZ4_write32(op, offset)（越界写）
#      新用 `if (!partialDecoding)` 包住
#   4) 匹配段复制越界: 旧 goto _output_error；新 clamp 到 oend 后正常返回
#
# EROFS 的 big pcluster（Z_EROFS_ADVISE_BIG_PCLUSTER_1/2）会发
# partial_decoding=1 的请求，decompressor.c 判定 `ret != rq->outputsize`
# 即 -EIO。旧实现返回 -1 -> 真机 dmesg 满屏
#   erofs: (device dm-0): z_erofs_lz4_decompress: failed to decompress -1 in[...] out[...]
# 表现就是小文件能读、framework.jar / services.jar 这种大文件 dd 报 I/O error。
# （参考实现 71594152「更新 lz4 版本以修复在开机时 EROFS 无法解压的问题」）
#
# ── 做法 ────────────────────────────────────────────────────────────────
# 从同为 4.14 的 MTK 树 mt6873-dev/android_kernel_xiaomi_mt6885 (cgroup-v2,
# 4.14.336, 即 patches/erofs 的同一来源) 取 lib/lz4 的四个文件覆盖:
#   lz4_decompress.c 14119 -> 20449 B   (dec32table -> inc32table, 修复版)
#   lz4defs.h         5943 ->  6785 B   (补 LZ4_memmove / MATCH_SAFEGUARD_DISTANCE)
#   lz4_compress.c   23376 -> 23282 B   (与 defs 配套)
#   lz4hc_compress.c 19151 -> 19052 B   (与 defs 配套)
# lib/lz4/Makefile 两边逐字节相同，不动。
# include/linux/lz4.h 两边 blob 相同 (394e3d92...)，不动。
set -euo pipefail

log() { echo -e "\033[1;36m[lz4]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[ ok ]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[warn]\033[0m $*"; }

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPTS_DIR:-$_SCRIPT_DIR}"
export SCRIPTS_DIR

cd "${KERNEL_DIR:-kernel}"
PATCH_DIR="${PATCH_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../patches" 2>/dev/null && pwd)}"
LZ4_SRC="$PATCH_DIR/lz4/lib/lz4"

if [ ! -d "$LZ4_SRC" ]; then
  echo "[lz4] 预置源码缺失: $LZ4_SRC" >&2
  exit 1
fi
if [ ! -d lib/lz4 ]; then
  echo "[lz4] 内核树里没有 lib/lz4 —— 内核源不对?" >&2
  exit 1
fi

# 已经是修复版就直接跳过（幂等）
if grep -q "inc32table" lib/lz4/lz4_decompress.c 2>/dev/null \
   && ! grep -q "dec32table" lib/lz4/lz4_decompress.c 2>/dev/null; then
  ok "lib/lz4 已是修复版 (inc32table), 跳过"
  exit 0
fi

log "旧版本证据: $(grep -c 'dec32table' lib/lz4/lz4_decompress.c || true) 处 dec32table, $(wc -l < lib/lz4/lz4_decompress.c) 行"

for f in lz4_decompress.c lz4defs.h lz4_compress.c lz4hc_compress.c; do
  cp "$LZ4_SRC/$f" "lib/lz4/$f"
  ok "覆盖 lib/lz4/$f ($(wc -c < lib/lz4/$f) B)"
done

# ── 硬校验: 不通过就 exit 1, 不能让 CI 白跑 20 分钟 ──
if grep -q "dec32table" lib/lz4/lz4_decompress.c; then
  echo "[lz4] lib/lz4/lz4_decompress.c 里还有 dec32table —— 覆盖没生效" >&2
  exit 1
fi
for pat in inc32table LZ4_memmove MATCH_SAFEGUARD_DISTANCE; do
  if ! grep -q "$pat" lib/lz4/lz4_decompress.c; then
    echo "[lz4] lib/lz4/lz4_decompress.c 缺少 $pat —— 拿到的不是修复版" >&2
    exit 1
  fi
done
if ! grep -q "LZ4_memmove" lib/lz4/lz4defs.h; then
  echo "[lz4] lib/lz4/lz4defs.h 缺少 LZ4_memmove" >&2
  exit 1
fi
if ! grep -q "MATCH_SAFEGUARD_DISTANCE" lib/lz4/lz4defs.h; then
  echo "[lz4] lib/lz4/lz4defs.h 缺少 MATCH_SAFEGUARD_DISTANCE" >&2
  exit 1
fi
# partialDecoding 分支必须还在（4.19+ 的 clamp 逻辑在里面）
if [ "$(grep -c "partialDecoding" lib/lz4/lz4_decompress.c)" -lt 4 ]; then
  echo "[lz4] partialDecoding 分支数量异常 —— 不是 4.19+ 的实现" >&2
  exit 1
fi
if ! grep -q "LZ4_decompress_safe_partial" lib/lz4/lz4_decompress.c; then
  echo "[lz4] 缺少 LZ4_decompress_safe_partial —— EROFS 会链接失败" >&2
  exit 1
fi

ok "lib/lz4 已替换为修复版并校验通过 ✓"
