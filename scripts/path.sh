#!/usr/bin/env bash

# Sets ADOC_SAFE_PATH or ADOC_PATH_ERROR without following a symlink outside
# the checkout. Call again immediately before every write to close delivery
# races as far as a shell Action can without an OS sandbox.
adoc_validate_target() { # root, repository-relative .adoc path
  local root="$1" relative="$2" canonical_root current candidate resolved part index
  local -a parts
  ADOC_SAFE_PATH=
  ADOC_PATH_ERROR=

  [ "$(printf %s "$relative" | wc -c | tr -d ' ')" -le 4096 ] \
    || { ADOC_PATH_ERROR='file path exceeds 4096 bytes'; return 1; }
  case "$relative" in
    '' | /*) ADOC_PATH_ERROR='file path must be repository-relative'; return 1 ;;
    *\\*) ADOC_PATH_ERROR='file path contains an alternate separator'; return 1 ;;
    *.adoc) ;;
    *) ADOC_PATH_ERROR='file path must end in .adoc'; return 1 ;;
  esac
  if printf %s "$relative" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    ADOC_PATH_ERROR='file path contains a control character'
    return 1
  fi
  case "/$relative/" in
    *//* | */./* | */../*) ADOC_PATH_ERROR='file path contains an empty, dot, or parent component'; return 1 ;;
  esac

  canonical_root="$(realpath "$root")" \
    || { ADOC_PATH_ERROR='checkout root cannot be resolved'; return 1; }
  current="$canonical_root"
  IFS=/ read -r -a parts <<< "$relative"
  index=0
  for part in "${parts[@]}"; do
    candidate="$current/$part"
    if [ -L "$candidate" ]; then
      ADOC_PATH_ERROR='file path contains a symlink'
      return 1
    fi
    if [ -e "$candidate" ]; then
      resolved="$(realpath "$candidate")" \
        || { ADOC_PATH_ERROR='file path cannot be resolved'; return 1; }
      case "$resolved" in
        "$canonical_root" | "$canonical_root"/*) ;;
        *) ADOC_PATH_ERROR='file path resolves outside the checkout'; return 1 ;;
      esac
      if [ "$index" -lt "$((${#parts[@]} - 1))" ] && [ ! -d "$resolved" ]; then
        ADOC_PATH_ERROR='file path has a non-directory parent component'
        return 1
      fi
      current="$resolved"
    else
      current="$candidate"
    fi
    index=$((index + 1))
  done
  # shellcheck disable=SC2034 # callers read this global after sourcing
  ADOC_SAFE_PATH="$current"
}

adoc_require_target() {
  if ! adoc_validate_target "$1" "$2"; then
    echo "::error::action.proposal_rejected: ${ADOC_PATH_ERROR}" >&2
    return 1
  fi
}
