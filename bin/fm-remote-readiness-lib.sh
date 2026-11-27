#!/usr/bin/env bash
# fm_remote_readiness_ensure <bin-dir> <route> [backend] [herdr-session]: 0 ready, 1 a gap remains, 255 SSH did not complete.
# The verdict is a read-only doctor run after any repair, and FM_REMOTE_READINESS_OUT holds its output.

# Consumed by the sourcing caller, so every assignment reads as unused here.
# shellcheck disable=SC2034
FM_REMOTE_READINESS_OUT=

fm_remote_readiness_probe() { # <bin-dir> <route> [doctor-args...]
  local bin_dir=$1 id=$2 out rc
  shift 2
  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh "$@" </dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  return "$rc"
}

fm_remote_readiness_ensure() { # <bin-dir> <route> [backend] [herdr-session]
  local bin_dir=$1 id=$2 backend=${3:-any} session=${4:-} rc
  local -a doctor_args=() session_args=()
  case "$backend" in
    any) ;;
    herdr) doctor_args=(--backend herdr) ;;
    *) echo "error: unsupported remote backend '$backend'" >&2; return 1 ;;
  esac
  [ -z "$session" ] || session_args=(--session "$session")

  fm_remote_readiness_probe "$bin_dir" "$id" ${doctor_args[@]+"${doctor_args[@]}"} ${session_args[@]+"${session_args[@]}"}
  rc=$?
  if [ "$rc" -eq 2 ] && [ "$backend" = herdr ]; then
    # A remote still on the herdr-only doctor refuses --backend entirely, and
    # the request without it is the same there.
    fm_remote_readiness_probe "$bin_dir" "$id" ${session_args[@]+"${session_args[@]}"}
    rc=$?
  fi
  [ "$rc" -ne 0 ] || return 0
  [ "$rc" -ne 255 ] || return 255

  fm_remote_readiness_probe "$bin_dir" "$id" --fix ${doctor_args[@]+"${doctor_args[@]}"} ${session_args[@]+"${session_args[@]}"}
  rc=$?
  if [ "$rc" -eq 2 ] && [ "$backend" = herdr ]; then
    fm_remote_readiness_probe "$bin_dir" "$id" --fix ${session_args[@]+"${session_args[@]}"}
    rc=$?
  fi
  [ "$rc" -ne 255 ] || return 255

  fm_remote_readiness_probe "$bin_dir" "$id" ${doctor_args[@]+"${doctor_args[@]}"} ${session_args[@]+"${session_args[@]}"}
  rc=$?
  if [ "$rc" -eq 2 ] && [ "$backend" = herdr ]; then
    fm_remote_readiness_probe "$bin_dir" "$id" ${session_args[@]+"${session_args[@]}"}
    rc=$?
  fi
  [ "$rc" -ne 255 ] || return 255
  [ "$rc" -eq 0 ] || return 1
  return 0
}
