#!/usr/bin/env bash
#
# Build this Mesa PS4 tree for native 64-bit Linux, 32-bit Linux, or both.
# The 32-bit build needs a multilib compiler, LLVM, libdrm, and window-system
# development packages for the target architecture.
#
# The package action is different: it builds in an Arch Linux container so
# that the resulting packages do not accidentally link against host Ubuntu
# libraries.

set -euo pipefail

readonly SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly BUILD_ROOT="${MESA_BUILD_ROOT:-${SOURCE_DIR}/build-ps4}"
readonly INSTALL_ROOT="${MESA_INSTALL_ROOT:-${BUILD_ROOT}/install}"
readonly BUILD_TYPE="${MESA_BUILD_TYPE:-release}"
readonly PLATFORMS="${MESA_PLATFORMS:-x11,wayland}"

usage()
{
   cat <<'EOF'
Usage: ./build-ps4.sh [64|32|all] [build|install|clean]
       ./build-ps4.sh package
       ./build-ps4.sh all package

Defaults:  all build

Useful environment overrides:
  MESA_BUILD_ROOT       Build-directory root
  MESA_INSTALL_ROOT     DESTDIR staging root
  MESA_BUILD_TYPE       Meson build type (default: release)
  MESA_PLATFORMS        Meson platforms (default: x11,wayland)
  MESA_MESON_ARGS       Additional Meson setup arguments
  MESA_JOBS             Parallel compile job count
  CC32/CXX32/AR32       32-bit compiler tools
  LLVM_CONFIG32         llvm-config for 32-bit LLVM
  PKG_CONFIG32          32-bit pkg-config executable
  PKG_CONFIG_LIBDIR_32  32-bit pkg-config search path
  PKG_CONFIG_PATH_32    Additional 32-bit pkg-config search path
  MESA_CONTAINER_ENGINE docker or podman executable
  MESA_ARCH_IMAGE       Arch container image
  MESA_PACKAGE_OUTPUT   Output directory for Arch packages
EOF
}

die()
{
   printf 'build-ps4.sh: %s\n' "$*" >&2
   exit 1
}

require_command()
{
   command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

default_pkg_config_libdir_32()
{
   if [[ -d /usr/lib/i386-linux-gnu/pkgconfig ]]; then
      printf '%s' '/usr/lib/i386-linux-gnu/pkgconfig:/usr/share/pkgconfig'
   elif [[ -d /usr/lib32/pkgconfig ]]; then
      printf '%s' '/usr/lib32/pkgconfig:/usr/share/pkgconfig'
   else
      printf '%s' '/usr/share/pkgconfig'
   fi
}

write_cross_file_32()
{
   local cross_file="$1"
   local cc32="${CC32:-gcc}"
   local cxx32="${CXX32:-g++}"
   local ar32="${AR32:-gcc-ar}"
   local strip32="${STRIP32:-strip}"
   local llvm_config32="${LLVM_CONFIG32:-llvm-config}"
   local pkg_config32="${PKG_CONFIG32:-pkg-config}"

   mkdir -p -- "$(dirname -- "${cross_file}")"
   cat >"${cross_file}" <<EOF
[binaries]
c = '${cc32}'
cpp = '${cxx32}'
ar = '${ar32}'
strip = '${strip32}'
llvm-config = '${llvm_config32}'
pkg-config = '${pkg_config32}'

[host_machine]
system = 'linux'
cpu_family = 'x86'
cpu = 'i686'
endian = 'little'

[properties]
needs_exe_wrapper = false

[built-in options]
c_args = ['-m32']
c_link_args = ['-m32']
cpp_args = ['-m32']
cpp_link_args = ['-m32']
EOF
}

meson_setup()
{
   local arch="$1"
   local build_dir="${BUILD_ROOT}/${arch}"
   local -a setup_args=(
      "-Dbuildtype=${BUILD_TYPE}"
      -Db_lto=false
      -Dgallium-drivers=radeonsi
      -Dvulkan-drivers=amd
      "-Dplatforms=${PLATFORMS}"
      -Dglx=dri
      -Degl=enabled
      -Dgbm=enabled
      -Dllvm=enabled
      -Dshared-llvm=enabled
      -Dgallium-va=disabled
      --prefix=/usr
   )

   if [[ -n "${MESA_MESON_ARGS:-}" ]]; then
      # Intentional word splitting lets callers pass normal Meson arguments.
      # shellcheck disable=SC2206
      setup_args+=( ${MESA_MESON_ARGS} )
   fi

   if [[ "${arch}" == 32 ]]; then
      local cross_file="${BUILD_ROOT}/cross-i686-linux.ini"
      write_cross_file_32 "${cross_file}"
      setup_args+=( "--cross-file=${cross_file}" )
   fi

   if [[ -f "${build_dir}/meson-private/coredata.dat" ]]; then
      meson setup --reconfigure "${build_dir}" "${SOURCE_DIR}" "${setup_args[@]}"
   else
      meson setup "${build_dir}" "${SOURCE_DIR}" "${setup_args[@]}"
   fi
}

compile_arch()
{
   local arch="$1"
   local -a compile_args=(compile -C "${BUILD_ROOT}/${arch}")

   meson_setup "${arch}"
   if [[ -n "${MESA_JOBS:-}" ]]; then
      compile_args+=( -j "${MESA_JOBS}" )
   fi
   meson "${compile_args[@]}"
}

install_arch()
{
   local arch="$1"

   compile_arch "${arch}"
   DESTDIR="${INSTALL_ROOT}/${arch}" meson install -C "${BUILD_ROOT}/${arch}"
   printf 'Staged %s-bit build in %s\n' "${arch}" "${INSTALL_ROOT}/${arch}"
}

clean_arch()
{
   local arch="$1"
   local target="${BUILD_ROOT}/${arch}"

   [[ "${target}" == "${BUILD_ROOT}/64" || "${target}" == "${BUILD_ROOT}/32" ]] ||
      die "refusing to clean unexpected path: ${target}"
   rm -rf -- "${target}"
}

main()
{
   local target
   local action
   local pkg_config_libdir_32
   local native_pkg_config_libdir="${PKG_CONFIG_LIBDIR-}"
   local native_pkg_config_path="${PKG_CONFIG_PATH-}"
   local had_native_pkg_config_libdir="${PKG_CONFIG_LIBDIR+x}"
   local had_native_pkg_config_path="${PKG_CONFIG_PATH+x}"
   local -a arches

   [[ $# -le 2 ]] || {
      usage
      exit 2
   }

   if [[ "${1:-}" == package ]]; then
      [[ $# -eq 1 ]] || die "the package shorthand takes no second argument"
      target=all
      action=package
   else
      target="${1:-all}"
      action="${2:-build}"
   fi

   case "${target}" in
   64|32) arches=( "${target}" ) ;;
   all) arches=( 64 32 ) ;;
   -h|--help)
      usage
      return
      ;;
   *) die "unknown target '${target}' (expected 64, 32, or all)" ;;
   esac

   case "${action}" in
   build|install)
      require_command meson
      require_command "${NINJA:-ninja}"
      require_command pkg-config
      require_command cmake
      require_command glslangValidator
      ;;
   clean) ;;
   package)
      [[ "${target}" == all ]] ||
         die "Arch packaging always builds the paired 64-bit and 32-bit packages"
      "${SOURCE_DIR}/build-arch-package.sh"
      return
      ;;
   *) die "unknown action '${action}' (expected build, install, clean, or package)" ;;
   esac

   pkg_config_libdir_32="${PKG_CONFIG_LIBDIR_32:-$(default_pkg_config_libdir_32)}"

   for arch in "${arches[@]}"; do
      if [[ "${arch}" == 32 ]]; then
         export PKG_CONFIG_LIBDIR="${pkg_config_libdir_32}"
         export PKG_CONFIG_PATH="${PKG_CONFIG_PATH_32:-}"
      else
         if [[ -n "${had_native_pkg_config_libdir}" ]]; then
            export PKG_CONFIG_LIBDIR="${native_pkg_config_libdir}"
         else
            unset PKG_CONFIG_LIBDIR
         fi
         if [[ -n "${had_native_pkg_config_path}" ]]; then
            export PKG_CONFIG_PATH="${native_pkg_config_path}"
         else
            unset PKG_CONFIG_PATH
         fi
      fi

      case "${action}" in
      build) compile_arch "${arch}" ;;
      install) install_arch "${arch}" ;;
      clean) clean_arch "${arch}" ;;
      esac
   done
}

main "$@"
