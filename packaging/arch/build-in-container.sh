#!/usr/bin/env bash
# Runs as PID 1 in an Arch base-devel container.

set -euo pipefail

readonly HOST_UID="${HOST_UID:?HOST_UID was not provided}"
readonly HOST_GID="${HOST_GID:?HOST_GID was not provided}"
readonly BUILD_ROOT=/build/mesa-ps4-package
readonly ARCHIVE_ROOT="${BUILD_ROOT}/archive"
readonly PACKAGE_ROOT="${BUILD_ROOT}/package"
readonly ARTIFACT_ROOT="${PACKAGE_ROOT}/artifacts"

enable_multilib()
{
   local pacman_conf="${PACMAN_CONF:-/etc/pacman.conf}"

   has_multilib_source()
   {
      awk '
         /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
            in_multilib = ($0 ~ /^[[:space:]]*\[multilib\][[:space:]]*$/)
         }
         in_multilib && /^[[:space:]]*(Include|Server)[[:space:]]*=/ {
            found = 1
         }
         END { exit(found ? 0 : 1) }
      ' "${pacman_conf}"
   }

   if ! grep -Eq '^[[:space:]]*\[multilib\][[:space:]]*$' "${pacman_conf}"; then
      # Some Arch container images omit the disabled repository template
      # entirely, so do not depend on uncommenting a particular file layout.
      printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >>"${pacman_conf}"
   elif ! has_multilib_source; then
      sed -i \
         '/^[[:space:]]*\[multilib\][[:space:]]*$/a Include = /etc/pacman.d/mirrorlist' \
         "${pacman_conf}"
   fi

   if ! grep -Eq '^[[:space:]]*\[multilib\][[:space:]]*$' "${pacman_conf}" ||
      ! has_multilib_source; then
      printf 'Unable to enable the Arch multilib repository; relevant pacman.conf lines:\n' >&2
      grep -nE 'multilib|Include|Server' "${pacman_conf}" >&2 || true
      exit 1
   fi
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

   # The minimal container does not necessarily have a local master key yet.
   # archlinux-keyring's upgrade hook needs it to rebuild/sign the trust DB.
   pacman-key --init
   pacman-key --populate archlinux
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
      "${PACKAGE_ROOT}" "${ARTIFACT_ROOT}"
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
   local artifact
   local out_gid
   local out_uid
   local -a artifacts

   runuser -u builder -- /bin/bash -euo pipefail -c '
      cd "$1"
      export PKGDEST="$2"
      export SRCDEST="$1/sources"
      export BUILDDIR="$1/work"
      makepkg --clean --cleanbuild --force --noconfirm
   ' _ "${PACKAGE_ROOT}" "${ARTIFACT_ROOT}"

   # Rootless Podman maps the host owner of /out to container UID 0. Building
   # directly into that mount as the makepkg user therefore fails. Stage in
   # the container, then copy as container root while preserving the mount's
   # effective owner for both rootless Podman and Docker.
   mapfile -d '' artifacts < <(
      find "${ARTIFACT_ROOT}" -maxdepth 1 -type f -name '*.pkg.tar.zst' -print0
   )
   (( ${#artifacts[@]} > 0 )) || {
      printf 'makepkg completed without producing a .pkg.tar.zst artifact\n' >&2
      exit 1
   }

   out_uid="$(stat -c %u /out)"
   out_gid="$(stat -c %g /out)"
   for artifact in "${artifacts[@]}"; do
      install -o "${out_uid}" -g "${out_gid}" -m 0644 "${artifact}" /out/
      printf 'Exported %s\n' "/out/$(basename "${artifact}")"
   done
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
