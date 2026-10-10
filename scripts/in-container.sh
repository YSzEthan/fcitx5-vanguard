#!/bin/sh
# 在 mint-dev 容器內、帶著 swiftly 環境執行指令。用法：./scripts-enter.sh '<bash 指令>'
exec distrobox enter mint-dev -- bash -lc ". \$HOME/.local/share/swiftly/env.sh; $1"
