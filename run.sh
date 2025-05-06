#!/usr/bin/env bash
#####################################
## Usage: br=<branch_name> && curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/zennozen/Infra-shell/refs/heads/$br/run.sh | bash /dev/stdin $br
#####################################
set -e

GITHUB_PROXY="https://ghproxy.net"
BRANCH=$1
PROJ_URL="$GITHUB_PROXY/https://github.com/zennozen/Infra-shell/archive/refs/heads/$BRANCH.zip"

which wget || dnf install -y wget
which unzip || dnf install -y unzip
wget -c $PROJ_URL && unzip $BRANCH.zip && rm -rf $_

echo -e "Usage: 
cd Infra-shell-$BRANCH
bash build ls
bash build gr k8s.sh

cd output
bash k8s.sh"
