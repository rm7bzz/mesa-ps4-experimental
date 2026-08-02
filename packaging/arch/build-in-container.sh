#!/usr/bin/env bash
# Runs as PID 1 in an Arch base-devel container.

set -euo pipefail

readonly HOST_UID="${HOST_UID:?HOST_UID was not provided}"
readonly HOST_GID="${HOST_GID:?HOST_GID was not provided}"
readonly BUILD_ROOT=/build/mesa-ps4-package
readonly ARCHIVE_ROOT="${BUILD_ROOT}/archive"
readonly PACKAGE_ROOT="${BUILD_ROOT}/package"

enable_multilib()
{
   sed -i \
      '/^#\[multilib\]$/,/^#Include = \/etc\/pacman.d\/mirrorlist$/s/^#//' \
      /etc/pacman.conf
   grep -qx '\[multilib\]' /etc/pacman.conf || {
      printf 'Unable to enable the Arch multilib repository\n' >&2
      exit 1
   }
}

install_dependencies()
{
   local -a packages=(
      base-devel git
      clang cmake elfutils glslang meson ninja pkgconf
      python-mako python-packaging python-ply python-pycparser python-yaml
      wayland-protocols xorgproto
      expat libdisplay-info libdrm libglvnd libx11 libxcb libxext
      libxrandr libxshmfence libxxf86vm llvm llvm-libs lm_sensors
      spirv-tools systemd-libs vulkan-icd-loader wayland xcb-util-keysyms
      zlib zstd
      lib32-clang lib32-expat lib32-gcc-libs lib32-glibc
      lib32-libdisplay-info lib32-libdrm lib32-libelf lib32-libglvnd
      lib32-libx11 lib32-libxcb lib32-libxext lib32-libxrandr
      lib32-libxshmfence lib32-libxxf86vm lib32-llvm lib32-llvm-libs
      lib32-lm_sensors lib32-spirv-tools lib32-systemd
      lib32-vulkan-icd-loader lib32-wayland lib32-xcb-util-keysyms
      lib32-zlib lib32-zstd
   )

   pacman -Syu --needed --noconfirm "${packages[@]}"
}

create_builder()
{
   local build_uid="${HOST_UID}"
   local build_gid="${HOST_GID}"
   local group_name

   # makepkg refuses to run as root. Keep root ownership on the host when the
   # container itself was launched by root, but use an unprivileged build ID.
   if [[ "${build_uid}" == 0 ]]; then
      build_uid=1000
   fi
   if [[ "${build_gid}" == 0 ]]; then
      build_gid=1000
   fi

   group_name="$(getent group "${build_gid}" | cut -d: -f1 || true)"
   if [[ -z "${group_name}" ]]; then
      group_name=builder
      groupadd -o -g "${build_gid}" "${group_name}"
   fi

   if getent passwd builder >/dev/null; then
      userdel -r builder
   fi
   useradd -o -m -u "${build_uid}" -g "${group_name}" builder
   install -d -o builder -g "${group_name}" "${BUILD_ROOT}" "${ARCHIVE_ROOT}" \
      "${PACKAGE_ROOT}"
}

prepare_source_archive()
{
   local revision_count
   local revision_hash

   revision_count="$(git -c safe.directory=/source -C /source rev-list --count HEAD)"
   revision_hash="$(git -c safe.directory=/source -C /source rev-parse --short=12 HEAD)"

   runuser -u builder -- /bin/bash -euo pipefail -c '
      mkdir -p "$1/mesa"
      git -c safe.directory=/source -C /source archive HEAD |
         tar -x -C "$1/mesa"
   ' _ "${ARCHIVE_ROOT}"

   printf '%s\n' "${revision_count}" >"${ARCHIVE_ROOT}/mesa/.ps4-revision-count"
   printf '%s\n' "${revision_hash}" >"${ARCHIVE_ROOT}/mesa/.ps4-revision-hash"
   chown builder: "${ARCHIVE_ROOT}/mesa/.ps4-revision-count" \
      "${ARCHIVE_ROOT}/mesa/.ps4-revision-hash"

   runuser -u builder -- tar -cf "${PACKAGE_ROOT}/mesa-ps4-experimental.tar" \
      -C "${ARCHIVE_ROOT}" mesa
   install -o builder -g "$(id -gn builder)" -m 0644 \
      /source/packaging/arch/PKGBUILD "${PACKAGE_ROOT}/PKGBUILD"
}

build_packages()
{
   runuser -u builder -- /bin/bash -euo pipefail -c '
      cd "$1"
      export PKGDEST=/out
      export SRCDEST="$1/sources"
      export BUILDDIR="$1/work"
      makepkg --clean --cleanbuild --force --noconfirm
   ' _ "${PACKAGE_ROOT}"
   chown -R "${HOST_UID}:${HOST_GID}" /out
}

main()
{
   [[ -d /source/.git ]] || {
      printf '/source is not a Git worktree\n' >&2
      exit 1
   }
   [[ -d /out ]] || {
      printf '/out is not mounted\n' >&2
      exit 1
   }

   enable_multilib
   install_dependencies
   create_builder
   prepare_source_archive
   build_packages
}

main "$@"
