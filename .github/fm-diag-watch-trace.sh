#!/usr/bin/env bash
exec 199>> "$(dirname "$FM_HOME")/watch-trace.$$"
BASH_XTRACEFD=199 PS4='+ ${EPOCHREALTIME} ${BASH_SOURCE##*/}:${LINENO}: ' exec bash -x "$FM_DIAG_REAL_WATCH" "$@"
