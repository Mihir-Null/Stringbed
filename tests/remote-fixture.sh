#!/bin/sh
# Disposable loopback SSH transport test; never invokes Nix or activation.
set -eu
RACKET=${RACKET:-racket}
fixture=$(mktemp -d)
trap 'test ! -f "$fixture/pid" || kill "$(cat "$fixture/pid")" 2>/dev/null || :; rm -rf "$fixture"' EXIT HUP INT TERM
ssh-keygen -q -t ed25519 -N '' -f "$fixture/host"
ssh-keygen -q -t ed25519 -N '' -f "$fixture/client"
cp "$fixture/client.pub" "$fixture/authorized_keys"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
cat > "$fixture/sshd_config" <<CONFIG
ListenAddress 127.0.0.1
Port $port
HostKey $fixture/host
PidFile $fixture/pid
AuthorizedKeysFile $fixture/authorized_keys
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
UsePAM no
AllowUsers $(id -un)
CONFIG
mkdir -p /run/sshd
/usr/sbin/sshd -f "$fixture/sshd_config" -E "$fixture/log"
cat > "$fixture/ssh_config" <<CONFIG
Host stringbed-fixture
 HostName 127.0.0.1
 Port $port
 User $(id -un)
 IdentityFile $fixture/client
 IdentitiesOnly yes
 StrictHostKeyChecking no
 UserKnownHostsFile /dev/null
CONFIG
cat > "$fixture/check.rkt" <<RACKETCODE
#lang racket/base
(require rackunit (file "$(pwd)/stringbed/operations.rkt"))
(define original (current-runner))
(parameterize ([current-runner (lambda (program args)
  (original program (if (equal? program "ssh") (append (list "-F" "$fixture/ssh_config") args) args)))])
  (check-equal? (target-command "stringbed-fixture" "printf" '("%s" "quotes' spaces; dollar\$()")) "quotes' spaces; dollar\$()")
  (check-exn exn:fail? (lambda () (target-command "stringbed-fixture" "sh" '("-c" "exit 7"))))
  (target-command "stringbed-fixture" "mkdir" '("--" "$fixture/lock"))
  (check-exn exn:fail? (lambda () (target-command "stringbed-fixture" "mkdir" '("--" "$fixture/lock"))))
  (target-command "stringbed-fixture" "rmdir" '("--" "$fixture/lock"))
  (parameterize ([current-process-timeout 0.2])
    (check-exn #rx"timed out" (lambda () (target-command "stringbed-fixture" "sleep" '("3"))))))
(displayln "Disposable SSH: quoting, atomic lock collision, failure, timeout passed")
RACKETCODE
"$RACKET" "$fixture/check.rkt"
