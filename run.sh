#!/usr/bin/env bash
########
## Usage: curl -fsSL https://raw.githubusercontent.com/zennozen/Infra-shell/refs/heads/<branch_name>/run.sh | bash /dev/stdin <branch_name>
########
set -e

GITHUB_PROXY="https://ghproxy.net"
BRANCH=$1
PROJ_URL="$GITHUB_PROXY/https://github.com/zennozen/Infra-shell/archive/refs/heads/$BRANCH.zip"

which unzip || dnf install -y unzip
wget -c $PROJ_URL && unzip $BRANCH.zip
cd Infra-shell-$BRANCH && ls -l

bash build ls
bash build
