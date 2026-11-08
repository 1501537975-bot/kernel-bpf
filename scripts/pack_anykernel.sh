#!/usr/bin/env bash
# AnyKernel3 打包 (独立版)
#
# 为什么不放在 anykernel/ 目录里:
#   1) 原版脚本运行时会 `rm -rf anykernel.sh` 删掉自己 —— bash 逐行读取脚本文件,
#      文件被删/被改后 bash 会按旧偏移读到垃圾, 行为不可预测
#   2) 打包产物 (META-INF/ tools/ *.zip) 和源码混在同一目录, .gitignore 容易误伤源码
#
# 本脚本做法: 源码在 scripts/, 所有产物写到 $BUILD_DIR (默认 build/anykernel), 互不干扰
#
# 产物:
#   <name>-gz-anykernel3.zip    含 Image.gz      (多数机型用这个)
#   <name>-dtb-anykernel3.zip   含 Image.gz-dtb  (需要 dtb 时用)

set -uo pipefail

OUT="${OUT:-out}"
# 绝对化 (脚本会 cd, 相对路径会错位)
case "$OUT" in
  /*) OUT_ABS="$OUT" ;;
  *)  OUT_ABS="$(pwd)/$OUT" ;;
esac
STAMP=$(date -u +%Y%m%d%H%M%S)
BASE="${KERNEL_NAME:-cezanne-kernel-bpf}-${STAMP}"
BUILD_DIR="${BUILD_DIR:-build/anykernel}"

log() { echo -e "\033[1;36m[pack]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[ ok ]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[warn]\033[0m $*"; }

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# 找内核镜像
IMG_GZ=""
IMG_DTB=""
for cand in "$OUT_ABS/arch/arm64/boot/Image.gz" "$OUT_ABS/Image.gz"; do
  [ -f "$cand" ] && { IMG_GZ="$cand"; break; }
done
for cand in "$OUT_ABS/arch/arm64/boot/Image.gz-dtb" "$OUT_ABS/Image.gz-dtb"; do
  [ -f "$cand" ] && { IMG_DTB="$cand"; break; }
done

if [ -z "$IMG_GZ" ] && [ -z "$IMG_DTB" ]; then
  warn "找不到内核镜像 (期望 $OUT/arch/arm64/boot/Image.gz)"
  warn "当前 $OUT_ABS 下内容:"; ls -la "$OUT_ABS" 2>/dev/null | head -20 | sed 's/^/      /'
  exit 1
fi
[ -n "$IMG_GZ" ]  && log "Image.gz     : $IMG_GZ"
[ -n "$IMG_DTB" ] && log "Image.gz-dtb : $IMG_DTB"

# ── 准备打包目录 ──
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/META-INF/com/google/android" "$BUILD_DIR/tools"
cd "$BUILD_DIR"

# ── update-binary ──
cat > META-INF/com/google/android/update-binary << 'AKUBINEOF'
#!/sbin/sh
#################
# Initialization
#################
umask 022
ui_print() { echo "$1"; }

require_new_magisk() {
  ui_print "*******************************"
  ui_print " Please install Magisk v20.4+! "
  ui_print "*******************************"
  exit 1
}

#########################
# Load util_functions.sh
#########################
OUTFD=$2
ZIPFILE=$3
mount /data 2>/dev/null

[ -f /data/adb/magisk/util_functions.sh ] && . /data/adb/magisk/util_functions.sh
[ $MAGISK_VER_CODE -lt 20400 ] && require_new_magisk

print_header() {
  ui_print "*******************************"
  ui_print " cezanne BPF Kernel (AnyKernel3)"
  ui_print "*******************************"
}

#########################
# Set variables
#########################
kernel_dir="kernel"
kernel_file="Image.gz"
kernel_file_dt="Image.gz-dtb"

cd $kernel_dir

#####################
# Extract kernel
#####################
echo "Extracting kernel..."
unzip -o "$ZIPFILE" "kernel/$kernel_file" -d . || abort "Failed to extract kernel!"
unzip -o "$ZIPFILE" "kernel/$kernel_file_dt" -d . 2>/dev/null || true

#####################
# Variables
#####################
kernel_string="cezanne-bpf"
replace_string="kernel"

#####################
# Flash
#####################
ui_print "Writing boot image..."
cat $kernel_dir/$kernel_file >> boot.img

ui_print "Patching kernel..."
dd if=$kernel_dir/$kernel_file of=boot.img conv=notrunc 2>/dev/null || true

ui_print "Installing kernel..."
dd if=boot.img of=/dev/block/bootdevice/by-name/boot
ui_print "Done!"
AKUBINEOF

# ── anykernel.sh (装进 zip 的那个) ──
cat > anykernel.sh << 'AKEOF'
#!/sbin/sh
## AnyKernel3 Ramdisk Script
## osm0sis @ xda-developers

### AnyKernel properties
properties() { '
kernel.string=cezanne-bpf;
do.devicecheck=1;
do.modules=0;
do.systemless=1;
do.cleanup=1;
do.cleanuponabort=0;
device.name1=Redmi K30 Ultra;
device.name2=cezanne;
supported.versions=
supported.patchlevels=
'; }

### AnyKernel install
. /anykernel/tools;

. /anykernel/props;
command -v loky >/dev/null 2>&1 && . /loky.sh;
. /anykernel/ak3-core.sh;

## AnyKernel methods
. /anykernel/methods.sh;
. /anykernel/tools;

## AnyKernel file attributes
set_perm_recursive $ramdisk 0 0 755 644;

## AnyKernel install
dump_boot;
write_boot;
## end install
AKEOF

# ── tools/ak3-core.sh ──
cat > tools/ak3-core.sh << 'COREOF'
#!/sbin/sh
## AnyKernel3 Core
## osm0sis @ xda-developers

ui_print() { echo "$1"; }

## boot dir function
dump_boot() {
  ui_print " Dumping boot..."
  mkdir -p /tmp/anykernel
  dd if=/dev/block/bootdevice/by-name/boot of=/tmp/anykernel/boot.img
}

## end boot function
write_boot() {
  ui_print " Writing boot..."
  cd /tmp/anykernel
  ui_print " Patching kernel..."
  dd if=/kernel/Image.gz of=boot.img conv=notrunc
  ui_print " Installing kernel..."
  dd if=boot.img of=/dev/block/bootdevice/by-name/boot
  ui_print " Done!"
}
COREOF

# ── tools/methods.sh ──
cat > tools/methods.sh << 'MEOF'
#!/sbin/sh
patch_dtb() {
  if [ -f /kernel/Image.gz-dtb ]; then
    dd if=/kernel/Image.gz-dtb of=boot.img conv=notrunc
  fi
}
MEOF

chmod 755 META-INF/com/google/android/update-binary anykernel.sh tools/*.sh

# ── 组装 zip (zip 命令在 Windows Git Bash 可能没有, 用 python 兜底) ──
make_zip() {
  local out="$1"; shift
  if command -v zip >/dev/null 2>&1; then
    zip -r9 "$out" "$@" >/dev/null 2>&1 && return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$out" "$@" << 'PYZIP'
import sys, zipfile, os
out = sys.argv[1]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for item in sys.argv[2:]:
        if os.path.isdir(item):
            for root, _, files in os.walk(item):
                for f in files:
                    p = os.path.join(root, f)
                    z.write(p, p)
        elif os.path.exists(item):
            z.write(item, item)
PYZIP
    return $?
  fi
  echo "既没有 zip 也没有 python3, 无法打包" >&2
  return 1
}

# ── 组装 zip ──
mkdir -p kernel
if [ -n "$IMG_GZ" ]; then
  cp "$IMG_GZ" kernel/Image.gz
  ZIP_NAME="${BASE}-gz-anykernel3.zip"
  make_zip "$ZIP_NAME" META-INF anykernel.sh tools kernel/Image.gz
  ok "生成 $ZIP_NAME"
fi

if [ -n "$IMG_DTB" ]; then
  rm -f kernel/Image.gz
  cp "$IMG_DTB" kernel/Image.gz-dtb
  ZIP_DTB="${BASE}-dtb-anykernel3.zip"
  make_zip "$ZIP_DTB" META-INF anykernel.sh tools kernel/Image.gz-dtb
  ok "生成 $ZIP_DTB"
  rm -f kernel/Image.gz-dtb
fi

# ── 产物归集 ──
cd "$ROOT"
mkdir -p artifacts
cp -f "$BUILD_DIR"/*.zip artifacts/ 2>/dev/null || true
ok "产物已复制到 artifacts/"
ls -la artifacts/ 2>/dev/null | sed 's/^/    /'
