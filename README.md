<div align="center">

# 🔥 Kinosaki Kernel

[![KernelSU](https://img.shields.io/badge/KernelSU-Supported-green)](https://kernelsu.org/)
[![SUSFS](https://img.shields.io/badge/SUSFS-Integrated-orange)](https://gitlab.com/simonpunk/susfs4ksu)

</div>

## ⚠️ Your warranty is no longer valid!

I am **not responsible** for bricked devices, damaged hardware, or any issues that arise from using this kernel.

**Please** do thorough research and fully understand the features included in this kernel before flashing it!

By flashing this kernel, **YOU** are choosing to make these modifications. If something goes wrong, **do not blame me**!

---

### 🚨 Proceed at your own risk!

---

## 🔧 About this build system

Kinosaki Kernel is built from a single consolidated pipeline:

- **`build.sh`** — one script that does the entire build: downloads the AOSP
  GKI `android16-6.12` source, applies every patch (KernelSU-Next, SUSFS,
  Baseband Guard, Networking/CIFS/Wireguard, DroidSpaces-OSS, NTSync, unicode
  fix, misc/BTF configs, branding, dirty-flag cleanup...), and packages an
  AnyKernel3 zip.
- **`.github/workflows/build.yml`** — one workflow that runs `build.sh` for
  the two supported targets.

## 🎯 Supported targets

Only two kernel targets are built — both are `android16-6.12`, they only
differ in which upstream `kernel/common` branch is used:

| Target | Branch | Output |
|--------|--------|--------|
| **6.12**  | `6.12` | `AK3-6.12.38-Kinosaki-Bore-<tanggal><jam>.zip` |
| **cass**  | `cass` | `AK3-CASS-Kinosaki-Bore-<tanggal><jam>.zip` |

SUSFS is always included — there's no on/off toggle, it's a permanent part
of the build alongside KernelSU-Next.

## 🛠️ Building locally

```bash
chmod +x build.sh
./build.sh --target 6.12   # or: --target cass
```

Optional flags: `--ksu-branch`, `--susfs-commit`, `--kernel-name`.

## 🛠️ Building via GitHub Actions

Run the **Build Kinosaki Kernel** workflow (`workflow_dispatch`) and choose:

- `targets`: `6.12`, `cass`, or both
- `release_type`: `Action` (artifacts only), `Pre-Release`, or `Release`
- optional overrides for the KernelSU-Next branch, SUSFS commit, and
  branding tag

---

## 📋 Installation Instructions

For GKI installation, please follow the official guide:

📖 **[KernelSU Installation Guide](https://kernelsu.org/guide/installation.html)**

---

## ✨ Features

- 🔐 **KernelSU-Next**: A root solution for Android GKI devices that works in kernel mode and grants root permission to userspace applications directly in kernel space
- 🛡️ **SUSFS**: An addon root hiding kernel patches and userspace module for KernelSU (always enabled)
- 🛡️ **Baseband Guard (BBG)**: Baseband/modem partition protection
- 🌐 **Networking**: IP Set, advanced TCP congestion control (incl. BBR), FQ/CAKE qdiscs, CIFS, Wireguard
- 🗂️ **DroidSpaces-OSS**: namespace/SysV IPC support patches
- 🖱️ **NTSync**: NT synchronization primitives for Wine/Proton-style workloads

---

## 🏆 Credits

- 🔐 **KernelSU**: Developed by [tiann](https://github.com/tiann/KernelSU)
- 🚀 **KernelSU-Next**: Developed by [rifsxd](https://github.com/KernelSU-Next/KernelSU-Next)
- ✨ **Magic-KSU**: Developed by [5ec1cff](https://github.com/5ec1cff/KernelSU)
- 🛡️ **SUSFS**: Developed by [simonpunk](https://gitlab.com/simonpunk/susfs4ksu.git)
- 🛡️ **Baseband-guard (BBG)**: Developed by [vc-teahouse](https://github.com/vc-teahouse/Baseband-guard)
- 📦 **SUSFS Module**: Developed by [sidex15](https://github.com/sidex15)
- 🗂️ **Droidspaces-OSS**: Developed by [ravindu644](https://github.com/ravindu644/Droidspaces-OSS)
- 🩹 **Kernel patches**: [WildKernels/kernel_patches](https://github.com/WildKernels/kernel_patches)
- 📦 **AnyKernel3**: [Cartethyiaaa/AnyKernel3](https://github.com/Cartethyiaaa/AnyKernel3)

🙏 Special thanks to the open-source community for their contributions!

---

## 💬 Support

If you encounter any issues or need help, feel free to open an issue in this repository.

---

## ⚠️ Disclaimer

Flashing this kernel will void your warranty, and there is always a risk of bricking your device. Please make sure to:
- 💾 Back up your data
- 🧠 Understand the risks before proceeding

**🚨 Proceed at your own risk!**
