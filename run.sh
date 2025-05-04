#!/usr/bin/env bash
set -e

GITHUB_PROXY="https://ghproxy.net"
BRANCH=$1
PROJ_URL="$GITHUB_PROXY/https://github.com/zennozen/Infra-shell/archive/refs/heads/$BRANCH.zip"

wget -c $PROJ_URL && unzip $BRANCH.zip
cd Infra-shell-$BRANCH && ls -l

bash build ls
bash build
