#!/usr/bin/env bash
# 强制改写内核 scripts/setlocalversion —— 兜底方案 (fallback)
#
# 背景:
#   内核 setlocalversion 第 96 行:
#       res="${res}${CONFIG_LOCALVERSION}${LOCALVERSION}"
#   CONFIG_LOCALVERSION (来自 .config) 与 LOCALVERSION (make 命令行导出的环境变量)
#   是**相加**关系。第 28 轮两者同时被写成 -perf-00252-g2f26b5917fd6,
#   结果版本串变成:
#       4.14.186-perf-00252-g2f26b5917fd6-perf-00252-g2f26b5917fd6
#
#   主方案 (build.sh 里): CONFIG_LOCALVERSION="" + make 命令行传 LOCALVERSION
#   → 只有一个来源, 版本串正确。
#
#   本脚本是主方案万一失效时的兜底: 直接把 setlocalversion 换成一个
#   只输出固定后缀的极简脚本, 从根上切断 git/scm/localversion 的所有影响。
#
# 用法:
#   bash force_release.sh <setlocalversion 的绝对路径> <版本后缀>
#
# 例:
#   bash force_release.sh "$KERNEL_DIR/scripts/setlocalversion" \
#                        "-perf-00252-g2f26b5917fd6"

set -euo pipefail

SV="${1:?用法: force_release.sh <setlocalversion 路径> <版本后缀>}"
SUFFIX="${2:?用法: force_release.sh <setlocalversion 路径> <版本后缀>}"

[ -f "$SV" ] || { echo "[FAIL] 找不到 setlocalversion: $SV" >&2; exit 1; }

# 备份原文件 (只备份一次, 重复调用不覆盖)
if [ ! -f "$SV.orig" ]; then
  cp "$SV" "$SV.orig"
fi

# 替换为只输出固定后缀的极简实现
#
# 注意 --save-scmversion 参数:
#   内核在某些流程里会调用 `setlocalversion --save-scmversion` 把 scm 版本
#   写进 .scmversion。我们必须原样 exit 0 (不写任何内容),
#   否则会污染 .scmversion, 导致后续版本串再次被追加。
cat > "$SV" <<EOF
#!/bin/sh
# [WorkBuddy] 强制版本串: 忽略 git / scm / localversion 文件, 只输出固定后缀
if [ "\$1" = "--save-scmversion" ]; then
	exit 0
fi
echo "$SUFFIX"
EOF

chmod +x "$SV"

# 自检
OUT="$(sh "$SV" 2>/dev/null || true)"
if [ "$OUT" != "$SUFFIX" ]; then
  echo "[FAIL] 改写后自检不通过: 得到 '$OUT', 期望 '$SUFFIX'" >&2
  exit 1
fi

echo "[ ok ] setlocalversion 已改写为固定输出 '$SUFFIX' (原文件备份在 $SV.orig)"
