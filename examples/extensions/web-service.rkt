#lang racket/base
(require "../../stringbed/extension.rkt")
(provide forms)
;; A genuinely external form: no core/UI dispatch changes required.
(define forms
  (list (form 'web-service "Nginx service with a configurable listener"
    (list (field 'port 'port 8080 "TCP listener")
          (field 'root 'string "/srv/www" "Document root"))
    (lambda (p w)
      (unless (eq? (hash-ref w 'target) 'nixos) (error 'web-service "requires a NixOS workspace"))
      (list (assignment '("services" "nginx" "enable") #t)
            (assignment '("services" "nginx" "virtualHosts" "localhost" "root") (hash-ref p 'root))
            (assignment '("services" "nginx" "defaultHTTPListenPort") (hash-ref p 'port)))))))
