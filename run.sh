#!/usr/bin/env bash
#####################################
## Usage: br=<branch_name> && curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/zennozen/Infra-shell/refs/heads/$br/run.sh | bash /dev/stdin $br
#####################################
set -e

GITHUB_PROXY="https://ghproxy.net"
LATEST_VER="$(curl -s "https://api.github.com/repos/zennozen/Infra-shell/releases/latest" | awk -F'"|v' '/tag_name/{printf $5}')"
RELEASE_URL="$GITHUB_PROXY/https://github.com/zennozen/Infra-shell/archive/refs/tags/v$LATEST_VER.tar.gz"

curl -C - -L -o Infra-shell_v$LATEST_VER.tar.gz "$RELEASE_URL"
tar -zxf Infra-shell_v$LATEST_VER.tar.gz && rm -rf $_

echo -e "\033[1;32m
Usage: 
    cd Infra-shell-$LATEST_VER && ls -l
    bash build ls
    bash build gr k8s.sh

    cd output
    bash k8s.sh
\033[0m"