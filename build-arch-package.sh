#!/usr/bin/env bash
# Build native and multilib Arch packages from an arbitrary Linux host.

set -euo pipefail

readonly SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly OUTPUT_DIR="${MESA_PACKAGE_OUTPUT:-${SOURCE_DIR}/packages}"
readonly ARCH_IMAGE="${MESA_ARCH_IMAGE:-docker.io/library/archlinux:base-devel}"

die()
{
   printf 'build-arch-package.sh: %s\n' "$*" >&2
   exit 1
}

find_container_engine()
{
   if [[ -n "${MESA_CONTAINER_ENGINE:-}" ]]; then
      command -v "${MESA_CONTAINER_ENGINE}" >/dev/null 2>&1 ||
         die "container engine not found: ${MESA_CONTAINER_ENGINE}"
      printf '%s' "${MESA_CONTAINER_ENGINE}"
   elif command -v podman >/dev/null 2>&1; then
      printf '%s' podman
   elif command -v docker >/dev/null 2>&1; then
      printf '%s' docker
   else
      die "Docker or Podman is required to produce Arch-linked packages"
   fi
}

main()
{
   local engine
   local uid
   local gid
   local -a run_args

   command -v git >/dev/null 2>&1 || die "git is required"
   git -C "${SOURCE_DIR}" rev-parse --verify HEAD >/dev/null

   engine="$(find_container_engine)"
   uid="$(id -u)"
   gid="$(id -g)"
   mkdir -p -- "${OUTPUT_DIR}"

   run_args=(
      run --rm
      -e "HOST_UID=${uid}"
      -e "HOST_GID=${gid}"
      -v "${SOURCE_DIR}:/source:ro"
      -v "${OUTPUT_DIR}:/out"
   )

   printf 'Building Arch packages from Mesa commit %s with %s\n' \
      "$(git -C "${SOURCE_DIR}" rev-parse --short=12 HEAD)" "${engine}"
   "${engine}" "${run_args[@]}" "${ARCH_IMAGE}" \
      /bin/bash /source/packaging/arch/build-in-container.sh

   printf 'Arch packages written to %s\n' "${OUTPUT_DIR}"
}

main "$@"
