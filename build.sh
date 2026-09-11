#!/usr/bin/env bash

set -euo pipefail

TARGET=""
KSU_BRANCH=""
SUSFS_COMMIT=""
KERNEL_NAME_OVERRIDE=""

usage() {
  cat <<EOF
Usage: $0 --target <6.12|cass> [options]

Options:
  --target <6.12|cass>     Which kernel source branch to build (required)
  --ksu-branch <ref>       KernelSU-Next branch/commit (default: dev-susfs tip)
  --susfs-commit <sha>     SUSFS commit on gki-android16-6.12 (default: latest)
  --kernel-name <tag>      Override the "Kinosaki-Bore" branding tag
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --ksu-branch) KSU_BRANCH="$2"; shift 2 ;;
    --susfs-commit) SUSFS_COMMIT="$2"; shift 2 ;;
    --kernel-name) KERNEL_NAME_OVERRIDE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ "$TARGET" != "6.12" && "$TARGET" != "cass" ]]; then
  echo "ERROR: --target must be '6.12' or 'cass' (got: '${TARGET:-<empty>}')" >&2
  usage
  exit 1
fi

# only the upstream kernel/common branch differs.
CUSTOM_REPO="https://github.com/Cartethyiaaa/android_kernel_common-5.10"
ANDROID_VERSION="android16"
KERNEL_VERSION="6.12"
MANIFEST_SUBLEVEL="38"
OS_PATCH_LEVEL="2025-09"
VERSION="${ANDROID_VERSION}-${KERNEL_VERSION}"   # android16-6.12

if [[ "$TARGET" == "6.12" ]]; then
  CUSTOM_BRANCH="6.12"
else
  CUSTOM_BRANCH="cass"
fi

WORKSPACE="$(pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="${SCRIPT_DIR}/patches"
KERNEL_DIR="${WORKSPACE}/kernel"
OUT_DIR="/home/runner/out"
AK3_DIR="${WORKSPACE}/AnyKernel3"

log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m[warn] $*\033[0m"; }

# Setup build environment
setup_build_environment() {
  log "Setting up build environment"

  git config --global user.name "kinosaki-bot"
  git config --global user.email "kinosaki-bot@users.noreply.github.com"

  mkdir -p "$KERNEL_DIR"

  if ! command -v repo >/dev/null 2>&1; then
    mkdir -p "${WORKSPACE}/git-repo"
    curl -L https://storage.googleapis.com/git-repo-downloads/repo -o "${WORKSPACE}/git-repo/repo"
    chmod +x "${WORKSPACE}/git-repo/repo"
    export PATH="${WORKSPACE}/git-repo:${PATH}"
  fi

  rm -rf "${WORKSPACE}/kernel_patches"
  git clone --depth=1 https://github.com/WildKernels/kernel_patches.git "${WORKSPACE}/kernel_patches"

  rm -rf "$AK3_DIR"
  git clone --depth=1 https://github.com/Cartethyiaaa/AnyKernel3.git -b gki-2.0 "$AK3_DIR"

  sudo apt-get update -qq
  sudo apt-get install -y -qq dwarves libelf-dev
}

# Sync kernel source
download_kernel() {
  log "Downloading AOSP GKI manifest ($VERSION, os_patch_level=$OS_PATCH_LEVEL)"

  local formatted_branch="${ANDROID_VERSION}-${KERNEL_VERSION}-${OS_PATCH_LEVEL}"

  cd "$KERNEL_DIR"

  init_repo() {
    repo init -u https://android.googlesource.com/kernel/manifest \
      -b "common-${formatted_branch}" --depth=1
    local remote_branch
    remote_branch=$(git ls-remote https://android.googlesource.com/kernel/common "${formatted_branch}")
    if grep -q deprecated <<<"$remote_branch"; then
      sed -i "s/\"${formatted_branch}\"/\"deprecated\/${formatted_branch}\"/g" .repo/manifests/default.xml
      warn "Branch ${formatted_branch} is deprecated upstream."
    fi
  }

  init_repo

  local max_retries=3 attempt=1
  while (( attempt <= max_retries )); do
    echo "repo sync attempt ${attempt}/${max_retries}..."
    if timeout 15m repo sync -c --current-branch --no-clone-bundle --no-tags --jobs-checkout=4 -j4; then
      break
    fi
    if (( attempt < max_retries )); then
      rm -rf .repo
      sleep 15
      init_repo
    else
      echo "ERROR: repo sync failed after ${max_retries} attempts" >&2
      exit 1
    fi
    attempt=$((attempt + 1))
  done

  log "Overriding kernel/common with ${CUSTOM_REPO} (branch: ${CUSTOM_BRANCH})"
  rm -rf common

  local clone_attempt=1
  while (( clone_attempt <= 3 )); do
    if git clone --branch "$CUSTOM_BRANCH" --depth=1 "$CUSTOM_REPO" common; then
      break
    fi
    rm -rf common
    if (( clone_attempt == 3 )); then
      echo "ERROR: failed to clone ${CUSTOM_REPO} (${CUSTOM_BRANCH})" >&2
      exit 1
    fi
    clone_attempt=$((clone_attempt + 1))
    sleep 10
  done

  echo "kernel/common HEAD: $(git -C common rev-parse HEAD)"
}

# Build timestamp
BUILD_EPOCH=""
KERNEL_NAME_TAG=""
set_build_timestamp() {
  log "Setting build timestamp / branding tag"
  BUILD_EPOCH=$(date -u +%s)
  export SOURCE_DATE_EPOCH="$BUILD_EPOCH"
  export KBUILD_BUILD_TIMESTAMP
  KBUILD_BUILD_TIMESTAMP=$(date -u -d "@${BUILD_EPOCH}" '+%a %b %d %H:%M:%S UTC %Y')
  export GIT_COMMITTER_DATE GIT_AUTHOR_DATE
  GIT_COMMITTER_DATE=$(date -u -d "@${BUILD_EPOCH}" '+%Y-%m-%dT%H:%M:%SZ')
  GIT_AUTHOR_DATE="$GIT_COMMITTER_DATE"

  if [[ -n "$KERNEL_NAME_OVERRIDE" ]]; then
    KERNEL_NAME_TAG=$(echo "$KERNEL_NAME_OVERRIDE" | sed 's/[^A-Za-z0-9._-]/-/g')
  else
    if [[ "$TARGET" == "6.12" ]]; then
      KERNEL_NAME_TAG="Kinosaki-BORE"
    else
      KERNEL_NAME_TAG="Kinosaki-CASS"
    fi
  fi
  echo "Kernel branding tag: $KERNEL_NAME_TAG"
}

# Extract sublevel
SUBLEVEL=""
FILE_NAME=""
extract_sublevel_and_name() {
  log "Extracting sublevel / composing file name"
  SUBLEVEL="$MANIFEST_SUBLEVEL"
  if [[ -f "${KERNEL_DIR}/common/Makefile" ]]; then
    local extracted
    extracted=$(grep '^SUBLEVEL = ' "${KERNEL_DIR}/common/Makefile" | awk '{print $3}')
    [[ -n "$extracted" ]] && SUBLEVEL="$extracted"
  fi

  local stamp
  stamp=$(date -u -d "@${BUILD_EPOCH}" '+%Y%m%d-%H%M')

  local label
    label="${KERNEL_VERSION}.${SUBLEVEL}"

  FILE_NAME="AK3-${label}-${KERNEL_NAME_TAG}-${stamp}"
  echo "File name: $FILE_NAME"
}

# Kernel fixes
apply_kernel_fixes() {
  log "Applying kernel fixes"
  cd "${KERNEL_DIR}/common"

  local glibc_version
  glibc_version="$(ldd --version 2>/dev/null | head -n1 | awk '{print $NF}')"
  if [[ "$(printf '%s\n' "2.38" "$glibc_version" | sort -V | head -n1)" == "2.38" ]]; then
    echo "GLIBC ${glibc_version} >= 2.38, checking resolve_btfids Makefile..."
    if grep -q '$(Q)$(MAKE) -C $(SUBCMD_SRC) OUTPUT=$(abspath $(dir $@))/ $(abspath $@)' tools/bpf/resolve_btfids/Makefile; then
      sed -i '/\$(Q)\$(MAKE) -C \$(SUBCMD_SRC) OUTPUT=\$(abspath \$(dir \$@))\/ \$(abspath \$@)/s//$(Q)$(MAKE) -C $(SUBCMD_SRC) EXTRA_CFLAGS="$(CFLAGS)" OUTPUT=$(abspath $(dir $@))\/ $(abspath $@)/' tools/bpf/resolve_btfids/Makefile
      echo "  -> Makefile EXTRA_CFLAGS fix applied"
    else
      echo "  -> pattern not found / already fixed, skipping"
    fi
  else
    echo "GLIBC ${glibc_version} < 2.38, skipping resolve_btfids Makefile fix"
  fi
}

apply_kconfig() {
  local defconfig="${KERNEL_DIR}/common/arch/arm64/configs/gki_defconfig"
  if [[ ! -f "$defconfig" ]]; then
    echo "ERROR: gki_defconfig not found" >&2
    exit 1
  fi
  while IFS= read -r line; do
    line="$(echo "$line" | xargs)"
    [[ -z "$line" || "$line" == \#* ]] && continue
    local key value
    if [[ "$line" == *"="* ]]; then
      key="${line%%=*}"; value="${line#*=}"
    else
      key="$line"; value="y"
    fi
    if grep -q "^${key}=" "$defconfig"; then
      sed -i "s|^${key}=.*|${key}=${value}|g" "$defconfig"
    elif grep -q "^# ${key} is not set" "$defconfig"; then
      sed -i "s|^# ${key} is not set|${key}=${value}|g" "$defconfig"
    else
      echo "${key}=${value}" >> "$defconfig"
    fi
  done <<< "$1"
}

# KernelSU-Next
KSU_VERSION=""
KSU_GIT_TAG=""
setup_kernelsu() {
  log "Setting up KernelSU-Next"
  cd "$KERNEL_DIR"

  local ksu_repo="https://github.com/pershoot/KernelSU-Next.git"
  local ksu_input="${KSU_BRANCH:-dev-susfs}"

  curl -LSs "https://raw.githubusercontent.com/pershoot/KernelSU-Next/dev-susfs/kernel/setup.sh" | bash -s dev-susfs
  git -C KernelSU-Next/kernel fetch --depth=50 origin "$ksu_input"
  if git ls-remote --heads "$ksu_repo" "$ksu_input" | grep -q .; then
    git -C KernelSU-Next/kernel checkout "origin/${ksu_input}"
  else
    git -C KernelSU-Next/kernel checkout "$ksu_input"
  fi

  cd KernelSU-Next/kernel
  local commits_count base_version=30000
  commits_count=$(git rev-list --count HEAD)
  KSU_VERSION=$((commits_count + base_version))
  sed -i "s/^KSU_VERSION_FALLBACK := 1$/KSU_VERSION_FALLBACK := ${KSU_VERSION}/" Kbuild

  KSU_GIT_TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo v0.0.1)"
  sed -i "s/^KSU_VERSION_TAG_FALLBACK := v0.0.1$/KSU_VERSION_TAG_FALLBACK := ${KSU_GIT_TAG}/" Kbuild

  cd "${KERNEL_DIR}/KernelSU-Next"
  patch -p1 < "${PATCH_DIR}/kernelsu-static.patch"

  apply_kconfig "CONFIG_KSU=y"
  echo "KSU version: $KSU_VERSION (tag: $KSU_GIT_TAG)"
}

# SUSFS
SUSFS_VERSION=""
setup_susfs() {
  log "Setting up SUSFS"
  cd "$WORKSPACE"

  local susfs_branch="gki-${VERSION}"   # gki-android16-6.12
  rm -rf susfs4ksu
  git clone "https://gitlab.com/simonpunk/susfs4ksu.git" -b "$susfs_branch" susfs4ksu

  if [[ -n "$SUSFS_COMMIT" ]]; then
    git -C susfs4ksu checkout "$SUSFS_COMMIT"
  fi

  cd susfs4ksu
  patch -p1 < "${WORKSPACE}/kernel_patches/pershoot/susfs4ksu/0001-pershoot-Allow-core-to-be-built-with-no-features.patch"
  patch -p1 < "${WORKSPACE}/kernel_patches/pershoot/susfs4ksu/0002-pershoot-Implement-SuSFS-and-Toolkit-coexistence.patch"

  apply_kconfig "$(cat <<'EOF'
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
EOF
)"

  cd "${KERNEL_DIR}/common"
  cp "${WORKSPACE}/susfs4ksu/kernel_patches/fs/"* fs/
  cp "${WORKSPACE}/susfs4ksu/kernel_patches/include/linux/"* include/linux/
  cp "${WORKSPACE}/susfs4ksu/kernel_patches/50_add_susfs_in_gki-${VERSION}.patch" ./

  # android16-6.12 fake patches
  if [[ "$SUBLEVEL" -ge 58 ]]; then
    echo "Applying exec.c android16-6.12 fake patch"
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/exec.c
  fi
  if [[ "$SUBLEVEL" -ge 69 ]]; then
    echo "Applying task_mmu.c android16-6.12 fake patch"
    sed -i 's/vma_data_pages/vma_pages/g' fs/proc/task_mmu.c
  fi

  # apply the real SUSFS patch
  patch -p1 < "50_add_susfs_in_gki-${VERSION}.patch"

  # VMA_PAD_START() fallback
  if grep -q 'VMA_PAD_START(' fs/proc/task_mmu.c && \
     ! grep -qE '#include <linux/pgsize_migration(_inline)?\.h>|define VMA_PAD_START' fs/proc/task_mmu.c; then
    sed -i '1a #ifndef VMA_PAD_START\n#define VMA_PAD_START(vma) ((vma)->vm_end)\n#endif' fs/proc/task_mmu.c
    echo "Added VMA_PAD_START fallback definition"
  fi

  # __fold_filemap_fixup_entry() fallback
  if grep -q '__fold_filemap_fixup_entry' fs/proc/task_mmu.c && \
     ! grep -q '#include <linux/page_size_compat.h>' fs/proc/task_mmu.c; then
    sed -i '/#include <linux\/pkeys.h>/a #include <linux/page_size_compat.h>' fs/proc/task_mmu.c
    echo "Added page_size_compat.h include"
  fi

  # revert the android16-6.12 fake patches now that the real patch applied
  if [[ "$SUBLEVEL" -ge 58 ]]; then
    echo "Reverting exec.c android16-6.12 fake patch"
    sed -i '/^#include /a #include <linux/dma-buf.h>' fs/exec.c
  fi
  if [[ "$SUBLEVEL" -ge 69 ]]; then
    echo "Reverting task_mmu.c android16-6.12 fake patch"
    sed -i 's/vma_pages/vma_data_pages/g' fs/proc/task_mmu.c
  fi

  if [[ -f include/linux/susfs.h ]]; then
    SUSFS_VERSION=$(grep '#define SUSFS_VERSION' include/linux/susfs.h | awk -F'"' '{print $2}' || echo "N/A")
  fi
  echo "SUSFS version: ${SUSFS_VERSION:-N/A}"
}

# Baseband Guard
setup_bbg() {
  log "Setting up Baseband Guard"
  cd "$KERNEL_DIR"
  wget -O- https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh | bash

  sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' common/security/Kconfig

  if ! grep -q "baseband_guard" common/security/Kconfig; then
    echo "ERROR: baseband_guard not found in common/security/Kconfig" >&2
    exit 1
  fi

  apply_kconfig "CONFIG_BBG=y"
}

# Networking
setup_networking() {
  log "Setting up networking configs"

  apply_kconfig "$(cat <<'EOF'
CONFIG_IP_SET=y
CONFIG_IP_SET_MAX=65534
CONFIG_IP_SET_BITMAP_IP=y
CONFIG_IP_SET_BITMAP_IPMAC=y
CONFIG_IP_SET_BITMAP_PORT=y
CONFIG_IP_SET_HASH_IP=y
CONFIG_IP_SET_HASH_IPMARK=y
CONFIG_IP_SET_HASH_IPPORT=y
CONFIG_IP_SET_HASH_IPPORTIP=y
CONFIG_IP_SET_HASH_IPPORTNET=y
CONFIG_IP_SET_HASH_IPMAC=y
CONFIG_IP_SET_HASH_MAC=y
CONFIG_IP_SET_HASH_NETPORTNET=y
CONFIG_IP_SET_HASH_NET=y
CONFIG_IP_SET_HASH_NETNET=y
CONFIG_IP_SET_HASH_NETPORT=y
CONFIG_IP_SET_HASH_NETIFACE=y
CONFIG_IP_SET_LIST_SET=y
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_NETFILTER_XT_SET=y
CONFIG_NETFILTER_XT_TARGET_LOG=y
CONFIG_NETFILTER_XT_MATCH_RECENT=y
CONFIG_IP6_NF_NAT=y
CONFIG_IP6_NF_TARGET_MASQUERADE=y
CONFIG_TCP_CONG_ADVANCED=y
CONFIG_TCP_CONG_BBR=y
CONFIG_TCP_CONG_CUBIC=y
CONFIG_TCP_CONG_BIC=y
CONFIG_TCP_CONG_WESTWOOD=y
CONFIG_TCP_CONG_HTCP=y
CONFIG_DEFAULT_BBR=y
CONFIG_DEFAULT_TCP_CONG="bbr"
CONFIG_NET_SCH_FQ=y
CONFIG_NET_SCH_FQ_CODEL=y
CONFIG_NET_SCH_CAKE=y
CONFIG_NET_ACT_CONNMARK=y
CONFIG_IP_NF_TARGET_TTL=y
CONFIG_IP6_NF_TARGET_HL=y
CONFIG_IP6_NF_MATCH_HL=y
CONFIG_WIREGUARD=y
CONFIG_CIFS=y
CONFIG_NETWORK_FILESYSTEMS=y
CONFIG_NETFS_SUPPORT=y
CONFIG_KEYS=y
CONFIG_CIFS_XATTR=y
CONFIG_CIFS_POSIX=y
EOF
)"

  # CIFS fix for android16-6.12
  cd "${KERNEL_DIR}/common"
  sed -i '/"fs\/netfs\/netfs\.ko",/d' modules.bzl
}

# DroidSpaces-OSS
setup_droidspaces() {
  log "Setting up DroidSpaces-OSS"
  cd "$WORKSPACE"
  rm -rf Droidspaces-OSS
  git clone --depth=1 https://github.com/ravindu644/Droidspaces-OSS.git

  cd "${KERNEL_DIR}/common"
  cp "${WORKSPACE}/Droidspaces-OSS/Documentation/resources/kernel-patches/GKI/kernel-6.12/001.GKI-6.12-or-above-fix_sysvipc_kabi.patch" ./
  patch -p1 < 001.GKI-6.12-or-above-fix_sysvipc_kabi.patch

  {
    echo
    echo 'EXPORT_SYMBOL_GPL(put_ipc_ns);'
  } >> "${KERNEL_DIR}/common/ipc/namespace.c"
  {
    echo
    echo 'EXPORT_SYMBOL_GPL(init_ipc_ns);'
  } >> "${KERNEL_DIR}/common/ipc/msgutil.c"

  apply_kconfig "$(cat <<'EOF'
CONFIG_PID_NS=y
CONFIG_SYSVIPC=y
CONFIG_POSIX_MQUEUE=y
CONFIG_IPC_NS=y
CONFIG_DEVTMPFS=y
CONFIG_BINFMT_MISC=y
CONFIG_BINFMT_SCRIPT=y
CONFIG_BINFMT_ELF=y
CONFIG_USER_NS=y
EOF
)"
}

# NTSync
setup_ntsync() {
  log "Applying NTSync patches"
  cd "${KERNEL_DIR}/common"

  echo "Removing pre-existing ntsync files for android16-6.12"
  rm -f include/uapi/linux/ntsync.h
  rm -f drivers/misc/ntsync.c

  patch -p1 < "${WORKSPACE}/kernel_patches/common/ntsync/ntsync_compat_${VERSION}.patch"
  patch -p1 < "${WORKSPACE}/kernel_patches/common/ntsync/ntsync_base.patch"

  apply_kconfig "CONFIG_NTSYNC=y"
}

# Ptrace patch
apply_ptrace_patch() {
  log "Checking ptrace patch (kernel ${KERNEL_VERSION})"
  if [[ "$(printf '%s\n' "$KERNEL_VERSION" "5.16" | sort -V | head -n1)" == "$KERNEL_VERSION" ]]; then
    cd "${KERNEL_DIR}/common"
    patch -p1 -F3 < "${WORKSPACE}/kernel_patches/gki_ptrace.patch"
  else
    echo "Kernel >= 5.16, skipping ptrace patch"
  fi
}

# Unicode fix
apply_unicode_fix() {
  log "Applying unicode fix patch"
  cd "${KERNEL_DIR}/common"
  if [[ "$(printf '%s\n' "$KERNEL_VERSION" "5.16" | sort -V | head -n1)" == "$KERNEL_VERSION" ]]; then
    patch -p1 --forward < "${WORKSPACE}/kernel_patches/common/unicode_bypass_fix_6.1-.patch"
  else
    patch -p1 --forward < "${WORKSPACE}/kernel_patches/common/unicode_bypass_fix_6.1+.patch"
  fi
}

# Misc configs
setup_misc_and_btf() {
  log "Setting up misc kernel configs"
  apply_kconfig "$(cat <<'EOF'
CONFIG_OVERLAY_FS=y
CONFIG_TMPFS_XATTR=y
CONFIG_TMPFS_POSIX_ACL=y
CONFIG_KALLSYMS=y
CONFIG_KALLSYMS_ALL=y
CONFIG_BPF_EVENTS=y
CONFIG_KPROBE_EVENTS=y
CONFIG_UPROBES=y
CONFIG_UPROBE_EVENTS=y
CONFIG_FUSE_BPF=y
CONFIG_ADIOS=y
CONFIG_DEBUG_INFO_BTF=y
EOF
)"
}

# Kernel branding
apply_kernel_branding() {
  log "Applying kernel branding: $KERNEL_NAME_TAG"
  cd "${KERNEL_DIR}/common"
  local kernel_string="${KERNEL_VERSION}.${SUBLEVEL}-${ANDROID_VERSION}"
  sed -i '$d' scripts/setlocalversion
  echo "echo \"${kernel_string}-${KERNEL_NAME_TAG}\"" >> scripts/setlocalversion
  chmod +x scripts/setlocalversion
}

# Remove protected exports
remove_protected_exports() {
  cd "$KERNEL_DIR"
  if [[ -f "build/build.sh" ]]; then
    echo "Legacy build system detected, skipping protected-exports removal"
    return
  fi

  log "Removing protected exports (Bazel)"
  rm -rf common/android/abi_gki_protected_exports_*

  if grep -q '"protected_exports_list"[[:space:]]*:[[:space:]]*"android/abi_gki_protected_exports_aarch64"' common/BUILD.bazel; then
    perl -pi -e 's/^\s*"protected_exports_list"\s*:\s*"android\/abi_gki_protected_exports_aarch64",\s*$//;' common/BUILD.bazel
  fi

  if grep -q '^protected_modules = ' common/modules.bzl; then
    sed -i 's/protected_modules = \[.*\]/protected_modules = []/' common/modules.bzl
  fi

  if grep -q 'protected_module_names_list' common/BUILD.bazel; then
    perl -pi -e 's/^\s*protected_module_names_list\s*=\s*":gki_(?:aarch64|x86_64)_protected_module_names",\s*$//;' common/BUILD.bazel
  fi
}

# Clean dirty flags
clean_kernel_flags() {
  log "Cleaning dirty flags"
  cd "$KERNEL_DIR"
  if [[ -f "build/build.sh" ]]; then
    sed -i 's/-dirty//' common/scripts/setlocalversion
  else
    sed -i "/stable_scmversion_cmd/s/-maybe-dirty//g" build/kernel/kleaf/impl/stamp.bzl
    sed -i 's/-dirty//' common/scripts/setlocalversion
  fi

  cd "${KERNEL_DIR}/common"
  git add -A
  git -c user.name="kinosaki-bot" -c user.email="kinosaki-bot@users.noreply.github.com" \
    commit -m "Kinosaki: clean dirty flag" --quiet || true
}

# Build kernel (Normal, then Bypass)
build_variant() {
  local bypass="$1"   # "true" | "false"
  log "Building kernel (bypass=${bypass})"
  cd "$KERNEL_DIR"

  if [[ "$bypass" == "true" ]]; then
    local target_file="common/kernel/module/version.c"
    sed -i '/bad_version:/{:a;n;/return 0;/{s/return 0;/return 1;/;b};ba}' "$target_file"
    if ! grep -A5 "bad_version:" "$target_file" | grep -q "return 1;"; then
      echo "ERROR: bypass patch failed on $target_file" >&2
      exit 1
    fi
  fi

  sed -i 's/check_defconfig//' ./common/build.config.gki

  if [[ -f "build/build.sh" ]]; then
    BUILD_GKI_ARTIFACTS="" \
    BUILD_GKI_CERTIFICATION_TOOLS=0 \
    BUILD_SYSTEM_DLKM=0 \
    SKIP_VENDOR_BOOT=1 \
    SKIP_EXT_MODULES=1 \
    SKIP_CP_KERNEL_HDR=1 \
    OUT_DIR="$OUT_DIR" \
    LTO=thin \
    BUILD_CONFIG=common/build.config.gki.aarch64 \
    build/build.sh -j"$(nproc)" \
    CC="ccache clang" CXX="ccache clang++" HOSTCC="ccache clang" HOSTCXX="ccache clang++"
  else
    if [[ "$bypass" == "false" ]] && ! grep -q 'check_defconfig = "disabled"' common/BUILD.bazel; then
      sed -i '/name = "kernel_aarch64",/a\    check_defconfig = "disabled",' common/BUILD.bazel
    fi
    tools/bazel build \
      --config=fast \
      --config=stamp \
      --disk_cache="${HOME}/.cache/bazel" \
      //common:kernel_aarch64/Image
  fi

  local image_out=""
  if [[ -f "bazel-bin/common/kernel_aarch64/Image" ]]; then
    image_out="bazel-bin/common/kernel_aarch64/Image"
  elif [[ -f "${OUT_DIR}/dist/Image" ]]; then
    image_out="${OUT_DIR}/dist/Image"
  else
    echo "ERROR: could not find built Image" >&2
    exit 1
  fi

  if [[ "$bypass" == "true" ]]; then
    cp "$image_out" "${AK3_DIR}/Bypass-Image"
    cp "${PATCH_DIR}/anykernel3-bypass.patch" "${AK3_DIR}/bypass.patch"
    (cd "$AK3_DIR" && patch -p1 < bypass.patch)
  else
    cp "$image_out" "${AK3_DIR}/Image"
  fi
}

build_kernel() {
  touch "${WORKSPACE}/wild_gki.fragment"
  build_variant "false"
  build_variant "true"
}

scan_patch_rejects() {
  log "Scanning for .rej files"
  local rejects_dir="${WORKSPACE}/patch-rejects"
  mkdir -p "$rejects_dir"
  local rej_count=0
  while IFS= read -r rej; do
    local rel="${rej#"$KERNEL_DIR"/}"
    [[ "$(basename "$rel")" == "i2c-nomadik.c.rej" ]] && continue
    mkdir -p "$(dirname "${rejects_dir}/${rel}")"
    cp "$rej" "${rejects_dir}/${rel}"
    rej_count=$((rej_count + 1))
  done < <(find "$KERNEL_DIR" -type f -name '*.rej' 2>/dev/null || true)

  if (( rej_count > 0 )); then
    warn "${rej_count} patch reject(s) found — see ${rejects_dir}"
  else
    echo "No patch rejects."
    rmdir "$rejects_dir" 2>/dev/null || true
  fi
}

package_output() {
  log "Packaging AnyKernel3 as ${FILE_NAME}.zip"
  mkdir -p "${WORKSPACE}/out"
  local zip_path="${WORKSPACE}/out/${FILE_NAME}.zip"
  rm -f "$zip_path"
  ( cd "$AK3_DIR" && zip -r -q -9 "$zip_path" . -x '.git/*' )
  echo "Built: $zip_path"
}

# Main
main() {
  echo "============================================================"
  echo " Kinosaki Kernel build — target: ${TARGET} (${VERSION}, branch ${CUSTOM_BRANCH})"
  echo "============================================================"

  setup_build_environment
  download_kernel
  set_build_timestamp
  extract_sublevel_and_name
  apply_kernel_fixes
  setup_kernelsu
  setup_susfs
  setup_bbg
  setup_networking
  setup_droidspaces
  setup_ntsync
  apply_ptrace_patch
  apply_unicode_fix
  setup_misc_and_btf
  apply_kernel_branding
  remove_protected_exports
  clean_kernel_flags
  scan_patch_rejects
  build_kernel
  package_output

  echo
  echo "============================================================"
  echo " Done. KSU=${KSU_VERSION:-N/A} (${KSU_GIT_TAG:-N/A})  SUSFS=${SUSFS_VERSION:-N/A}"
  echo " Output: ${WORKSPACE}/out/${FILE_NAME}.zip"
  echo "============================================================"
}

main "$@"
