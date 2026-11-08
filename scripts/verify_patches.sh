#!/usr/bin/env bash
# 验证生成的 BPF patch 能否干净地 apply 到原厂 cezanne 4.14.186 树上
#
# 做法：浅克隆原厂树 → git apply --check 每个 patch → 统计成功/失败
# 这是"方案是否成立"的决定性验证：patch 能 apply 才有意义。
set -uo pipefail

ok()    { echo -e "\033[1;32m[ ok ]\033[0m $*"; }

BASE="$(cd "$(dirname "$0")/.." && pwd)"
PATCH_DIR="$BASE/patches/mt6768-bpf"
WORK="${WORK:-/tmp/bpfverify}"
SRC="https://github.com/MiCode/Xiaomi_Kernel_OpenSource"
BRANCH="cezanne-r-oss"

echo "=============================================="
echo " BPF patch 可应用性验证"
echo "=============================================="

if [ ! -d "$PATCH_DIR" ] || [ -z "$(ls -A "$PATCH_DIR" 2>/dev/null)" ]; then
  echo "[FAIL] patch 目录为空: $PATCH_DIR"
  echo "       先运行: python3 scripts/gen_bpf_patches.py patches/mt6768-bpf"
  exit 1
fi

echo "patch 数量: $(ls -1 "$PATCH_DIR"/*.patch 2>/dev/null | wc -l)"
echo ""

rm -rf "$WORK"
mkdir -p "$WORK"

echo "[1/3] 浅克隆原厂内核树 (MiCode $BRANCH) ..."
# 注意：Windows 文件名大小写不敏感，会与内核树里的 aux.c/aux.h 冲突导致 checkout 失败。
# 对策：core.protectNTFS=false + 只 checkout 需要打 patch 的文件。
clone_ok=0
for repo in "$SRC" "https://github.com/2025DeveloperTeamInStaff/Xiaomi_Kernel_OpenSource"; do
  rm -rf "$WORK/kernel"
  if git clone --depth 1 --branch "$BRANCH" --no-checkout "$repo" "$WORK/kernel" 2>/dev/null; then
    cd "$WORK/kernel"
    git config core.ignorecase true 2>/dev/null || true
    git config core.protectNTFS false 2>/dev/null || true
    git sparse-checkout init --cone 2>/dev/null || true
    git sparse-checkout set net/bpf net/core kernel/bpf kernel/trace include/uapi/linux include/linux 2>/dev/null || true
    if git checkout -f HEAD 2>/dev/null || git checkout -f HEAD -- net kernel include 2>/dev/null; then
      clone_ok=1
      echo "      克隆完成: $repo"
      break
    fi
  fi
done
if [ "$clone_ok" != "1" ]; then
  echo "[FAIL] 无法检出工作树"
  echo "      提示: Windows 上内核树含大小写冲突文件（aux.c/aux.h），"
  echo "            可在 WSL/Linux 下重跑本验证，或用 --no-checkout 只取 .git 后手动取文件"
  exit 1
fi
echo ""

echo "[2/3] 逐个 git apply --check ..."
ok=0; fail=0; failed=""
for p in "$PATCH_DIR"/*.patch; do
  name=$(basename "$p")
  if git apply --check "$p" 2>/tmp/apply_err.txt; then
    printf "  [ OK ] %s\n" "$name"
    ok=$((ok+1))
  else
    printf "  [FAIL] %s\n" "$name"
    head -3 /tmp/apply_err.txt | sed 's/^/         /'
    fail=$((fail+1))
    failed="$failed $name"
  fi
done
echo ""

echo "[3/3] 实际 apply 验证（串行，前一个成功才继续）..."
cd "$WORK/kernel"
applied=0
for p in "$PATCH_DIR"/*.patch; do
  name=$(basename "$p")
  if git apply --3way "$p" 2>/dev/null || git apply "$p" 2>/dev/null; then
    applied=$((applied+1))
  else
    echo "  串行 apply 失败: $name"
    break
  fi
done
echo "  串行成功: $applied / $(ls -1 "$PATCH_DIR"/*.patch | wc -l)"
echo ""

echo "=============================================="
echo " 结果: check 通过 $ok / 失败 $fail"
echo "=============================================="

# 能力验证：apply 后是否含 sk_msg / btf_vmlinux
cd "$WORK/kernel"
if [ -f net/core/filter.c ]; then
  echo ""
  echo "能力验证 (apply 后):"
  echo "  net/core/filter.c   sk_msg 出现: $(grep -c sk_msg net/core/filter.c 2>/dev/null || echo 0) 次"
fi
if [ -f kernel/bpf/verifier.c ]; then
  echo "  kernel/bpf/verifier.c btf_vmlinux: $(grep -c btf_vmlinux kernel/bpf/verifier.c 2>/dev/null || echo 0) 次"
fi
echo ""
echo "验证工作区: $WORK/kernel"
echo "（可在此目录继续手工编译测试）"
