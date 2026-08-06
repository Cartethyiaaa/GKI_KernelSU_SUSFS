#!/usr/bin/env bash
# =============================================================================
#  build.sh — GKI android16-6.12 + KernelSU-Next + SUSFS (Bazel/Kleaf)
#  Consolidated from GKI_KernelSU_SUSFS-main/.github/{workflows,actions}
#  All logic from: main.yml -> prepare.yml -> build.yml -> (20+ composite
#  actions) is flattened into this one script. Only the android16-6.12
#  code path is kept live (that's the only target this repo builds for);
#  branches that only ever fired for android12/13/14/15 kernels are left
#  out on purpose — they never ran for 6.12 anyway.
#
#  Usage:
#    ./build.sh
#
#  Tunables (env vars, all optional):
#    FEATURE_SET   KSUN+SUSFS+BBG+NET+DS (default) | any subset | FULL | NONE
#    KSU_BRANCH    KernelSU-Next branch/commit   (default: dev-susfs tip)
#    SUSFS_COMMIT  susfs4ksu commit              (default: gki-android16-6.12 tip)
#    KERNEL_NAME   custom name tag               (default: Mahirooo)
#    OS_PATCH_LEVEL / MANIFEST_SUBLEVEL           (default: 2025-09 / 38)
#    CUSTOM_REPO / CUSTOM_BRANCH                  kernel/common source override
#    WORKSPACE     build workspace dir            (default: $PWD/gki-build)
#    JOBS          parallel jobs                  (default: nproc)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Config
# ---------------------------------------------------------------------------
ANDROID_VERSION="android16"
KERNEL_VERSION="6.12"
VERSION="${ANDROID_VERSION}-${KERNEL_VERSION}"

OS_PATCH_LEVEL="${OS_PATCH_LEVEL:-2025-09}"
MANIFEST_SUBLEVEL="${MANIFEST_SUBLEVEL:-38}"
CUSTOM_REPO="${CUSTOM_REPO:-https://github.com/Cartethyiaaa/android_kernel_common-5.10}"
CUSTOM_BRANCH="${CUSTOM_BRANCH:-6.12}"

FEATURE_SET="${FEATURE_SET:-KSUN+SUSFS+BBG+NET+DS}"
KSU_BRANCH="${KSU_BRANCH:-}"
SUSFS_COMMIT="${SUSFS_COMMIT:-}"
KERNEL_NAME="${KERNEL_NAME:-}"

JOBS="${JOBS:-$(nproc)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="${SCRIPT_DIR}/patched"
WORKSPACE="${WORKSPACE:-${SCRIPT_DIR}/gki-build}"
OUT_DIR="${WORKSPACE}/out"

feat() { [[ "$FEATURE_SET" == "FULL" || "$FEATURE_SET" == *"$1"* ]]; }

mkdir -p "$WORKSPACE" "$OUT_DIR"
cd "$WORKSPACE"

echo "==> Target: $VERSION | os_patch_level=$OS_PATCH_LEVEL | features=$FEATURE_SET"

# ---------------------------------------------------------------------------
# 1. Setup build environment  (was: actions/setup-build-environment)
# ---------------------------------------------------------------------------
setup_build_environment() {
  echo "::group::Setup build environment"
  git config --global user.name  "github-actions[bot]"
  git config --global user.email "github-actions[bot]@users.noreply.github.com"

  mkdir -p "${WORKSPACE}/kernel" "${WORKSPACE}/git-repo"
  curl -L https://storage.googleapis.com/git-repo-downloads/repo -o "${WORKSPACE}/git-repo/repo"
  chmod +x "${WORKSPACE}/git-repo/repo"
  export PATH="${WORKSPACE}/git-repo:$PATH"

  rm -rf "${WORKSPACE}/kernel_patches"
  git clone --depth=50 https://github.com/WildKernels/kernel_patches.git "${WORKSPACE}/kernel_patches"

  rm -rf "${WORKSPACE}/AnyKernel3"
  git clone https://github.com/WildKernels/AnyKernel3.git -b gki-2.0 "${WORKSPACE}/AnyKernel3"

  sudo apt-get update -qq
  sudo apt-get install -y -qq dwarves libelf-dev bc bison flex libssl-dev \
    build-essential python3 python3-pip curl git zip unzip ccache
  echo "::endgroup::"
}

# ---------------------------------------------------------------------------
# 2. Sync kernel source via repo, then override kernel/common with custom repo
#    (was: actions/download-kernel)
# ---------------------------------------------------------------------------
download_kernel() {
  echo "::group::Download kernel source"
  local formatted_branch="${ANDROID_VERSION}-${KERNEL_VERSION}-${OS_PATCH_LEVEL}"
  cd "${WORKSPACE}/kernel"

  init_repo() {
    repo init -u https://android.googlesource.com/kernel/manifest \
      -b "common-${formatted_branch}" --depth=1
    if git ls-remote https://android.googlesource.com/kernel/common "${formatted_branch}" | grep -q deprecated; then
      sed -i "s/\"${formatted_branch}\"/\"deprecated\/${formatted_branch}\"/g" .repo/manifests/default.xml
      echo "⚠ Branch ${formatted_branch} is deprecated."
    fi
  }
  init_repo

  local attempt=1 max=3
  while [ $attempt -le $max ]; do
    echo "repo sync attempt $attempt/$max..."
    if timeout 15m repo sync -c --current-branch --no-clone-bundle --no-tags --jobs-checkout=4 -j4; then
      break
    fi
    [ $attempt -eq $max ] && { echo "repo sync failed after $max attempts" >&2; exit 1; }
    rm -rf .repo; sleep 15; init_repo
    attempt=$((attempt+1))
  done

  if [ -n "$CUSTOM_REPO" ]; then
    echo "Overriding kernel/common with $CUSTOM_REPO ($CUSTOM_BRANCH)"
    rm -rf common
    git clone --branch "$CUSTOM_BRANCH" --depth=1 "$CUSTOM_REPO" common
  fi
  echo "::endgroup::"
}

# ---------------------------------------------------------------------------
# helper: patch gki_defconfig directly (was: actions/set-kernel-config)
# ---------------------------------------------------------------------------
set_kernel_config() {
  local defconfig="${WORKSPACE}/kernel/common/arch/arm64/configs/gki_defconfig"
  while IFS= read -r line; do
    line="$(echo "$line" | xargs)"
    [[ -z "$line" || "$line" == \#* ]] && continue
    local key value
    if [[ "$line" == *"="* ]]; then key="${line%%=*}"; value="${line#*=}"; else key="$line"; value="y"; fi
    if grep -q "^$key=" "$defconfig"; then
      sed -i "s|^$key=.*|$key=$value|g" "$defconfig"
    elif grep -q "^# $key is not set" "$defconfig"; then
      sed -i "s|^# $key is not set|$key=$value|g" "$defconfig"
    else
      echo "$key=$value" >> "$defconfig"
    fi
  done <<< "$1"
}

# ---------------------------------------------------------------------------
# 3. Build timestamp + kernel name tag  (was: inline step in build.yml)
# ---------------------------------------------------------------------------
set_timestamp_and_name() {
  export SOURCE_DATE_EPOCH; SOURCE_DATE_EPOCH=$(date -u +%s)
  export KBUILD_BUILD_TIMESTAMP; KBUILD_BUILD_TIMESTAMP=$(date -u -d @"$SOURCE_DATE_EPOCH" '+%a %b %d %H:%M:%S UTC %Y')
  export GIT_COMMITTER_DATE GIT_AUTHOR_DATE
  GIT_COMMITTER_DATE=$(date -u -d @"$SOURCE_DATE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')
  GIT_AUTHOR_DATE="$GIT_COMMITTER_DATE"

  if [ -n "$KERNEL_NAME" ]; then
    KERNEL_NAME_TAG="$(echo "$KERNEL_NAME" | sed 's/[^A-Za-z0-9._-]/-/g')-RE"
  else
    KERNEL_NAME_TAG="Mahirooo"
  fi
  export KERNEL_NAME_TAG
  echo "Kernel name tag: $KERNEL_NAME_TAG"
}

# ---------------------------------------------------------------------------
# 4. Extract sublevel + compose FILE_NAME  (was: extract-sublevel-file-name)
# ---------------------------------------------------------------------------
extract_sublevel_file_name() {
  SUBLEVEL="$MANIFEST_SUBLEVEL"
  local mk="${WORKSPACE}/kernel/common/Makefile"
  if [ -f "$mk" ]; then
    local e; e="$(grep '^SUBLEVEL = ' "$mk" | awk '{print $3}')"
    [ -n "$e" ] && SUBLEVEL="$e"
  fi
  FILE_NAME="${KERNEL_VERSION}.${SUBLEVEL}-${ANDROID_VERSION}-${KERNEL_NAME_TAG}"
  export SUBLEVEL FILE_NAME
  echo "File name: $FILE_NAME (sublevel $SUBLEVEL)"
}

# ---------------------------------------------------------------------------
# 5. KernelSU-Next  (was: actions/kernelsu)
# ---------------------------------------------------------------------------
setup_kernelsu() {
  echo "::group::Setup KernelSU-Next"
  cd "${WORKSPACE}/kernel"
  local ksu_repo="https://github.com/pershoot/KernelSU-Next.git"
  local ksu_input="${KSU_BRANCH:-dev-susfs}"

  curl -LSs "https://raw.githubusercontent.com/pershoot/KernelSU-Next/dev-susfs/kernel/setup.sh" | bash -s dev-susfs
  git -C KernelSU-Next/kernel fetch --depth=50 origin "$ksu_input"
  if git ls-remote --heads "$ksu_repo" "$ksu_input" | grep -q .; then
    git -C KernelSU-Next/kernel checkout "origin/$ksu_input"
  else
    git -C KernelSU-Next/kernel checkout "$ksu_input"
  fi

  cd KernelSU-Next/kernel
  local commits base=30000 ksu_version
  commits=$(git rev-list --count HEAD)
  ksu_version=$((commits + base))
  sed -i "s/^KSU_VERSION_FALLBACK := 1$/KSU_VERSION_FALLBACK := ${ksu_version}/" Kbuild
  local ksu_tag; ksu_tag="$(git describe --tags --abbrev=0 2>/dev/null || echo v0.0.1)"
  sed -i "s/^KSU_VERSION_TAG_FALLBACK := v0.0.1$/KSU_VERSION_TAG_FALLBACK := ${ksu_tag}/" Kbuild

  cd "${WORKSPACE}/kernel/KernelSU-Next"
  cp "${PATCH_DIR}/kernelsu-static.patch" ./static.patch
  patch -p1 < static.patch

  set_kernel_config "CONFIG_KSU=y"
  echo "::endgroup::"
}

# ---------------------------------------------------------------------------
# 6. SUSFS  (was: actions/susfs -> susfs-setup + susfs-config + susfs-patches
#             + susfs-revert-patches)
# ---------------------------------------------------------------------------
setup_susfs() {
  echo "::group::Setup SUSFS"
  cd "$WORKSPACE"
  git clone https://gitlab.com/simonpunk/susfs4ksu.git -b "gki-${VERSION}" susfs4ksu
  [ -n "$SUSFS_COMMIT" ] && (cd susfs4ksu && git checkout "$SUSFS_COMMIT")
  cd susfs4ksu
  patch -p1 < "${WORKSPACE}/kernel_patches/pershoot/susfs4ksu/0001-pershoot-Allow-core-to-be-built-with-no-features.patch"
  patch -p1 < "${WORKSPACE}/kernel_patches/pershoot/susfs4ksu/0002-pershoot-Implement-SuSFS-and-Toolkit-coexistence.patch"

  set_kernel_config "CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y"

  cd "${WORKSPACE}/kernel/common"
  cp "${WORKSPACE}/susfs4ksu/kernel_patches/fs/"* fs/
  cp "${WORKSPACE}/susfs4ksu/kernel_patches/include/linux/"* include/linux/
  cp "${WORKSPACE}/susfs4ksu/kernel_patches/50_add_susfs_in_gki-${VERSION}.patch" ./

  # --- android16-6.12 fake patches (pre) ---
  if [ "$SUBLEVEL" -ge 58 ]; then
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/exec.c
  fi
  if [ "$SUBLEVEL" -ge 69 ]; then
    sed -i 's/vma_data_pages/vma_pages/g' fs/proc/task_mmu.c
  fi

  patch -p1 < "50_add_susfs_in_gki-${VERSION}.patch"

  if grep -q 'VMA_PAD_START(' fs/proc/task_mmu.c && \
     ! grep -qE '#include <linux/pgsize_migration(_inline)?\.h>|define VMA_PAD_START' fs/proc/task_mmu.c; then
    sed -i '1a #ifndef VMA_PAD_START\n#define VMA_PAD_START(vma) ((vma)->vm_end)\n#endif' fs/proc/task_mmu.c
  fi
  if grep -q '__fold_filemap_fixup_entry' fs/proc/task_mmu.c && \
     ! grep -q '#include <linux/page_size_compat.h>' fs/proc/task_mmu.c; then
    sed -i '/#include <linux\/pkeys.h>/a #include <linux/page_size_compat.h>' fs/proc/task_mmu.c
  fi

  # --- android16-6.12 fake patches (revert, restore original includes) ---
  if [ "$SUBLEVEL" -ge 58 ]; then
    sed -i '/^#include /a #include <linux/dma-buf.h>' fs/exec.c
  fi
  if [ "$SUBLEVEL" -ge 69 ]; then
    sed -i 's/vma_pages/vma_data_pages/g' fs/proc/task_mmu.c
  fi
  echo "::endgroup::"
}

# ---------------------------------------------------------------------------
# 7. Baseband Guard  (was: actions/bbg)
# ---------------------------------------------------------------------------
setup_bbg() {
  echo "::group::Setup Baseband Guard"
  cd "${WORKSPACE}/kernel"
  wget -O- https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh | bash
  sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' common/security/Kconfig
  grep -q "baseband_guard" common/security/Kconfig || { echo "BBG install failed"; exit 1; }
  set_kernel_config "CONFIG_BBG=y"
  echo "::endgroup::"
}

# ---------------------------------------------------------------------------
# 8. Networking (IP set / TCP-CC / qdisc / CIFS / Wireguard).
#    BBRv3 is intentionally skipped for android16-6.12 — upstream has no
#    working backport patch for this branch yet (same as original workflow).
#    (was: actions/networking -> networking-config + bbrv3 + cifs)
# ---------------------------------------------------------------------------
setup_networking() {
  echo "::group::Setup networking"
  set_kernel_config "CONFIG_IP_SET=y
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
CONFIG_DEFAULT_TCP_CONG=\"bbr\"
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
CONFIG_CIFS_POSIX=y"

  # CIFS fix for android16-6.12
  cd "${WORKSPACE}/kernel/common"
  sed -i '/"fs\/netfs\/netfs\.ko",/d' modules.bzl
  echo "(BBRv3 patch skipped for android16-6.12 — no working upstream backport yet)"
  echo "::endgroup::"
}

# ---------------------------------------------------------------------------
# 9. DroidSpaces-OSS  (was: actions/droidspaces)
# ---------------------------------------------------------------------------
setup_droidspaces() {
  echo "::group::Setup DroidSpaces-OSS"
  cd "$WORKSPACE"
  rm -rf Droidspaces-OSS
  git clone --depth=1 https://github.com/ravindu644/Droidspaces-OSS.git

  cd "${WORKSPACE}/kernel/common"
  cp "${WORKSPACE}/Droidspaces-OSS/Documentation/resources/kernel-patches/GKI/kernel-6.12/001.GKI-6.12-or-above-fix_sysvipc_kabi.patch" ./
  patch -p1 < 001.GKI-6.12-or-above-fix_sysvipc_kabi.patch

  {
    echo
    echo 'EXPORT_SYMBOL_GPL(put_ipc_ns);'
  } >> "${WORKSPACE}/kernel/common/ipc/namespace.c"
  {
    echo
    echo 'EXPORT_SYMBOL_GPL(init_ipc_ns);'
  } >> "${WORKSPACE}/kernel/common/ipc/msgutil.c"

  set_kernel_config "CONFIG_PID_NS=y
CONFIG_SYSVIPC=y
CONFIG_POSIX_MQUEUE=y
CONFIG_IPC_NS=y
CONFIG_DEVTMPFS=y
CONFIG_BINFMT_MISC=y
CONFIG_BINFMT_SCRIPT=y
CONFIG_BINFMT_ELF=y
CONFIG_USER_NS=y"
  echo "::endgroup::"
}

# ---------------------------------------------------------------------------
# 10. NTSync  (was: actions/ntsync — android16-6.12 branch)
# ---------------------------------------------------------------------------
apply_ntsync() {
  echo "::group::Apply NTSync"
  cd "${WORKSPACE}/kernel/common"
  rm -f include/uapi/linux/ntsync.h drivers/misc/ntsync.c
  patch -p1 < "${WORKSPACE}/kernel_patches/common/ntsync/ntsync_compat_${VERSION}.patch"
  patch -p1 < "${WORKSPACE}/kernel_patches/common/ntsync/ntsync_base.patch"
  set_kernel_config "CONFIG_NTSYNC=y"
  echo "::endgroup::"
}

# ---------------------------------------------------------------------------
# 11. Ptrace patch — only for kernel < 5.16, so it's a no-op for 6.12
#     (was: actions/ptrace)
# ---------------------------------------------------------------------------
apply_ptrace() {
  echo "Kernel ${KERNEL_VERSION} >= 5.16, skipping ptrace patch"
}

# ---------------------------------------------------------------------------
# 12. Unicode bypass fix  (was: actions/unicode-fix)
# ---------------------------------------------------------------------------
apply_unicode_fix() {
  echo "::group::Apply unicode bypass fix"
  cd "${WORKSPACE}/kernel/common"
  patch -p1 --forward < "${WORKSPACE}/kernel_patches/common/unicode_bypass_fix_6.1+.patch"
  echo "::endgroup::"
}

# ---------------------------------------------------------------------------
# 13. Misc configs  (was: actions/misc)
# ---------------------------------------------------------------------------
setup_misc_configs() {
  set_kernel_config "CONFIG_OVERLAY_FS=y
CONFIG_TMPFS_XATTR=y
CONFIG_TMPFS_POSIX_ACL=y
CONFIG_KALLSYMS=y
CONFIG_KALLSYMS_ALL=y
CONFIG_BPF_EVENTS=y
CONFIG_KPROBE_EVENTS=y
CONFIG_UPROBES=y
CONFIG_UPROBE_EVENTS=y
CONFIG_FUSE_BPF=y
CONFIG_ADIOS=y"
}

# ---------------------------------------------------------------------------
# 14. Kernel branding (custom version string)  (was: apply-kernel-branding)
# ---------------------------------------------------------------------------
apply_kernel_branding() {
  cd "${WORKSPACE}/kernel/common"
  local kernel_string="${KERNEL_VERSION}.${SUBLEVEL}-${ANDROID_VERSION}"
  sed -i '$d' scripts/setlocalversion
  echo "echo \"${kernel_string}-${KERNEL_NAME_TAG}\"" >> scripts/setlocalversion
  chmod +x scripts/setlocalversion
}

# ---------------------------------------------------------------------------
# 15. Remove ABI protected exports (Bazel-only tree)  (was: remove-protected-exports)
# ---------------------------------------------------------------------------
remove_protected_exports() {
  cd "${WORKSPACE}/kernel"
  [ -f "build/build.sh" ] && return 0   # legacy build system — n/a for 6.12
  rm -rf common/android/abi_gki_protected_exports_*
  perl -pi -e 's/^\s*"protected_exports_list"\s*:\s*"android\/abi_gki_protected_exports_aarch64",\s*$//;' common/BUILD.bazel
  sed -i 's/protected_modules = \[.*\]/protected_modules = []/' common/modules.bzl
  perl -pi -e 's/^\s*protected_module_names_list\s*=\s*":gki_(?:aarch64|x86_64)_protected_module_names",\s*$//;' common/BUILD.bazel
}

# ---------------------------------------------------------------------------
# 16. Clean dirty flags  (was: clean-kernel-flags)
# ---------------------------------------------------------------------------
clean_kernel_flags() {
  cd "${WORKSPACE}/kernel"
  sed -i "/stable_scmversion_cmd/s/-maybe-dirty//g" build/kernel/kleaf/impl/stamp.bzl
  sed -i 's/-dirty//' common/scripts/setlocalversion
  cd common
  git add -A
  git -c user.name="github-actions[bot]" -c user.email="github-actions[bot]@users.noreply.github.com" \
    commit -m "Wild: Clean Dirty Flag" --allow-empty
}

# ---------------------------------------------------------------------------
# 17. Build (Bazel/Kleaf)  (was: actions/build-kernel, bypass=false path)
# ---------------------------------------------------------------------------
build_kernel() {
  echo "::group::Build kernel (Bazel/Kleaf)"
  cd "${WORKSPACE}/kernel"
  sed -i 's/check_defconfig//' ./common/build.config.gki
  sed -i '/name = "kernel_aarch64",/a\    check_defconfig = "disabled",' common/BUILD.bazel

  tools/bazel build \
    --config=fast \
    --config=stamp \
    --disk_cache="${HOME}/.cache/bazel" \
    //common:kernel_aarch64/Image

  if [ ! -f "bazel-bin/common/kernel_aarch64/Image" ]; then
    echo "ERROR: Image not found after build" >&2
    exit 1
  fi
  cp "bazel-bin/common/kernel_aarch64/Image" "${WORKSPACE}/AnyKernel3/Image"
  echo "::endgroup::"
}

# ---------------------------------------------------------------------------
# 18. Package AnyKernel3 zip
# ---------------------------------------------------------------------------
package_anykernel3() {
  echo "::group::Package AnyKernel3"
  mkdir -p "$OUT_DIR"
  ( cd "${WORKSPACE}/AnyKernel3" && zip -r -q -9 "${OUT_DIR}/${FILE_NAME}-AnyKernel3.zip" . )
  echo "Output: ${OUT_DIR}/${FILE_NAME}-AnyKernel3.zip"
  echo "::endgroup::"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  setup_build_environment
  download_kernel
  set_timestamp_and_name
  extract_sublevel_file_name

  feat "KSUN" && setup_kernelsu
  feat "SUSFS" && setup_susfs
  feat "BBG"   && setup_bbg
  feat "NET"   && setup_networking
  feat "DS"    && setup_droidspaces

  apply_ntsync
  apply_ptrace
  apply_unicode_fix
  setup_misc_configs
  apply_kernel_branding
  remove_protected_exports
  clean_kernel_flags

  build_kernel
  package_anykernel3

  echo "==> Done: ${FILE_NAME}"
}

main "$@"
