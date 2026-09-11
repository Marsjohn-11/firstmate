#!/usr/bin/env bash
# Classify a project's delivery rail from its git origin, and parse a CRUX CR URL.
#
# A project ships either through a forge pull/merge request (GitHub, GitLab,
# Bitbucket, ...) or through an Amazon CRUX code review (code.amazon.com). The
# rail is a property of where the repository lives, so it is derived from the
# origin host rather than configured by hand.
#
# This is deliberately a SEPARATE owner from bin/fm-project-origin-lib.sh. That
# file validates structure and safety only and forbids any host or forge
# allowlist, because any host must be able to serve a clone. Rail classification
# is the opposite question - it reads the host on purpose - so it lives here and
# never leaks a host judgement back into origin validation.
#
# Two rails:
#   crux-cr   an Amazon gitfarm origin (git.amazon.com, code.amazon.com, or any
#             *.amazon.com host); ships via a CRUX code review and NEVER an
#             autonomous merge (AGENTS.md section 7, CR rail always escalates)
#   forge     everything else; ships via a forge PR/MR on the existing fm-pr path
#
# The default on an unrecognized or unreadable origin is "forge", which keeps
# the established PR path and never silently routes work onto the CR rail.

FM_CR_URL=
FM_CR_ID=

# Extract the bare host from an accepted origin URL. Handles scheme URLs
# (https://, ssh://, git://), scp-like [user@]host:path, and leaves anything
# else empty. Amazon gitfarm hosts are plain DNS names, so IPv6-literal parsing
# is intentionally out of scope here.
fm_delivery_host_from_origin() { # <url>; prints lowercase host or nothing
  local url=${1-} rest authority host
  local LC_ALL=C
  case "$url" in
    '' | *[[:space:]]* | *[[:cntrl:]]*) return 1 ;;
  esac
  case "$url" in
    *://*)
      rest=${url#*://}
      authority=${rest%%/*}
      host=${authority##*@}
      host=${host%%:*}
      ;;
    *:*)
      rest=${url%%:*}
      host=${rest##*@}
      ;;
    *)
      return 1 ;;
  esac
  case "$host" in
    '' | *[!A-Za-z0-9.-]*) return 1 ;;
  esac
  printf '%s\n' "$host" | tr '[:upper:]' '[:lower:]'
}

# Classify a host into a rail. Amazon gitfarm hosts serve CRUX; everything else
# is a forge.
fm_delivery_target_from_host() { # <host>; prints crux-cr | forge
  local host=${1-}
  local LC_ALL=C
  case "$host" in
    amazon.com | *.amazon.com) printf 'crux-cr\n' ;;
    *) printf 'forge\n' ;;
  esac
}

# Classify an origin URL directly. An unparseable origin is a forge, so the
# default keeps the PR path rather than routing onto the CR rail.
fm_delivery_target_from_origin() { # <url>; prints crux-cr | forge
  local host
  host=$(fm_delivery_host_from_origin "${1-}") || { printf 'forge\n'; return 0; }
  fm_delivery_target_from_host "$host"
}

# Classify the rail of a git working directory from its origin remote. Prints
# "forge" when the directory is not a git repo or has no origin, so a caller
# never has to distinguish "no origin" from "forge origin".
fm_delivery_target_of_dir() { # <dir>; prints crux-cr | forge
  local dir=${1-} origin
  if ! origin=$(git -C "$dir" remote get-url origin 2>/dev/null) || [ -z "$origin" ]; then
    printf 'forge\n'
    return 0
  fi
  fm_delivery_target_from_origin "$origin"
}

# Parse a canonical CRUX code-review URL into FM_CR_URL and FM_CR_ID. Only the
# canonical https://code.amazon.com/reviews/CR-<digits> shape is accepted, with
# no trailing path, query, or fragment, so a stored CR identity round-trips to
# exactly the URL it came from.
fm_cr_url_parse() { # <url>; 0 on a valid CR URL
  local raw=${1-}
  local LC_ALL=C
  FM_CR_URL=
  FM_CR_ID=
  case "$raw" in
    *[[:space:]]* | *[[:cntrl:]]*) return 1 ;;
  esac
  [[ "$raw" =~ ^https://code\.amazon\.com/reviews/(CR-[1-9][0-9]*)$ ]] || return 1
  # Consumed by callers such as bin/fm-cr-check.sh, which read the canonical URL
  # and id back out of these globals after a successful parse.
  # shellcheck disable=SC2034
  FM_CR_URL=$raw
  # shellcheck disable=SC2034
  FM_CR_ID=${BASH_REMATCH[1]}
}
