#!/bin/sh
# GUL-2096 / AC-1: the program names its output exactly.
# `sh host/paperclip-air/factory-probe-d/greet.sh` prints `hello factory`
# (one line, no arguments, no extra text) and exits 0.
set -eu

printf 'hello factory\n'
