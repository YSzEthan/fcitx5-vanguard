#!/bin/sh
# 在開發容器內執行指令。用法：./scripts/in-container.sh '<bash 指令>'
# 預設進 mint-dev（Ubuntu 24.04，有 Swift 工具鏈）；要進 Arch 的容器：
#   VANGUARD_CONTAINER=arch-dev ./scripts/in-container.sh '<bash 指令>'
exec distrobox enter "${VANGUARD_CONTAINER:-mint-dev}" -- bash -lc \
  "[ -f \$HOME/.local/share/swiftly/env.sh ] && . \$HOME/.local/share/swiftly/env.sh; $1"
