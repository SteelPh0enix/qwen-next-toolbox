# Qwen3.8-Next-Flash toolbox for Strix Halo (gfx1151).
#
# Builds and runs the stack from https://github.com/pwilkin/strix-halo
# (custom ROCr + HIP with retained PM4 command lists, llama.cpp `strix-halo` branch).
#
# Base image layout taken from https://github.com/kyuz0/amd-strix-halo-toolboxes.
#
# The installer needs a complete, current ROCm SDK to build against and to link
# rocBLAS/hipBLAS at runtime. Most distributions package a ROCm several majors behind the
# ROCm 10 base this fork tracks, so the SDK comes from AMD's own repository instead.
# The host only has to provide the kernel driver (amdgpu/KFD) and the firmware.

FROM registry.fedoraproject.org/fedora:44

# ROCm 10.0 Core SDK (TheRock release stream), gfx1151 package set.
RUN <<'EOF'
tee /etc/yum.repos.d/rocm.repo <<REPO
[amdrocm-stable]
name=ROCm 10.0.0
baseurl=https://stable.repo.amd.com/rocm/core/packages/rhel10/x86_64
enabled=1
priority=50
gpgcheck=1
gpgkey=https://stable.repo.amd.com/rocm/gpg/packages.gpg
REPO
EOF

# amdrocm10.0-gfx1151: runtime libraries incl. gfx1151 rocBLAS kernels.
# amdrocm-core-devel10.0-gfx1151: hipcc, LLVM, and the cmake packages the installer looks for
# (hip, hipblas, rocblas, amd_comgr, rocprofiler-register, hsa-runtime64).
# The rest is the installer's own Fedora dependency list, preinstalled so that
# it can run unprivileged with --skip-packages.
RUN <<'EOF'
set -eux
dnf -y --nodocs --setopt=install_weak_deps=False install \
  amdrocm10.0-gfx1151 \
  amdrocm-core-devel10.0-gfx1151 \
  ca-certificates curl git-core patch procps-ng which xxd \
  cmake make ninja-build gcc gcc-c++ libstdc++-devel \
  elfutils-libelf-devel libdrm-devel libglvnd-devel libcurl-devel \
  libpciaccess-devel libzstd-devel numactl-devel openssl-devel \
  pciutils pkgconf-pkg-config python3 python3-devel python3-pip \
  libatomic libgcc libgomp
dnf clean all
rm -rf /var/cache/dnf/*
EOF

# The Core SDK installs into /opt/rocm/core-<version>; expose the usual /opt/rocm layout.
RUN <<'EOF'
set -eux
v=$(basename "$(realpath /opt/rocm/core-*)")
ln -sfn "$v" /opt/rocm/core
for d in bin include lib libexec share; do
  ln -sfn "$v/$d" "/opt/rocm/$d"
done
ln -sfn "$v/lib/llvm" /opt/rocm/llvm
ln -sfn "$v/lib/llvm/amdgcn" /opt/rocm/amdgcn
EOF

ENV ROCM_PATH=/opt/rocm \
    HIP_PATH=/opt/rocm \
    ROCM_ROOT=/opt/rocm/core \
    PATH=/opt/rocm/bin:/opt/rocm/core/bin:/opt/rocm/core/lib/llvm/bin:/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/sbin \
    LD_LIBRARY_PATH=/opt/rocm/core/lib/rocm_sysdeps/lib:/opt/rocm/core/lib

# Home for the build tree, the venv and the generated launchers; mount a host directory here.
ENV HOME=/home/strix
RUN mkdir -m 0777 -p /home/strix /models

# Installer front ends from https://github.com/pwilkin/strix-halo, fetched at build time.
# `main` tracks upstream; pin a commit and rebuild to freeze them:
#   docker build --build-arg STRIX_HALO_REF=fa16925 .
ARG STRIX_HALO_REF=main
RUN <<EOF
set -eux
mkdir -p /opt/strix-halo
for s in install.sh install-flash-next.sh; do
  curl -fsSL --retry 3 -o "/opt/strix-halo/$s" \
    "https://raw.githubusercontent.com/pwilkin/strix-halo/${STRIX_HALO_REF}/$s"
done
EOF

WORKDIR /home/strix
CMD ["/bin/bash"]
