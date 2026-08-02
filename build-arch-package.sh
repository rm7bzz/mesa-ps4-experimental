#!/usr/bin/env bash
# Build native and multilib Arch packages, or publish existing packages.

set -euo pipefail

readonly SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly OUTPUT_DIR="${MESA_PACKAGE_OUTPUT:-${SOURCE_DIR}/packages}"
readonly ARCH_IMAGE="${MESA_ARCH_IMAGE:-docker.io/library/archlinux:base-devel}"
readonly RELEASE_REPOSITORY="${MESA_GITHUB_REPOSITORY:-rm7bzz/mesa-ps4-experimental}"

die()
{
   printf 'build-arch-package.sh: %s\n' "$*" >&2
   exit 1
}

usage()
{
   cat <<'EOF'
Usage: ./build-arch-package.sh [rebuild|release]

With no argument, an interactive menu chooses whether to rebuild or upload the
newest existing native/lib32 package pair to a GitHub Release.

Environment overrides:
  MESA_CONTAINER_ENGINE    docker or podman executable
  MESA_ARCH_IMAGE          Arch container image
  MESA_PACKAGE_OUTPUT      package input/output directory
  MESA_GITHUB_REPOSITORY   GitHub OWNER/REPO for releases
  MESA_RELEASE_TAG         explicit release tag override
EOF
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

rebuild_packages()
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

choose_action()
{
   local choice

   [[ -t 0 ]] ||
      die "no action supplied in non-interactive mode (use 'rebuild' or 'release')"

   printf 'What do you want to do?\n' >&2
   printf '  1) Rebuild the Arch packages\n' >&2
   printf '  2) Upload the existing packages to a GitHub Release\n' >&2
   printf '  3) Exit\n' >&2
   read -r -p 'Choice [1-3]: ' choice

   case "${choice}" in
   1) printf '%s' rebuild ;;
   2) printf '%s' release ;;
   3) printf '%s' exit ;;
   *) die "invalid choice: ${choice}" ;;
   esac
}

publish_packages()
{
   local candidate
   local latest_native=''
   local native_basename
   local lib32_package
   local package_id
   local release_tag
   local release_title
   local target_commit
   local short_commit
   local release_notes
   local -a candidates
   local -a assets

   command -v gh >/dev/null 2>&1 ||
      die "GitHub CLI not found; install 'gh', then run 'gh auth login'"
   gh auth status --hostname github.com >/dev/null 2>&1 ||
      die "GitHub CLI is not authenticated; run 'gh auth login'"

   shopt -s nullglob
   candidates=( "${OUTPUT_DIR}"/mesa-ps4-experimental-*.pkg.tar.zst )
   shopt -u nullglob
   (( ${#candidates[@]} > 0 )) ||
      die "no native Arch package found in ${OUTPUT_DIR}"

   for candidate in "${candidates[@]}"; do
      if [[ -z "${latest_native}" || "${candidate}" -nt "${latest_native}" ]]; then
         latest_native="${candidate}"
      fi
   done

   native_basename="$(basename "${latest_native}")"
   lib32_package="${OUTPUT_DIR}/lib32-${native_basename}"
   [[ -f "${lib32_package}" ]] ||
      die "matching lib32 package not found: ${lib32_package}"

   package_id="${native_basename#mesa-ps4-experimental-}"
   package_id="${package_id%-x86_64.pkg.tar.zst}"
   release_tag="${MESA_RELEASE_TAG:-mesa-ps4-${package_id//:/-}}"
   release_title="Mesa PS4 experimental ${package_id}"

   if [[ "${package_id}" =~ \.g([0-9a-fA-F]{7,40})-[0-9]+$ ]]; then
      short_commit="${BASH_REMATCH[1]}"
      target_commit="$(git -C "${SOURCE_DIR}" rev-parse "${short_commit}^{commit}")" ||
         die "package commit ${short_commit} is not present in this Git clone"
   else
      die "cannot recover the source commit from package version: ${package_id}"
   fi

   assets=( "${latest_native}" "${lib32_package}" )
   release_notes="$(printf \
      'Arch Linux native and multilib packages for PS4 Mesa commit `%s`.\n\nAssets:\n- `%s`\n- `%s`' \
      "${target_commit}" "${native_basename}" "$(basename "${lib32_package}")")"

   printf 'Repository: %s\n' "${RELEASE_REPOSITORY}"
   printf 'Release tag: %s\n' "${release_tag}"
   printf 'Source commit: %s\n' "${target_commit}"
   printf 'Uploading:\n  %s\n  %s\n' "${assets[0]}" "${assets[1]}"

   if gh release view "${release_tag}" --repo "${RELEASE_REPOSITORY}" \
      >/dev/null 2>&1; then
      printf 'Release already exists; replacing matching assets.\n'
      gh release upload "${release_tag}" "${assets[@]}" \
         --repo "${RELEASE_REPOSITORY}" --clobber
   else
      gh release create "${release_tag}" "${assets[@]}" \
         --repo "${RELEASE_REPOSITORY}" \
         --target "${target_commit}" \
         --title "${release_title}" \
         --notes "${release_notes}" \
         --prerelease
   fi

   gh release view "${release_tag}" --repo "${RELEASE_REPOSITORY}" \
      --json url --jq .url
}

main()
{
   local action="${1:-}"

   [[ $# -le 1 ]] || {
      usage
      exit 2
   }

   case "${action}" in
   '') action="$(choose_action)" ;;
   -h|--help)
      usage
      return
      ;;
   esac

   case "${action}" in
   rebuild) rebuild_packages ;;
   release) publish_packages ;;
   exit) return ;;
   *) die "unknown action '${action}' (expected rebuild or release)" ;;
   esac
}

main "$@"
