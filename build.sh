#!/usr/bin/env bash
#
# Kinosaki Kernel build script
# Builds a GKI 6.12 kernel (android16) with KernelSU-Next, Baseband Guard,
# DroidSpaces, NTSync and assorted config patches, then packages AnyKernel3.
#
# Usage: ./build.sh --target <6.12|cass> [options]

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

readonly CUSTOM_REPO="https://github.com/Cartethyiaaa/android_kernel_common-5.10"
readonly ANDROID_VERSION="android16"
readonly KERNEL_VERSION="6.12"
readonly MANIFEST_SUBLEVEL="38"
readonly OS_PATCH_LEVEL="2025-09"
readonly VERSION="${ANDROID_VERSION}-${KERNEL_VERSION}"

readonly WORKSPACE="$(pwd)"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PATCH_DIR="${SCRIPT_DIR}/patches"
readonly KERNEL_DIR="${WORKSPACE}/kernel"
readonly OUT_DIR="/home/runner/out"
readonly AK3_DIR="${WORKSPACE}/AnyKernel3"

readonly BOT_NAME="kinosaki-bot"
readonly BOT_EMAIL="kinosaki-bot@users.noreply.github.com"

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------

TARGET=""
KSU_BRANCH=""
KERNEL_NAME_OVERRIDE=""

usage() {
  cat <<EOF
Usage: $0 --target <6.12|cass> [options]

Options:
  --target <6.12|cass>     Which kernel source branch to build (required)
  --ksu-branch <ref>       KernelSU-Next branch/commit (default: next tip)
  --kernel-name <tag>      Override branding tag (default: Kinosaki-BORE or Kinosaki-CASS)
  -h, --help                Show this help
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)       TARGET="$2"; shift 2 ;;
      --ksu-branch)   KSU_BRANCH="$2"; shift 2 ;;
      --kernel-name)  KERNEL_NAME_OVERRIDE="$2"; shift 2 ;;
      -h|--help)      usage; exit 0 ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  if [[ "$TARGET" != "6.12" && "$TARGET" != "cass" ]]; then
    echo "ERROR: --target must be '6.12' or 'cass' (got: '${TARGET:-<empty>}')" >&2
    usage
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m[warn] $*\033[0m"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  local line_no=$1
  echo -e "\033[1;31m[fail] build.sh exited ${exit_code} at line ${line_no}\033[0m" >&2
}
trap 'on_error $LINENO' ERR

# ---------------------------------------------------------------------------
# Derived / runtime globals (populated as the build progresses)
# ---------------------------------------------------------------------------

CUSTOM_BRANCH=""
BUILD_EPOCH=""
KERNEL_NAME_TAG=""
SUBLEVEL=""
FILE_NAME=""
KSU_VERSION=""
KSU_GIT_TAG=""

resolve_custom_branch() {
  if [[ "$TARGET" == "6.12" ]]; then
    CUSTOM_BRANCH="6.12"
  else
    CUSTOM_BRANCH="cass"
  fi
}

# ---------------------------------------------------------------------------
# kconfig helper — merges "KEY=value" / "KEY" lines into gki_defconfig
# ---------------------------------------------------------------------------

apply_kconfig() {
  local defconfig="${KERNEL_DIR}/common/arch/arm64/configs/gki_defconfig"
  [[ -f "$defconfig" ]] || die "gki_defconfig not found at ${defconfig}"

  local line key value
  while IFS= read -r line; do
    line="$(echo "$line" | xargs)"
    [[ -z "$line" || "$line" == \#* ]] && continue

    if [[ "$line" == *"="* ]]; then
      key="${line%%=*}"
      value="${line#*=}"
    else
      key="$line"
      value="y"
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

# ---------------------------------------------------------------------------
# Stage: environment setup
# ---------------------------------------------------------------------------

setup_build_environment() {
  log "Setting up build environment"

  git config --global user.name "$BOT_NAME"
  git config --global user.email "$BOT_EMAIL"

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

# ---------------------------------------------------------------------------
# Stage: kernel source
# ---------------------------------------------------------------------------

_repo_init() {
  local formatted_branch="$1"
  repo init -u https://android.googlesource.com/kernel/manifest \
    -b "common-${formatted_branch}" --depth=1

  local remote_branch
  remote_branch=$(git ls-remote https://android.googlesource.com/kernel/common "${formatted_branch}")
  if grep -q deprecated <<<"$remote_branch"; then
    sed -i "s/\"${formatted_branch}\"/\"deprecated\/${formatted_branch}\"/g" .repo/manifests/default.xml
    warn "Branch ${formatted_branch} is deprecated upstream."
  fi
}

_repo_sync_with_retries() {
  local max_retries=3 attempt=1
  while (( attempt <= max_retries )); do
    echo "repo sync attempt ${attempt}/${max_retries}..."
    if timeout 15m repo sync -c --current-branch --no-clone-bundle --no-tags --jobs-checkout=4 -j4; then
      return 0
    fi
    if (( attempt < max_retries )); then
      rm -rf .repo
      sleep 15
      _repo_init "$1"
    else
      die "repo sync failed after ${max_retries} attempts"
    fi
    attempt=$((attempt + 1))
  done
}

_clone_custom_common() {
  log "Overriding kernel/common with ${CUSTOM_REPO} (branch: ${CUSTOM_BRANCH})"
  rm -rf common

  local attempt=1
  while (( attempt <= 3 )); do
    if git clone --branch "$CUSTOM_BRANCH" --depth=1 "$CUSTOM_REPO" common; then
      echo "kernel/common HEAD: $(git -C common rev-parse HEAD)"
      return 0
    fi
    rm -rf common
    if (( attempt == 3 )); then
      die "failed to clone ${CUSTOM_REPO} (${CUSTOM_BRANCH})"
    fi
    attempt=$((attempt + 1))
    sleep 10
  done
}

download_kernel() {
  log "Downloading AOSP GKI manifest ($VERSION, os_patch_level=$OS_PATCH_LEVEL)"

  local formatted_branch="${ANDROID_VERSION}-${KERNEL_VERSION}-${OS_PATCH_LEVEL}"
  cd "$KERNEL_DIR"

  _repo_init "$formatted_branch"
  _repo_sync_with_retries "$formatted_branch"
  _clone_custom_common
}

# ---------------------------------------------------------------------------
# Stage: build metadata (timestamp, branding tag, output file name)
# ---------------------------------------------------------------------------

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
  elif [[ "$TARGET" == "6.12" ]]; then
    KERNEL_NAME_TAG="Kinosaki-BORE"
  else
    KERNEL_NAME_TAG="Kinosaki-CASS"
  fi

  echo "Kernel branding tag: $KERNEL_NAME_TAG"
}

extract_sublevel_and_name() {
  log "Extracting sublevel / composing file name"

  SUBLEVEL="$MANIFEST_SUBLEVEL"
  if [[ -f "${KERNEL_DIR}/common/Makefile" ]]; then
    local extracted
    extracted=$(grep '^SUBLEVEL = ' "${KERNEL_DIR}/common/Makefile" | awk '{print $3}')
    [[ -n "$extracted" ]] && SUBLEVEL="$extracted"
  fi

  local stamp label
  stamp=$(date -u -d "@${BUILD_EPOCH}" '+%Y%m%d-%H%M')
  label="${KERNEL_VERSION}.${SUBLEVEL}"

  FILE_NAME="AK3-${label}-${KERNEL_NAME_TAG}-${stamp}"
  echo "File name: $FILE_NAME"
}

# ---------------------------------------------------------------------------
# Stage: toolchain / Makefile fixes
# ---------------------------------------------------------------------------

apply_kernel_fixes() {
  log "Applying kernel fixes"
  cd "${KERNEL_DIR}/common"

  local glibc_version
  glibc_version="$(ldd --version 2>/dev/null | head -n1 | awk '{print $NF}')"

  if [[ "$(printf '%s\n' "2.38" "$glibc_version" | sort -V | head -n1)" != "2.38" ]]; then
    echo "GLIBC ${glibc_version} < 2.38, skipping resolve_btfids Makefile fix"
    return
  fi

  echo "GLIBC ${glibc_version} >= 2.38, checking resolve_btfids Makefile..."
  local target="tools/bpf/resolve_btfids/Makefile"

  if grep -q '$(Q)$(MAKE) -C $(SUBCMD_SRC) OUTPUT=$(abspath $(dir $@))/ $(abspath $@)' "$target"; then
    sed -i '/\$(Q)\$(MAKE) -C \$(SUBCMD_SRC) OUTPUT=\$(abspath \$(dir \$@))\/ \$(abspath \$@)/s//$(Q)$(MAKE) -C $(SUBCMD_SRC) EXTRA_CFLAGS="$(CFLAGS)" OUTPUT=$(abspath $(dir $@))\/ $(abspath $@)/' "$target"
    echo "  -> Makefile EXTRA_CFLAGS fix applied"
  else
    echo "  -> pattern not found / already fixed, skipping"
  fi
}

# ---------------------------------------------------------------------------
# Stage: KernelSU-Next
# ---------------------------------------------------------------------------

_ksu_checkout_branch() {
  local ksu_repo="https://github.com/KernelSU-Next/KernelSU-Next.git"
  local ksu_input="${KSU_BRANCH:-next}"

  [[ -z "$KSU_BRANCH" || "$KSU_BRANCH" == "next" ]] && return

  git -C KernelSU-Next/kernel fetch --depth=50 origin "$ksu_input"
  if git ls-remote --heads "$ksu_repo" "$ksu_input" | grep -q .; then
    git -C KernelSU-Next/kernel checkout "origin/${ksu_input}"
  else
    git -C KernelSU-Next/kernel checkout "$ksu_input"
  fi
}

_ksu_stamp_version() {
  local commits_count base_version=30000
  commits_count=$(git rev-list --count HEAD)
  KSU_VERSION=$((commits_count + base_version))
  sed -i "s/^KSU_VERSION_FALLBACK := 1$/KSU_VERSION_FALLBACK := ${KSU_VERSION}/" Kbuild

  KSU_GIT_TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo v0.0.1)"
  sed -i "s/^KSU_VERSION_TAG_FALLBACK := v0.0.1$/KSU_VERSION_TAG_FALLBACK := ${KSU_GIT_TAG}/" Kbuild
}

# Fixes the linkage mismatch in selinux_hide.c: forward declarations are
# non-static (extern) while the actual definitions further down the file
# are static, which GCC/Clang rejects ("static declaration follows
# non-static declaration"). Applied via a patch file (not sed) so that if
# upstream KernelSU-Next reformats the file, this fails loudly instead of
# silently no-op'ing.
#
# IMPORTANT: KernelSU-Next's setup.sh places (copies, not always symlinks)
# the driver source under kernel/common/drivers/kernelsu/feature/ — that is
# the file the compiler actually reads. The raw checkout at
# KernelSU-Next/kernel/feature/ may be a separate copy that setup.sh no
# longer touches once it's been placed into common/. Patch the compiled
# location first; fall back to the raw checkout only if that path doesn't
# exist (e.g. a different setup.sh version that does symlink instead).
_ksu_fix_selinux_hide_linkage() {
  local patch_file="${PATCH_DIR}/kernelsu-static.patch"
  [[ -f "$patch_file" ]] || die "${patch_file} not found"

  local hide_file="${KERNEL_DIR}/common/drivers/kernelsu/feature/selinux_hide.c"
  if [[ ! -f "$hide_file" ]]; then
    hide_file="${KERNEL_DIR}/KernelSU-Next/kernel/feature/selinux_hide.c"
  fi
  [[ -f "$hide_file" ]] || die "selinux_hide.c not found in any known location"

  log "Applying kernelsu-static.patch to ${hide_file#"${KERNEL_DIR}"/}"
  # Pass the target file explicitly (-p0 + filename) instead of relying on
  # the a/ b/ paths inside the diff, so this works no matter which of the
  # two locations above actually held the file.
  patch -p0 "$hide_file" < "$patch_file"
}

setup_kernelsu() {
  log "Setting up KernelSU-Next (official next)"
  cd "$KERNEL_DIR"

  curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s next

  _ksu_checkout_branch

  (cd KernelSU-Next/kernel && _ksu_stamp_version)
  _ksu_fix_selinux_hide_linkage

  apply_kconfig "CONFIG_KSU=y"
  echo "KSU version: $KSU_VERSION (tag: $KSU_GIT_TAG)"
}

# ---------------------------------------------------------------------------
# Stage: Baseband Guard
# ---------------------------------------------------------------------------

setup_bbg() {
  log "Setting up Baseband Guard"
  cd "$KERNEL_DIR"

  wget -O- https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh | bash

  sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' \
    common/security/Kconfig

  grep -q "baseband_guard" common/security/Kconfig \
    || die "baseband_guard not found in common/security/Kconfig"

  apply_kconfig "CONFIG_BBG=y"
}

# ---------------------------------------------------------------------------
# Stage: networking configs
# ---------------------------------------------------------------------------

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

  cd "${KERNEL_DIR}/common"
  sed -i '/"fs\/netfs\/netfs\.ko",/d' modules.bzl
}

# ---------------------------------------------------------------------------
# Stage: DroidSpaces-OSS
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Stage: NTSync
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Stage: misc patches (ptrace, unicode, extra kconfig)
# ---------------------------------------------------------------------------

_kernel_version_le() {
  # Returns success if $KERNEL_VERSION <= $1 (per `sort -V`).
  # NOTE: named _le (less-or-equal), not _at_least — the gki_ptrace patch
  # and the unicode-fix variant selection both key off "is this kernel
  # <= 5.16", not ">= 5.16". Getting this backwards means gki_ptrace.patch
  # (which touches tracehook.h, removed from the kernel well before 6.12)
  # gets applied to kernels it was never meant for.
  [[ "$(printf '%s\n' "$KERNEL_VERSION" "$1" | sort -V | head -n1)" == "$KERNEL_VERSION" ]]
}

apply_ptrace_patch() {
  log "Checking ptrace patch (kernel ${KERNEL_VERSION})"
  if _kernel_version_le "5.16"; then
    cd "${KERNEL_DIR}/common"
    patch -p1 -F3 < "${WORKSPACE}/kernel_patches/gki_ptrace.patch"
  else
    echo "Kernel >= 5.16, skipping ptrace patch"
  fi
}

apply_unicode_fix() {
  log "Applying unicode fix patch"
  cd "${KERNEL_DIR}/common"
  if _kernel_version_le "5.16"; then
    patch -p1 --forward < "${WORKSPACE}/kernel_patches/common/unicode_bypass_fix_6.1-.patch"
  else
    patch -p1 --forward < "${WORKSPACE}/kernel_patches/common/unicode_bypass_fix_6.1+.patch"
  fi
}

setup_misc_and_btf() {
  log "Setting up misc kernel configs"
  # CONFIG_ADIOS=y dihapus karena tidak ada driver/patch di repo upstream
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
CONFIG_DEBUG_INFO_BTF=y
EOF
)"
}

# ---------------------------------------------------------------------------
# Stage: branding, protected exports, dirty flag
# ---------------------------------------------------------------------------

apply_kernel_branding() {
  log "Applying kernel branding: $KERNEL_NAME_TAG"
  cd "${KERNEL_DIR}/common"

  local kernel_string="${KERNEL_VERSION}.${SUBLEVEL}-${ANDROID_VERSION}"
  sed -i '$d' scripts/setlocalversion
  echo "echo \"${kernel_string}-${KERNEL_NAME_TAG}\"" >> scripts/setlocalversion
  chmod +x scripts/setlocalversion
}

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
  git -c user.name="$BOT_NAME" -c user.email="$BOT_EMAIL" \
    commit -m "Kinosaki: clean dirty flag" --quiet || true
}

# ---------------------------------------------------------------------------
# Stage: build
# ---------------------------------------------------------------------------

_apply_bypass_patch() {
  local target_file="common/kernel/module/version.c"
  sed -i '/bad_version:/{:a;n;/return 0;/{s/return 0;/return 1;/;b};ba}' "$target_file"
  grep -A5 "bad_version:" "$target_file" | grep -q "return 1;" \
    || die "bypass patch failed on $target_file"
}

_disable_defconfig_check() {
  [[ -f "./common/build.config.gki" ]] && sed -i 's/check_defconfig//' ./common/build.config.gki

  # Nonaktifkan check_defconfig Bazel secara permanen agar tidak fail saat
  # ada config tambahan.
  if grep -q 'name = "kernel_aarch64"' common/BUILD.bazel; then
    sed -i '/check_defconfig =/d' common/BUILD.bazel
    sed -i '/name = "kernel_aarch64",/a\    check_defconfig = "disabled",' common/BUILD.bazel
  fi
}

_run_legacy_build() {
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
}

_run_bazel_build() {
  tools/bazel build \
    --config=fast \
    --config=stamp \
    --kconfig_check=none \
    --disk_cache="${HOME}/.cache/bazel" \
    //common:kernel_aarch64/Image \
  || tools/bazel build \
    --config=fast \
    --config=stamp \
    --disk_cache="${HOME}/.cache/bazel" \
    //common:kernel_aarch64/Image
}

_locate_built_image() {
  if [[ -f "bazel-bin/common/kernel_aarch64/Image" ]]; then
    echo "bazel-bin/common/kernel_aarch64/Image"
  elif [[ -f "${OUT_DIR}/dist/Image" ]]; then
    echo "${OUT_DIR}/dist/Image"
  else
    die "could not find built Image"
  fi
}

build_variant() {
  local bypass="$1"
  log "Building kernel (bypass=${bypass})"
  cd "$KERNEL_DIR"

  [[ "$bypass" == "true" ]] && _apply_bypass_patch
  _disable_defconfig_check

  if [[ -f "build/build.sh" ]]; then
    _run_legacy_build
  else
    _run_bazel_build
  fi

  local image_out
  image_out="$(_locate_built_image)"

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

# ---------------------------------------------------------------------------
# Stage: post-build (patch rejects, packaging)
# ---------------------------------------------------------------------------

scan_patch_rejects() {
  log "Scanning for .rej files"
  local rejects_dir="${WORKSPACE}/patch-rejects"
  mkdir -p "$rejects_dir"

  local rej_count=0 rej rel
  while IFS= read -r rej; do
    rel="${rej#"$KERNEL_DIR"/}"
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

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  parse_args "$@"
  resolve_custom_branch

  echo "============================================================"
  echo " Kinosaki Kernel build — target: ${TARGET} (${VERSION}, branch ${CUSTOM_BRANCH})"
  echo "============================================================"

  setup_build_environment
  download_kernel
  set_build_timestamp
  extract_sublevel_and_name
  apply_kernel_fixes
  setup_kernelsu
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
  echo " Done. KSU=${KSU_VERSION:-N/A} (${KSU_GIT_TAG:-N/A})"
  echo " Output: ${WORKSPACE}/out/${FILE_NAME}.zip"
  echo "============================================================"
}

main "$@"
