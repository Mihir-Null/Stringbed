#!/usr/bin/env bash
set -euo pipefail
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
racket stringbed/main.rkt init "$work/home.sbd"
racket stringbed/main.rkt edit "$work/home.sbd" '(add package "search" #hash((attribute . "ripgrep")))'
racket stringbed/main.rkt edit "$work/home.sbd" '(set "search" attribute "fd")'
racket stringbed/main.rkt edit "$work/home.sbd" '(note "search" "My note")'
racket stringbed/main.rkt edit "$work/home.sbd" '(why "search")' | grep -q 'My note'
printf '(note "search" "temporary")\n(undo)\n(save)\nquit\n' | racket stringbed/main.rkt tui "$work/home.sbd"
racket stringbed/main.rkt edit "$work/home.sbd" '(why "search")' | grep -q 'My note'
printf '2\npackage\nmenu-node\nfd\n3\nmenu-node\nattribute\njq\n7\nq\n' | racket stringbed/main.rkt tui "$work/home.sbd"
racket stringbed/main.rkt edit "$work/home.sbd" '(why "menu-node")' | grep -q jq
racket stringbed/main.rkt generate examples/programmatic.rkt "$work/generated.sbd"
racket stringbed/main.rkt edit "$work/generated.sbd" '(validate)'
racket stringbed/main.rkt --extension extensions/web-service.rkt edit examples/server.sbd '(nix)' | grep -q nginx
racket stringbed/main.rkt inspect | grep -q 'kernel='
if racket stringbed/main.rkt not-a-command; then
  echo 'invalid command unexpectedly succeeded' >&2; exit 1
fi
if racket stringbed/main.rkt tui "$work/home.sbd" ignored; then
  echo 'extra arguments unexpectedly succeeded' >&2; exit 1
fi
