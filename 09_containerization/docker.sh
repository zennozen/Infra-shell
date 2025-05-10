#!/usr/bin/env bash
# https://download.docker.com/linux/
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
  DOCKER_VER DOCKER_URL DOCKER_CONF DOCKER_PROXY_ENDPOINT DOCKER_PROXY_CONF
' ERR

# define golabal variables
DOCKER_VER="$2"
DOCKER_URL_PREFIX="https://download.docker.com/linux/static/stable/x86_64"
DOCKER_CONF="/etc/docker/daemon.json"
DOCKER_PROXY_ENDPOINT="$3"
DOCKER_PROXY_CONF="/etc/systemd/system/docker.service.d/http-proxy.conf"

#######################################
## Main Business Logic Begins
#######################################

function get_docker_ver() {
  # check_args
  ! which docker 2>/dev/null || { _logger error "Docker already install on system." && exit 1; }

  if [[ -z $DOCKER_VER ]]; then
    _logger warn "User not defined version number, auto-get latest official version."
    DOCKER_VER=$(curl -sSL $DOCKER_URL_PREFIX 2>/dev/null | grep -oP 'docker-rootless-extras-\K\d+\.\d+\.\d+(?=\.tgz)' | sort -V | tail -n 1)
  fi
  if [[ -z $DOCKER_VER ]]; then
    _logger warn "Failed to get latest version number, default to 28.0.0."
    DOCKER_VER="28.0.0"
  fi
}

function rpm_install() {
  _print_line title "Install Docker via yum repo"

  get_docker_ver

  _logger info "1. Update system config"
  _logger info "1.1 Enable the netfilter module to support routing forwarding"
  echo "br_netfilter" | tee /etc/modules-load.d/br_netfilter.conf
  systemctl restart systemd-modules-load
  lsmod | grep "br_netfilter"

  _logger info "1.2 Enable kernel routing forwarding, bridge filtering, and prefer to avoid using swap space, etc."
  tee /etc/sysctl.d/container.conf <<-EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
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
  
  _logger info "2. Add official yum repo"
  dnf config-manager --add-repo=https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
  dnf makecache

  _logger info "3. Install docker-ce"
  # containerd.io docker-ce-cli  docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
  dnf install -y docker-ce-$DOCKER_VER
}

function tar_install() {
  _print_line title "Install Docker via tar.gz ${red}Not recommended, peripheral plugins are not installed yet"

  get_docker_ver
  local DOCKER_URL="${DOCKER_URL_PREFIX}/docker-${DOCKER_VER}.tgz"

  _logger info "1. Update system config"
  _logger info "1.1 Enable the netfilter module to support routing forwarding"
  echo "br_netfilter" | tee /etc/modules-load.d/br_netfilter.conf
  systemctl restart systemd-modules-load
  lsmod | grep "br_netfilter"

  _logger info "1.2 Enable kernel routing forwarding, bridge filtering, and prefer to avoid using swap space, etc."
  tee /etc/sysctl.d/container.conf <<-EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
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

  _logger info "2. Download and extract docker binary .tgz package"
  cd /usr/local/src
  if [[ -f docker-${DOCKER_VER}.tgz ]]; then
    _logger warn "docker-${DOCKER_VER}.tgz is already exists in /usr/local/src/, will use."
  else
    wget --tries=5 --timeout=60 -c $DOCKER_URL
  fi
  tar -xzf docker-${DOCKER_VER}.tgz -C /usr/local/
    
  _logger info "3. Create necessary symbolic links and user groups"
  ln -s /usr/local/docker/* /usr/bin/    # Create a symbolic link (key)
  #groupadd docker 2> /dev/null || true
  #usermod -aG docker your_username  # Add users who want to manage Docker to this group

  _logger info "4. Create the service unit file, manage using systemctl"
  tee /usr/lib/systemd/system/docker.service <<-EOF
[Unit]
Description=Docker Application Container Engine
Documentation=http://docs.docker.com
After=network.target

[Service]
Type=notify
ExecStart=/usr/bin/dockerd -H tcp://0.0.0.0:2375 -H unix:///var/run/docker.sock
ExecReload=/bin/kill -s HUP $MAINPID
LimitNOFILE=infinity
LimitNPROC=infinity
TimeoutStartSec=0
Delegate=yes
KillMode=process
Restart=on-failure
StartLimitBurst=4
StartLimitInterval=20s

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

function update_config_and_start() {
  _logger info "5. Configure image acceleration"
  mkdir -p $(echo $DOCKER_CONF | cut -d'/' -f-3)
  [[ -f $DOCKER_CONF ]] && \cp -v $DOCKER_CONF $DOCKER_CONF.bak
  tee $DOCKER_CONF <<EOF
{
    "registry-mirrors": [
        "https://docker.1ms.run",
        "https://docker-0.unsee.tech",
        "https://docker.m.daocloud.io",
        "https://register.librax.org",
        "https://docker.hlmirror.com",
        "https://lispy.org",
        "https://docker.actima.top",
        "https://docker.xiaogenban1993.com"
    ],
    "insecure-registries": [
        "docker.rockylinux.cn"
    ],
    "exec-opts": ["native.cgroupdriver=systemd"],
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m",
        "max-file": "10"
    },
    "storage-driver": "overlay2",
    "live-restore": true,
    "default-shm-size": "128M",
    "max-concurrent-downloads": 10,
    "max-concurrent-uploads": 10,
    "debug": false
}
EOF

  if [[ -n "$DOCKER_PROXY_ENDPOINT" ]]; then
    _logger info "Config proxy endpoint"
    mkdir -p $(echo $DOCKER_PROXY_CONF | cut -d'/' -f-5)
    [[ -f $DOCKER_PROXY_CONF ]] && cp -fv $DOCKER_PROXY_CONF $DOCKER_PROXY_CONF.bak
    tee $DOCKER_PROXY_CONF <<-EOF
[Service]
Environment="HTTP_PROXY=http://$DOCKER_PROXY_ENDPOINT"
Environment="HTTPS_PROXY=http://$DOCKER_PROXY_ENDPOINT"
Environment="NO_PROXY=localhost,127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,containerd"
EOF
    systemctl daemon-reload
  fi

  _logger info "Start docker service"
  systemctl enable --now docker
  systemctl --no-pager -l status docker
  ps -ef | grep [d]ocker

  _logger info "6. Enable docker command auto-completion"
  dnf install -y bash-completion
  echo "source <(docker completion bash)" >> ~/.bashrc && source <(docker completion bash)

  _print_line split -
  _logger info "Docker has been successfully installed.
Summary:
  Version: please run ${blue}docker info / docker version${green} to show
  Config: $DOCKER_CONF
  Proxy config: $DOCKER_PROXY_CONF
  Proxy endpoint: $DOCKER_PROXY_ENDPOINT"
}


function remove() {
  # check_args
  which docker >/dev/null || { _logger error "Docker is not installed on system." && exit 1; }

  _print_line title "Remove Docker"
    
  _logger info "1. Check and kill processes ..."
  systemctl is-active --quiet docker && systemctl stop docker || true && sleep 3
  while ps -ef | grep "[d]ockerd" | grep -v "pts" &>/dev/null; do
    echo -e "${yellow}Dockerd is stopping, if necessary, please manually kill: ${red}pkill -9 dockerd${reset}"
    sleep 5
  done

  _logger info "2. Delete related files"
  ! dnf list --installed | grep docker-ce || dnf remove -y docker-ce
  find /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin -name docker | xargs rm -rfv
  rm -rfv /var/lib/docker /var/lib/containerd /var/run/docker.sock
  rm -rfv /usr/lib/systemd/system/docker.service /etc/systemd/system/docker.service.d
  systemctl daemon-reload

  _logger info "3. Delete related usergroup"
  getent group docker && groupdel docker

  _print_line split -
  _logger info "Docker has been successfully removed.\n"
}


function main() {
  function _help() {
    printf "Invalid option ${@:1}\n"
    printf "${green}Usage: ${reset}\n"
    printf "    ${gray}bash ${blue}$0 ${green}rpm_install ${gray}28.0.0 proxy_endpoint${reset}\n"
    printf "    ${gray}bash ${blue}$0 ${green}tar_install${red}(Not recommended) ${gray}28.0.0 proxy_endpoint${reset}\n"
    printf "    ${gray}bash ${blue}$0 ${green}remove${reset}\n\n"
  }

  case $1 in
    rpm_install)
      shift
      rpm_install ${@:1}
      update_config_and_start
      ;;
    tar_install)
      shift
      tar_install ${@:1}
      update_config_and_start
      ;;
    remove)
      remove
      ;;
    *)
      _help ${@:1} && exit 1 ;;
  esac
}

main ${@:1}
