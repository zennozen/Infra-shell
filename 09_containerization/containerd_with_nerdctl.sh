#!/usr/bin/env bash
# https://github.com/containerd/nerdctl
set -o errexit

script_path="$(dirname ${BASH_SOURCE[0]})"
abs_script_path="$(realpath "${BASH_SOURCE[0]}")"
workdir="$(dirname "$abs_script_path")"

# import some define
source "$script_path/../00_utils/_print.sh"
source "$script_path/../00_utils/_trap.sh"
source "$script_path/../00_utils/_logger.sh"

# capture errors and print environment variables
trap '_trap_print_env \
  NERDCTL_VER NERDCTL_URL CONTAINERD_CONF CONTAINERD_ACCELERATION_DIR \
  CONTAINERD_PROXY_ENDPOINT CONTAINERD_PROXY_CONF
' ERR

# define golabal variables
GITHUB_PROXY="https://ghproxy.net"
NERDCTL_URL_PREFIX="$GITHUB_PROXY/https://github.com/containerd/nerdctl/releases/download"
CONTAINERD_CONF="/etc/containerd/config.toml"
CONTAINERD_ACCELERATION_DIR="$(echo $CONTAINERD_CONF | cut -d'/' -f-3)/certs.d"
CONTAINERD_PROXY_ENDPOINT="$3"
CONTAINERD_PROXY_CONF="/etc/systemd/system/containerd.service.d/http-proxy.conf"


#######################################
## Main Business Logic Begins
#######################################

function install() {
  _print_line title "Install Containerd with Nerdctl"
  # check_args
  ! which nerdctl 2>/dev/null || { _logger error "nerdctl already install on system." && exit 1; }
  ! which containerd 2>/dev/null || { _logger error "containerd already install on system." && exit 1; }

  local NERDCTL_VER="$2"

  if [[ -z $NERDCTL_VER ]]; then
    _logger warn "User not defined version number, auto-get latest official version."
    NERDCTL_VER="$(curl -s https://api.github.com/repos/containerd/nerdctl/releases/latest | \
      grep '"tag_name":' | awk -F 'v|"' '{print $5}')"
  fi
  if [[ -z $NERDCTL_VER ]]; then
    _logger warn "Failed to get latest version number, default to 2.0.4"
    NERDCTL_VER="2.0.4"
  fi
  local NERDCTL_URL="$NERDCTL_URL_PREFIX/v$NERDCTL_VER/nerdctl-full-$NERDCTL_VER-linux-amd64.tar.gz"

  _logger info "1. Update system config"
  _logger info "1.1 Enable the netfilter module to support routing forwarding"
  echo "br_netfilter" | tee /etc/modules-load.d/br_netfilter.conf
  systemctl restart systemd-modules-load
  lsmod | grep "br_netfilter"

  _logger info "1.2 Enable kernel routing forwarding, bridge filtering, and prefer to avoid using swap space, etc."
  sed -i '/^net.ipv4.ip_forward/s/0/1/g' /etc/sysctl.conf && sysctl -p
  tee /etc/sysctl.d/container.conf <<-EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
vm.swappiness = 0
vm.overcommit_memory = 1
vm.panic_on_oom = 0
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 1048576
fs.file-max = 52706963
fs.nr_open = 52706963
net.ipv6.conf.all.disable_ipv6 = 1
net.netfilter.nf_conntrack_max = 2310720
EOF
  sysctl -p /etc/sysctl.d/container.conf

  ## To speed up deployment, commenting out less commonly used snapshot services
  # _logger info "2. Install the ZFS file system module to support snapshot services"
  # dnf install https://zfsonlinux.org/epel/zfs-release-2-3$(rpm --eval "%{dist}").noarch.rpm
  # dnf config-manager --disable zfs
  # dnf config-manager --enable zfs-kmod
  # dnf install zfs

  _logger info "3. Download and extract install containerd with nerdctl"
  cd /usr/local/src
  if [[ -f nerdctl-full-$NERDCTL_VER-linux-amd64.tar.gz ]]; then
    _logger warn "nerdctl-full-$NERDCTL_VER-linux-amd64.tar.gz is already exists in /usr/local/src/, will use."
  else
    wget --tries=5 --timeout=60 -c $NERDCTL_URL
  fi
  tar -xzf nerdctl-full-$NERDCTL_VER-linux-amd64.tar.gz -C /usr/local
  mkdir -p /opt/cni/bin && cp -fv /usr/local/libexec/cni/* $_
  cp -fv /usr/local/lib/systemd/system/*.service /etc/systemd/system/

  _logger info "4. Configure image acceleration"
  mkdir -p /etc/containerd
  [[ -f $CONTAINERD_CONF ]] && cp -fv $CONTAINERD_CONF $CONTAINERD_CONF.bak
  containerd config default > $CONTAINERD_CONF
  sed -i -e "/\[plugins.'io.containerd.cri.v1.images'.registry\]/,/\[/{s|config_path = ''|config_path = '$CONTAINERD_ACCELERATION_DIR'|}" $CONTAINERD_CONF

  # docker.hub image acceleration
  mkdir -p $CONTAINERD_ACCELERATION_DIR/docker.io && tee $_/hosts.toml <<-EOF
server = "https://docker.io"

[host."https://docker.1ms.run"]
  capabilities = ["pull", "resolve"]

[host."https://docker-0.unsee.tech"]
  capabilities = ["pull", "resolve"]

[host."https://docker.m.daocloud.io"]
  capabilities = ["pull", "resolve"]

[host."https://register.librax.org"]
  capabilities = ["pull", "resolve"]

[host."https://docker.hlmirror.com"]
  capabilities = ["pull", "resolve"]

[host."https://lispy.org"]
  capabilities = ["pull", "resolve"]
  
[host."https://docker.actima.top"]
  capabilities = ["pull", "resolve"]

[host."https://docker.xiaogenban1993.com"]
  capabilities = ["pull", "resolve"]

[host."https://func.ink"]
  capabilities = ["pull", "resolve"]
EOF

  # registry.k8s.io image acceleration
  mkdir -p $CONTAINERD_ACCELERATION_DIR/registry.k8s.io && tee $_/hosts.toml <<-EOF
server = "https://registry.k8s.io"

[host."https://k8s.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
EOF

  # docker.elastic.co image acceleration
  mkdir -p $CONTAINERD_ACCELERATION_DIR/docker.elastic.co && tee $_/hosts.toml <<-EOF
server = "https://docker.elastic.co"

[host."https://elastic.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
EOF

  # gcr.io image acceleration
  mkdir -p $CONTAINERD_ACCELERATION_DIR/gcr.io && tee $_/hosts.toml <<-EOF
server = "https://gcr.io"

[host."https://gcr.m.daocloud.io"]
  capabilities = ["pull", "resolve"]

[host."https://gcr.1ms.run"]
  capabilities = ["pull", "resolve"]
EOF

  # ghcr.io image acceleration
mkdir -p $CONTAINERD_ACCELERATION_DIR/ghcr.io && tee $_/hosts.toml <<-EOF
server = "https://ghcr.io"

[host."https://ghcr.m.daocloud.io"]
  capabilities = ["pull", "resolve"]

[host."https://ghcr.1ms.run"]
  capabilities = ["pull", "resolve"]
EOF

  # mcr.m.daocloud.io image acceleration
  mkdir -p $CONTAINERD_ACCELERATION_DIR/mcr.microsoft.com && tee $_/hosts.toml <<-EOF
server = "https://mcr.microsoft.com"

[host."https://mcr.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
EOF

  # nvcr.io image acceleration
  mkdir -p $CONTAINERD_ACCELERATION_DIR/nvcr.io && tee $_/hosts.toml <<-EOF
server = "https://nvcr.io"

[host."https://nvcr.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
EOF

  # quay.io image acceleration
  mkdir -p $CONTAINERD_ACCELERATION_DIR/quay.io && tee $_/hosts.toml <<-EOF
server = "https://quay.io"

[host."https://quay.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
EOF

  # registry.jujucharms.com image acceleration
  mkdir -p $CONTAINERD_ACCELERATION_DIR/registry.jujucharms.com && tee $_/hosts.toml <<-EOF
server = "https://registry.jujucharms.com"

[host."https://jujucharms.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
EOF

  # rocks.canonical.com image acceleration
  mkdir -p $CONTAINERD_ACCELERATION_DIR/rocks.canonical.com && tee $_/hosts.toml <<-EOF
server = "https://rocks.canonical.com"

[host."https://rocks-canonical.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
EOF

  if [[ -n "$CONTAINERD_PROXY_ENDPOINT" ]]; then
    _logger info "Config proxy endpoint"
    mkdir -p $(echo $CONTAINERD_PROXY_CONF | cut -d'/' -f -5)
    [[ -f $CONTAINERD_PROXY_CONF ]] && \cp -v $CONTAINERD_PROXY_CONF $CONTAINERD_PROXY_CONF.bak
    local no_proxy_subnet=(
      localhost,
      127.0.0.0/8,
      10.0.0.0/8,
      172.16.0.0/12,
      192.168.0.0/16,
      containerd,
      .svc,
      .cluster.local,
      .ewhisper.cn
    )

    tee $CONTAINERD_PROXY_CONF <<-EOF
[Service]
Environment="HTTP_PROXY=http://$CONTAINERD_PROXY_ENDPOINT"
Environment="HTTPS_PROXY=http://$CONTAINERD_PROXY_ENDPOINT"
Environment="NO_PROXY=${no_proxy_subnet[@]}"
# the parts to be added to No_proxy based on the environment:
#   <nodeCIDR>,<APIServerInternalURL>,<serviceNetworkCIDRs>,<etcdDiscoveryDomain>,<clusterNetworkCIDRs>,
#   <platformSpecific>,<REST_OF_CUSTOM_EXCEPTIONS>
EOF
    systemctl daemon-reload
  fi

  _logger info "4. Start related services"
  which git &>/dev/null || dnf install -qy git >/dev/null    # if buildkit git source be enabled
  # systemctl enable containerd stargz-snapshotter buildkit --now
  # systemctl status --no-pager containerd stargz-snapshotter buildkit
  systemctl enable containerd buildkit --now
  systemctl status --no-pager containerd buildkit

  _print_line split -
  _logger info "Containerd with Nerdctl has been successfully installed.
Summary:
  Version: please run ${blue}nerdctl info / nerdctl version${green} to show
  Config: $CONTAINERD_CONF
  Proxy config: $CONTAINERD_PROXY_CONF
  Proxy endpoint: $CONTAINERD_PROXY_ENDPOINT"
  echo -e "${yellow}      Nerdctl is fully compatible with Docker syntax. If you prefer Docker,"
  echo -e "${yellow}      just run ${blue}echo "alias docker='nerdctl'" >> ~/.bashrc && bash${reset}.\n"
}

function remove() {
  # check_args
  which nerdctl >/dev/null || { _logger error "Nerdctl is not installed on system." && exit 1; }

  _print_line title "Remove Containerd with Nerdctl"

  _logger info "1. Check and kill processes ..."
  for srv in buildkit stargz-snapshotter containerd; do
    systemctl is-active --quiet $srv && systemctl stop $srv || true && sleep 3
    while ps -ef | grep "$srv" | grep -v "pts" &>/dev/null; do
      echo -e "${yellow}$srv is stopping, if necessary, please manually kill: ${red}pkill -9 $srv${reset}"
      sleep 5
    done
  done

  _logger info "2. Delete related files"
  for i in "buildkit*" "containerd*" runc nerdctl; do rm -rfv /usr/local/bin/$i; done
  for i in containerd buildkit stargz-snapshotter; do rm -rfv /usr/local/lib/systemd/system/$i; done
  rm -rfv /etc/systemd/system/containerd.service.d/http-proxy.conf
  systemctl daemon-reload

  _logger info "3. Delete related usergroup"
  getent group docker && groupdel docker

  _print_line split -
  _logger info "Containerd with Nerdctl has been successfully removed.\n"
}


function main() {
  function _help() {
    printf "Invalid option ${@:1}\n"
    printf "${green}Usage: ${reset}\n"
    printf "    ${gray}bash ${blue}$0 ${green}install ${gray}2.0.4 proxy_endpoint${reset}\n"
    printf "    ${gray}bash ${blue}$0 ${green}remove${reset}\n\n"
  }

  case $1 in
    install)
      install ${@:1}
      ;;
    remove)
      remove
      ;;
    *)
      _help ${@:1} && exit 1 ;;
  esac
}

main ${@:1}
