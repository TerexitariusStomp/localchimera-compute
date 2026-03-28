#!/usr/bin/env guile
!#
;;; deploy/guix/deploy.sh — load secrets and run guix deploy
;;; Usage: ./deploy/guix/deploy.sh

(primitive-load "deploy/guix/secrets.scm")
(apply execlp "guix" "guix" "deploy"
       "-L" "deploy/guix"
       "deploy/guix/machines.scm"
       (cdr (command-line)))
