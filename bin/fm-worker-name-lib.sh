#!/usr/bin/env bash

fm_worker_numbered_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*-[1-9][0-9]*$ ]]
}

fm_worker_name_valid() {
  local id=$1 name=$2 suffix
  [ "$name" != "$id" ] || return 0
  fm_worker_numbered_id "$id" || return 1
  case "$name" in "$id"-*) ;; *) return 1 ;; esac
  suffix=${name#"$id"-}
  [[ "$suffix" =~ ^[a-z0-9]{1,16}(-[a-z0-9]{1,16}){0,2}$ ]]
}

fm_worker_name_from_brief() {
  local id=$1 name record
  record=$(sed -n '1,3{/^Worker name: /p;}' "$2") || return 1
  name=$id
  [ -z "$record" ] || name=${record#Worker name: }
  fm_worker_name_valid "$id" "$name" || return 1
  printf '%s\n' "$name"
}

fm_worker_name_from_ticket() {
  local id=$1 data=$2 row suffix
  if fm_worker_numbered_id "$id" &&
     fm_backlog_source_present "$data" "$data" &&
     row=$(fm_backlog_row_show "$data" "$id" --full); then
    suffix=$(printf '%s\n' "$row" | FM_WORKER_PROJECT="${id%-*}" LC_ALL=C perl -MJSON::PP -ne '
      next unless /^  title: (.*)$/;
      my ($title, $project) = ($1, lc $ENV{FM_WORKER_PROJECT});
      $title = JSON::PP->new->utf8->allow_nonref->decode($title) if $title =~ /^"/;
      $title =~ s/^\Q$project\E:\s*//i;
      my @words = map { substr($_, 0, 16) } lc($title) =~ /([a-z0-9]+)/g;
      splice @words, 3 if @words > 3;
      print join "-", @words;
      exit;
    ') || return 1
    printf '%s\n' "$id${suffix:+-$suffix}"
  else
    printf '%s\n' "$id"
  fi
}
