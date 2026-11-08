# cezanne BPF 内核构建仓库

> 红米 K30 至尊纪念版（cezanne / M2006J10C / MT6889 天玑1000+）
> 目标：编译一个支持 **Android 16 / 17** 的 4.14 内核

---

## 这个仓库解决什么问题

Android 16 起，`netbpfload` / `bpfloader` / `netd` 会加载 BPF 程序做网络过滤。
MTK 在 4.14 早期 tag 里的 `ALPS05247589` 破坏了 BPF arraymap 的边界检查，
导致 BPF map 写入被静默丢弃 → **bpfloader 炸 → 无网络 / SystemUI 崩溃循环**。

同时 A15+ 的系统分区改用 **EROFS**（4.19 才有的只读文件系统），4.14 没有驱动 → 卡开机。

本仓库把三件套补齐：

| 能力 | 作用 | 状态 |
|---|---|---|
| **BPF backport** | 回合 5.10 的 sk_msg / BTF / arraymap 修复 | ✅ 9 个 patch，已验证可干净 apply |
| **EROFS backport** | 从同代 MTK 树移植 fs/erofs | ✅ 自动获取 |
| **uname 伪装** | 对外报告 5.4.186，放行 BPF 加载器的版本检查 | ✅ 可选 |
| **sys_clone3** | A17 zygote 硬需求 | ⚠️ 需额外 patch（见下） |
| **KernelSU** | 内置 root | ✅ 可选 |

**关键不变量**：`kernel-release` 必须等于 `4.14.186-perf-00252-g2f26b5917fd6`，
否则原厂 vendor 里那 10 个 `.ko` 会全部报 `disagrees about version of symbol`。

---

## ⚠️ 编译前必读：原厂硬约束（2026-11-08 实测）

在 GitHub Actions 上原样编译会**失败或刷进去变砖**，除非满足下面三条。脚本已内置强制校验。

### 1. defconfig 名字
原厂树 `MiCode/Xiaomi_Kernel_OpenSource @ cezanne-r-oss` 的 defconfig 是
**`cezanne_user_defconfig`**（不是 `cezanne_defconfig`）。
脚本会自动探测 `cezanne_user_defconfig` / `cezanne_defconfig` / `cezanne_defconfig_gki`。

### 2. kernel-release 必须**精确**等于原厂值
```
原厂 /proc/version : 4.14.186-perf-00252-g2f26b5917fd6
原厂 .ko vermagic  : 4.14.186-perf-00252-g2f26b5917fd6 SMP preempt mod_unload modversions aarch64
```
Actions 是**浅克隆**，git hash 与原厂不同 → `scripts/setlocalversion` 会追加 `-g<hash>`，
导致版本串不匹配 → 原厂 10 个 .ko 全部 `disagrees about version of symbol`
→ **相机/蓝牙/GPS/热管理全部失效**。

**脚本对策**：编译后关闭 `CONFIG_LOCALVERSION_AUTO`、写死 `CONFIG_LOCALVERSION`、重编一次，
并且**版本串不匹配就直接拒绝打包**（`exit 1`）。

### 3. CONFIG_MODVERSIONS 必须显式打开
原厂 defconfig 里 `CONFIG_MODVERSIONS` **没有 default y**（Kconfig 默认 n），
但原厂 .ko 的 vermagic 里明确带 `modversions` → 必须显式 `--enable`。

同样，**原厂 defconfig 显式关闭了 `CONFIG_FHANDLE`**（`# CONFIG_FHANDLE is not set`），
而 A16+ 的 BPF 需要它 → 脚本强制打开 `MODVERSIONS` / `FHANDLE` / `INDIRECT_FD`。

### 已验证事实
- `scripts/config` 在原厂树中存在 ✓
- `arch/arm64/configs/` 内容：`atom_user_defconfig` `bomb_user_defconfig` **`cezanne_user_defconfig`** `cuttlefish_defconfig` `defconfig` `k68xx_defconfig` 系列 `ranchu64_defconfig`
- `cezanne_user_defconfig` = 14066 字节 / 521 行
- 本机 4.14 内核**已自带** `CONFIG_BPF_SYSCALL=y` / `BPF_JIT=y` / bpffs → **唯一缺的是 `CONFIG_DEBUG_INFO_BTF`**
- 缺 `CONFIG_EROFS_FS`（`/proc/filesystems` 无 erofs）→ A15+ 分区必须靠内核侧移植

## 📋 操作清单

**照着做请打开 → [`操作清单.html`](操作清单.html)**（单页，可勾选进度、可打印、命令块可一键复制）

10 个阶段：准备 → 触发 Actions → 三项自检 → 备份 → 刷入 → 验证 → 回滚 → 换 A17 包 → 已知坑 → 社区资源速查。

> **两条最容易踩的**：
> ① `kernel-release` 必须等于 `4.14.186-perf-00252-g2f26b5917fd6`，不等**别刷**（原厂 vendor 的 10 个 .ko 全废）
> ② **Windows 上编译不了内核**（内核树 `aux.c`/`aux.h` 大小写冲突），必须走 GitHub Actions

## 快速开始

### 方式一：GitHub Actions（推荐，无需本地环境）

1. Fork 本仓库到你的账号
2. Actions → `Build cezanne BPF kernel` → Run workflow
3. 参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| `enable_erofs` | ✅ | 移植 fs/erofs（A15+ 分区必需） |
| `enable_bpf` | ✅ | 回合 BPF（A16/A17 必需） |
| `enable_uname` | ✅ | 伪装 uname 为 5.4.186 |
| `enable_ksu` | ⬜ | 集成 KernelSU |
| `localversion` | `-perf-00252-g2f26b5917fd6` | **不要改**，改了 vendor 模块加载不了 |

4. 跑完（30~60 分钟）在 Artifacts 下载 `cezanne-kernel-bpf`：
   - `*-gz-anykernel3.zip` → TWRP / OrangeFox 里直接刷
   - `*-dtb-anykernel3.zip` → 需要 dtb 时用
   - `kernel-release.txt` / `BUILD-INFO.txt` / `config.txt` / `System.map` → 排障用

### 方式二：本地编译（Linux / WSL2）

```bash
git clone --depth 1 --branch cezanne-r-oss \
  https://github.com/MiCode/Xiaomi_Kernel_OpenSource kernel
git clone <this-repo> buildrepo
cd buildrepo

# 生成 BPF patch（已随仓库提供，可跳过）
python3 scripts/gen_bpf_patches.py patches/mt6768-bpf

# 验证 patch 能否干净应用
bash scripts/verify_patches.sh

# 编译
export enable_erofs=yes enable_bpf=yes enable_uname=yes enable_ksu=no
export KERNEL_DIR=../kernel OUT=../out
export PATCH_DIR="$PWD/patches" EROFS_TREE="$PWD/patches/erofs"
export SCRIPTS_DIR="$PWD/scripts" ANYKERNEL_DIR="$PWD/anykernel"
bash scripts/build.sh
```

### 自检（拿到包后必做）

```bash
# 1. kernel-release 必须严格等于这一行，否则别刷
cat kernel-release.txt
# 期望: 4.14.186-perf-00252-g2f26b5917fd6

# 2. config 必须含这几项
grep -E "CONFIG_(EROFS_FS|BPF_SYSCALL|DEBUG_INFO_BTF|CGROUP_FREEZER)=y" config.txt
```

---

## 目录结构

```
kernel-bpf/
├── .github/workflows/build.yml     # Actions 流水线
├── scripts/
│   ├── build.sh                   # 主构建脚本（7 步）
│   ├── backport_bpf.sh            # BPF 回合（检测能力 → 应用 patch）
│   ├── fetch_erofs.sh             # EROFS 移植（自动克隆同代 MTK 树取源码）
│   ├── patch_uname.sh             # uname 伪装（注入 FAKE_UNAME）
│   ├── setup_ksu.sh               # KernelSU 集成
│   ├── gen_bpf_patches.py         # 从 mt6768 生成 BPF patch
│   └── verify_patches.sh          # patch 可应用性验证
├── configs/
│   ├── erofs.fragment             # EROFS config 片段
│   └── ksu.fragment               # KernelSU config 片段
├── anykernel/anykernel.sh         # AnyKernel3 打包
└── patches/mt6768-bpf/            # 生成的 9 个 BPF patch
```

---

## 数据来源（全部免费公开）

| 来源 | 用途 |
|---|---|
| `MiCode/Xiaomi_Kernel_OpenSource @ cezanne-r-oss` | 原厂 4.14.186 内核基线 |
| `mk7x7/android_kernel_xiaomi_mt6768` (MT6768 同代 4.14) | **BPF backport 来源**（含 `LTS: Update to 4.14.357`、sk_msg 转换、BTF 修复） |
| `mt6873-dev/android_kernel_xiaomi_mt6885` (cgroup-v2 分支) | BPF + EROFS + fake uname + SukiSU 的另一份实现（备选来源） |
| `Kernel114514/kernel_redmi_mt6885` | cezanne 通用内核树（2026-07-15 仍活跃） |
| `origin-oem-ports / portingessential` | UKL / MIO Kitchen / TFSS / apex / init.gsi.rc（移植工具） |

### 社区技术结论（酷安「Redmi K30至尊纪念版」专项调研）

- **月下斩过往**（内核核心作者，uid 34331734）：
  > 「Backport 5.10 BPF 以支持启动 Android17 QPR0 · Backport sys_clone3 以满足 Android17 zygote」
  > 「安卓15开始4.14内核已经不是原生支持了…开包会炸bpfloader，也就是我们所熟知的网络过滤器」
  > 「不过5.4的bpf也只能开qpr0」→ **A16/A17 只能 QPR0**
  > 「我内核只补充了安卓16所依赖的BTF的东西和一点ebpf相关」→ 最小化补丁，不是全量 backport
- **tiffanyy**（BPF 补丁集作者，uid 29580310）：
  > 「Android16已经删除了对5.4以下内核的支持…当然我们可以通过 system patch bpf 来解决这个问题，
  > 适用条件 4.9-4.19…将 system/apex 下的 com.android.tethering.capex 或 com.android.tethering.apex 替换」
- **Ty_1224**（移植包作者，uid 12024762）：HyperOS4 A17 已跑通，内核 `4.14.357-perf-g2c5cc13`，OS4.0.0.10 内置 ksu，VNDK 保持 31
- **WIMOS**（uid 28814114）：「这手机不支持 erofs，mi_ext 难以打包」→ EROFS 是 A13 档移植的拦路虎

---

## 已验证的量化对比

| 文件 | 原厂 cezanne 4.14.186 | 打 patch 后（mt6768 回合） |
|---|---|---|
| `net/core/filter.c` | 116,973 字节，`sk_msg` **0** 处 | 288,122 字节，`sk_msg` **118** 处 |
| `kernel/bpf/verifier.c` | 无 BTF | `btf_vmlinux` **31** 处 |

patch 可应用性：**9/9 全部 `git apply --check` 通过，串行实际 apply 9/9 成功**。

---

## 已知限制

1. **A16/A17 只能 QPR0**，QPR2 需要真正的 5.4 BPF，4.14 做不到
2. **sys_clone3 未包含在 9 个 patch 里** —— A17 zygote 需要，需从 mt6873-dev 或 mt6768 单独提取
3. **BTF 需要 pahole**（`sudo apt-get install dwarves`），Actions 里已装
4. **FOD 屏下指纹不可用** —— GSI 架构缺口（vendor HAL 回调为 null），与内核无关
5. **必须用 ext4 打包**，本机 `/proc/filesystems` 无 erofs（内核侧支持 ≠ 分区侧可用）

---

## 刷入后回滚

```bash
# 进 fastboot
adb reboot bootloader
# 刷回原厂 boot
fastboot flash boot boot_stock.img
# 或用 TWRP 刷回备份的 boot 分区
```

**刷内核前务必备份 `boot` 与 `super`**，MT6889 变砖后极难救回。

---

*本仓库基于公开资料整理，所有来源免费开源。未在真机上验证刷入结果——刷机有风险，务必先备份。*
