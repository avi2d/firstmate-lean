#!/usr/bin/env bash
# Sourced. Owns the Lavish address a board URL handed to the supervising home names.

fm_lavish_address_valid() {  # <host:port>
  local address=$1 host port
  port=${address##*:}
  host=${address%:*}
  [ "$host" != "$address" ] && [ -n "$host" ] || return 1
  case "$port" in ''|0*|*[!0-9]*) return 1 ;; esac
  [ "${#port}" -le 5 ] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
  case "$host" in
    '['*']') host=${host#[}; host=${host%]}
      case "$host" in ''|*[!0-9A-Fa-f:.]*) return 1 ;; esac ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

# Sets FM_LAVISH_SUPERVISOR_SCOPE to local (not an execution home, the file is
# never read), configured (FM_LAVISH_SUPERVISOR_ADDRESS is set), or
# unconfigured. A present but unusable file prints an error and returns 1.
fm_lavish_supervisor_address_load() {  # <home> <config-dir>
  local home=$1 file="$2/lavish-axi-supervisor-address" address
  FM_LAVISH_SUPERVISOR_ADDRESS=
  FM_LAVISH_SUPERVISOR_SCOPE=local
  [ -f "$home/.fm-exec-home" ] && [ ! -L "$home/.fm-exec-home" ] || return 0
  FM_LAVISH_SUPERVISOR_SCOPE=unconfigured
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ] || ! address=$(cat "$file"); then
    printf 'error: config/lavish-axi-supervisor-address must be a readable regular file\n' >&2
    return 1
  fi
  if ! fm_lavish_address_valid "$address"; then
    printf 'error: config/lavish-axi-supervisor-address must contain one host:port address without whitespace\n' >&2
    return 1
  fi
  FM_LAVISH_SUPERVISOR_ADDRESS=$address
  FM_LAVISH_SUPERVISOR_SCOPE=configured
}

# Call after fm_lavish_supervisor_address_load.
fm_lavish_supervisor_url() {  # <http://host:port/path>
  local url=$1 path
  if [ "$FM_LAVISH_SUPERVISOR_SCOPE" != configured ]; then
    printf '%s\n' "$url"
    return 0
  fi
  path=${url#http://}
  case "$path" in */*) path=/${path#*/} ;; *) path= ;; esac
  printf 'http://%s%s\n' "$FM_LAVISH_SUPERVISOR_ADDRESS" "$path"
}
