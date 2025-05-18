#!/usr/bin/env bash
# https://packages.gitlab.com/gitlab/gitlab-ce/install#bash-rpm
set -o errexit

script_path="$(dirname ${BASH_SOURCE[0]})"
abs_script_path="$(realpath "${BASH_SOURCE[0]}")"
workdir="$(dirname "$abs_script_path")"

# import some define
source "$script_path/../00_utils/_print.sh"
source "$script_path/../00_utils/_trap.sh"
source "$script_path/../00_utils/_logger.sh"
source "$script_path/../00_utils/_remote.sh"

# capture errors and print environment variables
trap '_trap_print_env \
  SRV_IP INIT_NODE_IP K8S_VER CALICO_VER NERDCTL_VER POD_SUBNET INIT_CMD UI_BOARD_TY \
  DASHBOARD_TOKEN ip2host join_cmds
' ERR

# define golabal variables
SRV_IP="$(ip -4 addr show | grep inet | grep -v 127.0.0.1 | awk 'NR==1 {print $2}' | cut -d'/' -f1)"
INIT_NODE_IP=""
GITHUB_PROXY="https://ghproxy.net"
K8S_V="${3:-"1.29"}"
NERDCTL_VER=""
SVC_SUBNET="10.10.0.0/16"
POD_SUBNET="10.244.0.0/16"
INIT_CMD=""
UI_BOARD_TY=""
DASHBOARD_TOKEN=""
declare -A ip2host
declare -A join_cmds
tag="k8s_cluster"
dep_script="containerd_with_nerdctl.sh"
offline_pkg_path="/usr/local/src/k8s_offline_$K8S_V"
# definition of key version compatibility
#   refer: https://kubernetes.io/zh-cn/releases/patch-releases/
case $K8S_V in
  1.24)
    K8S_VER="1.24.17"
    ;;
  1.25)
    K8S_VER="1.25.16"
    ;;
  1.26)
    K8S_VER="1.26.15"
    ;;
  1.27)
    K8S_VER="1.27.16"
    ;;
  1.28)
    K8S_VER="1.28.15"
    ;;
  1.29)
    K8S_VER="1.29.14"
    ;;
  1.30)
    K8S_VER="1.30.13"
    ;;
  1.31)
    K8S_VER="1.31.9"
    ;;
  1.32)
    K8S_VER="1.32.5"
    ;;
  1.33)
    K8S_VER="1.33.1"
    ;;
  *)
    _logger error "Version number is invalid or unstable, not supported temporarily."
    exit 1
esac

case $K8S_V in
  1.24|1.25|1.26|1.27|1.28|1.29|1.30)
    NERDCTL_VER="1.7.7"
    ;;
  1.31|1.32)
    NERDCTL_VER="2.0.5"
    ;;
esac

case $K8S_V in
  1.24|1.25|1.26)
    CALICO_VER="3.26.1"
    TIGERA_VER="1.30.4"
    ;;
  1.27)
    CALICO_VER="3.27.5"
    TIGERA_VER="1.32.12"
    ;;
  1.28)
    CALICO_VER="3.28.4"
    TIGERA_VER="1.34.10"
    ;;
  1.29|1.30)
    CALICO_VER="3.29.3"
    TIGERA_VER="1.36.7"
    ;;
  1.31|1.32|1.33)
    CALICO_VER="3.30.0"
    TIGERA_VER="1.38.0"
    ;;
esac

####################################### Main Business Logic Begins ####################################

# Provide an override entry for environment variables for remote execution
source /tmp/${tag}_var &>/dev/null || true

#############################################################################
## Function: plan_nodes
## Overview: The function for planning k8s nodes and configuring passwordless.
## Description:
##   Planning k8s nodes and configuring SSH passwordless, adapted for both 
##   cluster and node scenarios.
##
## Parameters:
##   - $1: cluster/node
##
## Returns:
##   -  0: Success (... successfully)
##   - !0: Failure (...)
##
## Example:
##   SRV_IP="$(ip -4 addr show | grep inet | grep -v 127.0.0.1 | awk 'NR==1 {print $2}' | cut -d'/' -f1)"
##   INIT_NODE_IP=""
##   tag="k8s_cluster"
##   offline_pkg_path="/usr/local/src/k8s_offline_$K8S_V"
##
##   source /tmp/${tag}_var &>/dev/null || true
##
##   case "$1-$2" in
##     dp-cluster|deploy-cluster)
##       plan_nodes $2
##       ... ;;
##     dp-node|deploy-node)
##       plan_nodes $2
##       ... ;;
#############################################################################
function plan_nodes() {
  local scene="$1"

  _print_line title "1. Planning k8s nodes, configuring passwordless and prepare some resources"

  case $scene in
    cluster)
      # obtain the IP address of the initialization node
      INIT_NODE_IP="$SRV_IP"

      # init operation
      _logger info "1.1 Before init, get the necessary resources."
      cd $(dirname $offline_pkg_path)
      while [[ ! -f k8s_offline_${K8S_V}.tar.gz ]]; do
        read -rp "No $(dirname $offline_pkg_path)/k8s_offline_${K8S_V}.tar.gz found. Upload manually ? (y/n) [Enter 'y' by default]: " answer
        
        if ! which rz &>/dev/null; then
          _logger info "Try get and install rpm pkg: lrzsz"
          if ! _remote_get_resource rpm lrzsz $offline_pkg_path/rpm/lrzsz -q &>/dev/null; then
            rm -rf $offline_pkg_path
            _logger error "lrzsz install failed, please manually upload k8s_offline_${K8S_V}.tar.gz to /usr/local/src."
            exit 1
          fi
        fi

        answer=${answer:-y}
        if [[ "$answer" =~ ^[Yy]$ ]]; then
          which rz >/dev/null || dnf install -qy lrzsz
          rz -y
        else
          _logger warn "User canceled manually."
          break
        fi
      done

      if [[ -f k8s_offline_${K8S_V}.tar.gz ]]; then
        _logger info "Detected existing $(dirname $offline_pkg_path)/k8s_offline_${K8S_V}.tar.gz locally, will extract and use ..."
        tar -zxf k8s_offline_${K8S_V}.tar.gz
      else
        _logger warn "Offline resource fetch failed, will handle each case separately later."
      fi

      # plan cluster nodes, configure SSH passwordless, update hostnames
      _remote_ssh_passfree config
      ;;
    node)
      if [[ -z $INIT_NODE_IP ]]; then
        while [[ -z $INIT_NODE_IP ]]; do
          read -rp "The cluster initialization node IP is empty, please enter it manually: " INIT_NODE_IP
        done

        _logger info "1.2 Install the necessary tools."
        mkdir -p $offline_pkg_path/rpm
        scp -r root@$INIT_NODE_IP:$offline_pkg_path/rpm/sshpass $offline_pkg_path/rpm/ 2>/dev/null || {
          _logger warn "No available offline resources on the remote node $INIT_NODE_IP."
        }

        # update plan cluster nodes
        _remote_ssh_passfree config
      fi
      ;;
  esac

  # get ips and hosts save to ${!ip2host[@]}
  _remote_get_ip2host
}


#############################################################################
## Function: config_sys
## Overview: K8s pre-install system config function.
## Description:
##   Configure clock source and sync immediately, enable IPVS modules, 
##   optimize route forwarding, bridge filtering, and disable swap, 
##   among other kernel parameters.
##
## Parameters:
##   - offline_pkg_path: $offline_pkg_path
##
## Returns:
##   -  0: Success (... successfully)
##   - !0: Failure (...)
##
## Example:
##   offline_pkg_path="/usr/local/src/k8s_offline_$K8S_V"
##   config_sys
#############################################################################
function config_sys() {
  _print_line title "2. System configuration before install (current machine: $(hostname))"

  # config chronyd
  _logger info "2.1 Configure clock source and immediately synchronize time"
  _logger info "Check and install chrony"
  which chronyc || dnf install -y chronyd

  _logger info "Backup and update chrony config"
  local CHRONY_CONF="/etc/chrony.conf"
  [[ -f $CHRONY_CONF ]] && cp -fv $CHRONY_CONF ${CHRONY_CONF}_$(date +'%Y%m%d-%H%M').bak
  tee $CHRONY_CONF <<-EOF
server ntp.aliyun.com iburst
server cn.pool.ntp.org iburst
server ntp.ntsc.ac.cn iburst
local stratum 10
makestep 1.0 3
rtcsync
driftfile /var/lib/chrony/drift
logdir /var/log/chrony
EOF

  _logger info "Start/Restart chronyd service"
  systemctl restart chronyd && systemctl enable $_ && systemctl status --no-pager $_

  # immediately sync time
  _logger info "Immediately jump to the current time and force correction of historical errors and verifying sync status"
  chronyc -a makestep
  chronyc sources -v

  # disable selinux
  _logger info "2.2 Disable selinux"
  sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
  grubby --update-kernel ALL --args selinux=0
  setenforce 0  && sestatus

  # disable swap
  _logger info "2.3 Off swap"
  sed -ri 's/.*swap.*/#&/' /etc/fstab
  swapoff -a && free -h

  # enable ipvs-related modules
  _logger info "2.4 Enable IPVS-related modules"
  for s in ipset ipvsadm; do _remote_get_resource rpm $s $offline_pkg_path/rpm/$s -q; done
  tee /etc/modules-load.d/ipvs.conf <<-EOF
# Load IPVS at boot
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
EOF
  systemctl restart systemd-modules-load
  lsmod | grep -E "ip_vs|nf_conntrack"

  # enable netfilter modules
  _logger info "2.5 Enable the netfilter module to support routing forwarding"
  tee /etc/modules-load.d/br_netfilter.conf <<-EOF
overlay
br_netfilter
EOF
  systemctl restart systemd-modules-load
  lsmod | grep -E "br_netfilter|overlay"

  # enable related kernel parameters
  _logger info "2.6 Enable kernel parameters such as routing forwarding, bridge filtering, and a preference to avoid using swap space"
  tee /etc/sysctl.d/k8s.conf <<-EOF
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
  sysctl -p /etc/sysctl.d/k8s.conf
}


#############################################################################
## Function: install_containerd
## Overview: Function to install containerd and nerdctl command-line tool.
## Description:
##   Call 'containerd_with_nerdctl.sh' to install the containerd service and
##   nerdctl command-line tool by installing the full version of nerdctl, and
##   configure command completion for both.
##
## Parameters:
##   - $1: $NERDCTL_VER
##
## Returns:
##   -  0: Success (... successfully)
##   - !0: Failure (...)
##
## Example:
##   NERDCTL_VER="1.7.7"  # containerd v1.7.22, default sandbox = pause:3.8
##   dep_script="containerd_with_nerdctl.sh"
##   install_containerd
#############################################################################
function install_containerd() {
  _remote_get_resource rpm bash-completion $offline_pkg_path/rpm/bash-completion -q

  if which nerdctl 2>/dev/null && which containerd 2>/dev/null; then
    _logger warn "containerd_with_nerdctl already install on system."
  else
    # get nerdctl full pkg
    local nerdctl_ver="${1:-$NERDCTL_VER}"
    local nerdctl_url="$GITHUB_PROXY/https://github.com/containerd/nerdctl/releases/download/v${nerdctl_ver}/nerdctl-full-${nerdctl_ver}-linux-amd64.tar.gz"
    _remote_get_resource download containerd $offline_pkg_path/download/containerd $nerdctl_url
    cp -v $offline_pkg_path/download/containerd/* /usr/local/src
    _remote_get_resource rpm git $offline_pkg_path/rpm/git -q

    # generation containerd_with_nerdctl.sh
    cd $workdir
    [[ -f $dep_script ]] || { cd .. && bash build gr $dep_script && cd $workdir; }
    [[ -f $dep_script ]] || { _logger error "Missing script $dep_script in current directory. Please check." && exit 1; }
    bash $dep_script install $nerdctl_ver || { _logger error "Script $dep_script failed, exit code $?" && exit 1; }
    rm -rf /usr/local/src/nerdctl-full-*.tar.gz
  fi

  # set alias docker
  _logger info "3.x Set the alias of nerdctl to docker"
  which docker 2>/dev/null || echo "alias docker='nerdctl'" >> ~/.bashrc
}


#############################################################################
## Function: install_kubeX
## Overview: Function to install Kubeadm、kubectl、kubelet.
## Description:
##  Configure k8s repo and install Kubeadm, kubectl, kubelet based on the
##  provided version number. Enable and start kubelet, disable firewall, 
##  and set up command autocompletion.
##
## Parameters:
##
## Returns:
##   -  0: Success (... successfully)
##   - !0: Failure (...)
##
## Example:
##   K8S_V="${3:-"1.29"}"
##   offline_pkg_path="/usr/local/src/k8s_offline_$K8S_V"
##   install_kubeX
#############################################################################
function install_kubeX() {
  _print_line title "4. Install Kubeadm、kubectl、kubelet (current machine: $(hostname))"

  _logger info "4.1 Install socat to enable port forwarding and container communication within the Kubernetes cluster"
  _remote_get_resource rpm socat $offline_pkg_path/rpm/socat -q

  _logger info "4.2 Add the k8s YUM mirror source"
  tee /etc/yum.repos.d/kubernetes.repo <<-EOF
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes-new/core/stable/v$K8S_V/rpm/
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes-new/core/stable/v$K8S_V/rpm/repodata/repomd.xml.key
EOF

  _logger info "4.3 Install kubeadm-$K8S_VER (include kubectl and kubelet)"
  _remote_get_resource rpm kubeadm-$K8S_VER $offline_pkg_path/rpm/kubeadm-$K8S_VER -q
  # adapt the kubeadm package to be independent of the kubectl and kubelet packages
  rpm -q "kubectl" || _remote_get_resource rpm kubectl-$K8S_VER $offline_pkg_path/rpm/kubectl-$K8S_VER -q
  rpm -q "kubelet" || _remote_get_resource rpm kubelet-$K8S_VER $offline_pkg_path/rpm/kubelet-$K8S_VER -q

  _logger info "4.4 Set kubelet to start on boot, initiated by kubeadm init"
  systemctl enable kubelet --now && systemctl status --no-pager kubelet

  _logger info "4.5 Disable the firewall"
  if systemctl status firewalld | grep "active (running)" &>/dev/null; then
    systemctl stop firewalld && systemctl disable $_ && systemctl status --no-pager $_ || true
  else
    _logger info "The firewall is already disabled on the current system, no action needed."
  fi

  _logger info "4.6 Enable kubeadm, kubectl, crictl, ctr command auto-completion"
  _remote_get_resource rpm bash-completion $offline_pkg_path/rpm/bash-completion -q
  echo "source <(kubeadm completion bash)" >> ~/.bashrc && source <(kubeadm completion bash)
  echo "source <(kubectl completion bash)" >> ~/.bashrc && source <(kubectl completion bash)
  echo "source <(crictl completion bash)" >> ~/.bashrc && source <(crictl completion bash)
}


#############################################################################
## Function: _update_containerd_pause_img
## Overview: Function to update containerd pause version for k8s.
## Description:
##  Modify the pause image version in containerd based on the corresponding 
##  pause image version number in the k8s version.
##
## Parameters:
##   $1: repo_prefix (such as $INIT_NODE_IP:5000, 
##       or registry.cn-hangzhou.aliyuncs.com/google_containers)
##
## Returns:
##   -  0: Success (...)
##   - !0: Failure (...)
##
## Example:
##   K8S_V="${3:-"1.29"}"
##   INIT_NODE_IP="xxx"
##  # _update_containerd_pause_img registry.cn-hangzhou.aliyuncs.com/google_containers  # public
##  _update_containerd_pause_img $INIT_NODE_IP:5000   # private
#############################################################################
function _update_containerd_pause_img() {
  local repo_prefix="$1"
  local pause_img_ver="$(kubeadm config images list --kubernetes-version v$K8S_VER | awk -F':' '/pause/ {print $2}')"
  local containerd_conf="/etc/containerd/config.toml"
  local containerd_v=$(containerd -v | awk -F' |v' '{print $4}' | awk -F'.' '{print $1}')

  _logger info "5.3 Enable SystemdCgroup and change sandbox_image to pause:$pause_img_ver, required by k8s"
  # update cgroup driver
  sed -i -e '/SystemdCgroup/s/false/true/g' $containerd_conf
  # update sandbox image
  case $containerd_v in
    1)
      sed -i -E "s|(sandbox_image = ).*|\1\"$repo_prefix/pause:$pause_img_ver\"|" $containerd_conf
      ;;
    2)
      sed -i -E "s|(sandbox = ).*|\1\"$repo_prefix/pause:$pause_img_ver\"|" $containerd_conf
      ;;
  esac

  systemctl restart containerd
  while ! systemctl is-active containerd &>/dev/null; do
    _logger info "Restart containerd service starting ..."
    sleep 1
  done
}


#############################################################################
## Function: config_private_registry
## Overview: Function to configure and enable a private registry.
## Description:
##  Start a registry container and update containerd's private registry 
##  settings for both pulling and pushing images, including modifying 
##  '/etc/containerd/config.toml' for k8s and crictl, and adding 
##  '/etc/containerd/certs.d/$INIT_NODE_IP:5000/hosts.toml' for nerdctl.
##
## Parameters:
##
## Returns:
##   -  0: Success (...)
##   - !0: Failure (...)
##
## Example:
##   SRV_IP="xxx"
##   INIT_NODE_IP="xxx"
##   config_private_registry
#############################################################################
function config_private_registry() {
  local containerd_conf="/etc/containerd/config.toml"

  _print_line title "5. Set up a simple private repository for the cluster (current machine: $(hostname))"

  if [[ $SRV_IP == $INIT_NODE_IP ]]; then
    _logger info "5.1 Detected that this is the initialization node, run a register2 container."
    _remote_get_resource image registry $offline_pkg_path/image/registry default docker.io/library/registry:2
    
    # start registry container on port 5000
    nerdctl run -d -p 5000:5000 --restart=always --name registry docker.io/library/registry:2
    while ! nerdctl ps | grep registry &>/dev/null; do
      _logger info "The register2 container starting ..."
      sleep 1
    done
  else
    _logger warn "5.2 Detected non-initialization node, skipping run a register2 container."
  fi

  # update containerd pause image to private repo
  # _update_containerd_pause_img registry.cn-hangzhou.aliyuncs.com/google_containers  # public
  _update_containerd_pause_img $INIT_NODE_IP:5000   # private

  # update private registry config in config.toml: registry.mirrors, registry.configs, and restart service
  _logger info "5.4 Update private registry config in config.toml to support HTTP for containerd CRI interactions (crictl, k8s)"
  local containerd_conf="/etc/containerd/config.toml"

  sed -i "/\[plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors\]/a \
    \        [plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors.\"${INIT_NODE_IP}:5000\"\] \
    \n\          endpoint = \[\"http://${INIT_NODE_IP}:5000\"\]" "$containerd_conf"

  sed -i "/\[plugins.\"io.containerd.grpc.v1.cri\".registry.configs\]/a \
    \        [plugins.\"io.containerd.grpc.v1.cri\".registry.configs.\"${INIT_NODE_IP}:5000\".tls] \
    \n\          insecure_skip_verify = true" "$containerd_conf"    

  systemctl restart containerd
  while ! systemctl is-active containerd &>/dev/null; do
    _logger info "Restart containerd service starting ..."
    sleep 1
  done

  # update private registry config in certs.d: registry.mirrors, actions: pull/resolve,push, no need restart service
  _logger info "5.5 Update private registry config in certs.d to support HTTP (for containerd underlying interface, such as nerdctl)"
  mkdir -p /etc/containerd/certs.d/$INIT_NODE_IP:5000 && tee $_/hosts.toml <<-EOF
server = "http://$INIT_NODE_IP:5000"

[host."http://$INIT_NODE_IP:5000"]
  capabilities = ["pull", "resolve", "push"]
EOF
  sleep 5  # allow containerd to reload the updated configurations from /etc/containerd/certs.d
}


#############################################################################
## Function: load_and_push_image
## Overview: Function to load or pull images and push to private registry.
## Description:
##  Function to get k8s and calico image versions based on k8s version, 
##  define dashboard plugin image versions, try to load offline image packages,
##  or pull online with acceleration if failed, then retag and push to private
##  registry.
##
## Parameters:
##
## Returns:
##   -  0: Success (...)
##   - !0: Failure (...)
##
## Example:
##   INIT_NODE_IP="xxx"
##   K8S_VER="xxx"
##   CALICO_VER="xxx"
##   TIGERA_VER="xxx"
##   load_and_push_image
#############################################################################
function load_and_push_image() {
  _print_line title "6. Pre-pull all required images, and push them to the private registry"

  # define images tag
  # Use readarray to convert the output of 'kubeadm config images list' into an array.
  # The '-t' option strips the trailing newline characters from each array element.
  # The '< <(command)' syntax is process substitution in Bash, which feeds the output of the command as a file input.
  readarray -t k8s_cluster_imgs < <(
      kubeadm config images list --kubernetes-version v$K8S_VER | \
      sed -E "s#(registry.k8s.io|registry.k8s.io/coredns)#registry.cn-hangzhou.aliyuncs.com/google_containers#g"
  )
  # k8s_cluster_imgs=(
  #     "registry.cn-hangzhou.aliyuncs.com/google_containers/kube-apiserver:v$K8S_VER"
  #     "registry.cn-hangzhou.aliyuncs.com/google_containers/kube-scheduler:v$K8S_VER"
  #     "registry.cn-hangzhou.aliyuncs.com/google_containers/kube-controller-manager:v$K8S_VER"
  #     "registry.cn-hangzhou.aliyuncs.com/google_containers/kube-proxy:v$K8S_VER"
  #     "registry.cn-hangzhou.aliyuncs.com/google_containers/pause:3.x"
  #     "registry.cn-hangzhou.aliyuncs.com/google_containers/etcd:3.5.2x-0"
  #     "registry.cn-hangzhou.aliyuncs.com/google_containers/coredns:v1.1x.0"
  # )
  calico_imgs=(
    "docker.io/calico/apiserver:v$CALICO_VER"
    "docker.io/calico/kube-controllers:v$CALICO_VER"
    "docker.io/calico/node:v$CALICO_VER"
    "docker.io/calico/node-driver-registrar:v$CALICO_VER"
    "docker.io/calico/cni:v$CALICO_VER"
    "docker.io/calico/csi:v$CALICO_VER"
    "docker.io/calico/pod2daemon-flexvol:v$CALICO_VER"
    "docker.io/calico/typha:v$CALICO_VER"
    "quay.io/tigera/operator:v$TIGERA_VER"
  )
  dashboard_imgs=(
    "docker.io/kubernetesui/dashboard-auth:1.2.4"
    "docker.io/kubernetesui/dashboard-api:1.12.0"
    "docker.io/kubernetesui/dashboard-web:1.6.2"
    "docker.io/kubernetesui/dashboard-metrics-scraper:1.2.2"
    "docker.io/library/kong:3.8"
  )
  kuboard_imgs=(
    "swr.cn-east-2.myhuaweicloud.com/kuboard/kuboard:v3"
    "swr.cn-east-2.myhuaweicloud.com/kuboard/etcd-host:3.4.16-2"
    "swr.cn-east-2.myhuaweicloud.com/kuboard-dependency/metrics-server:v0.6.2"
    "swr.cn-east-2.myhuaweicloud.com/kuboard-dependency/metrics-scraper:v1.0.8"
  )

  # get images
  _logger info "6.1 Pre-pull/load all required images."
  for i in k8s_cluster calico dashboard kuboard; do
    _logger info "Start loading $i related images ..."
    local imgs_array_name="${i}_imgs"
    declare -n imgs_ref="$imgs_array_name"
    
    printf "[$i]: %s\n" "${imgs_ref[@]}"
    _remote_get_resource image $i $offline_pkg_path/image/$i k8s.io "${imgs_ref[@]}"
  done

  # retag and push
  _logger info "6.2 Retag and push them to the private registry."
  imgs_array=$(nerdctl -n k8s.io images --names | grep -E 'docker.io|quay.io|aliyuncs.com|myhuaweicloud.com' | awk '{print $1}')
  for old_tag in ${imgs_array[@]}; do
    new_tag=$(echo $old_tag | sed -E "s#(docker.io|docker.io/library|quay.io|registry.cn-hangzhou.aliyuncs.com/google_containers|swr.cn-east-2.myhuaweicloud.com)#$INIT_NODE_IP:5000#g")
    echo "retag and push: $old_tag $new_tag"
    nerdctl -n k8s.io tag $old_tag $new_tag
    for i in {1..3}; do
      nerdctl -n k8s.io push $new_tag && break || sleep 1
    done || { _logger error "After three attempts, the push of image $new_tag still failed." && exit 1; }
  done

  # remove dangling images
  _logger info "6.3 Remove dangling and other residual images."
  nerdctl -n k8s.io images --names | grep -v "$INIT_NODE_IP:5000" | awk 'NR>1{print $1}' | xargs -r nerdctl -n k8s.io rmi
  nerdctl image prune -a -f
}


#############################################################################
## Function: _chk_pod
## Overview: Generic Pod running check function.
## Description:
##  Loop every 5 seconds to check specified namespace's Pods until all are
##  in running state.
##
## Parameters:
##   - $1: namespace
##
## Returns:
##   -  0: Success (all pod is running in $1 namespace)
##   - !0: Failure (...)
##
## Example:
##   _chk_pod kube-system
##   _chk_pod calico-system
#############################################################################
function _chk_pod() {
  local ns="$1"
  while true; do
    local total_pods=$(kubectl get pod -n $ns | awk 'NR > 1' | wc -l)
    local running_pods=$(kubectl get pod -n $ns | grep Running | wc -l)

    if [[ $running_pods -gt 0 && $running_pods -eq $total_pods ]]; then
      _logger info "Pods in $ns are normal, and node network communication is normal."
      kubectl get pod -n $ns -o wide
      break
    else
      echo
      _logger warn "Pods in $ns are not healthy, waiting for them to run normally."
      kubectl get pod -n $ns -o wide
      sleep 5
    fi
  done
}


#############################################################################
## Function: init_cluster
## Overview: Function to quickly init a single-node cluster using kubeadm.
## Description:
##  Generate kubeadm init command based on prior parameters, execute init.
##  If errors occur, reset and retry with '-v=5' for detailed error output.
##  After successful init, configure '.kube/config' for kubectl to immediately
##  connect and manage the cluster.
##
## Parameters:
##
## Returns:
##   -  0: Success (init a single master node cluster successfully)
##   - !0: Failure (...)
##
## Example:
##   K8S_VER="xxx"
##   INIT_NODE_IP="xxx"
##   CP_ENDPOINT="xxx"
##   INIT_CMD=""
##   SVC_SUBNET="10.10.0.0/16"
##   POD_SUBNET="10.244.0.0/16"
##   init_cluster
#############################################################################
function init_cluster() {
  _print_line title "7. Init cluster (current machine: $(hostname))"

  # define init command
  _logger info "7.1 Define init command"
  if [[ -z $CP_ENDPOINT ]]; then
    _logger info "Specify a shared endpoint for all control-plane nodes - as a unified cluster entry point?"
    printf "If yes, please enter ${red} <your_vip/your_domain>:<port>, such as: k8s.example.com:6443 ${reset}"
    read -rp "[Enter 'n' by default]: " CP_ENDPOINT
  fi
  [[ -n $CP_ENDPOINT ]] || CP_ENDPOINT="${INIT_NODE_IP}:6443"

  INIT_CMD="kubeadm init \
    --kubernetes-version=v${K8S_VER} \
    --apiserver-advertise-address=${INIT_NODE_IP} \
    --control-plane-endpoint=${CP_ENDPOINT} \
    --image-repository=$INIT_NODE_IP:5000 \
    --service-cidr=$SVC_SUBNET \
    --pod-network-cidr=${POD_SUBNET} \
    --upload-certs
  "
  INIT_CMD=$(echo "$INIT_CMD" | awk '{$1=$1};1')  # reformat the field to remove extra spaces and tabs

  printf "\n$INIT_CMD\n\n"
  read -rp "Will initialize cluster. Confirm? (y/n) [Enter 'y' by default]: " answer
  answer=${answer:-y}
  [[ $answer =~ ^[Yy]$ ]] || { _logger error "User canceled initializing the cluster." && exit 1; }

  _logger info "7.2 Start init"
  if ! $INIT_CMD; then
    # reset and init again with -v=5
    _logger error "First init failed, starting reset and cleanup ..."
    _print_line split -
    reset
    _logger info "Enabling detailed log output, retrying init ..."
    _print_line split -
    $INIT_CMD -v=5
  fi

  # config $HOME/.kube/config
  _logger info "7.3 Init complete, configuring environment"
  local manage_conf="$HOME/.kube/config"
  mkdir -p $(dirname $manage_conf)
  [[ ! -f $manage_conf ]] || cp -v $manage_conf $manage_conf_$(date +'%Y%m%d-%H%M').bak
  cp -fv /etc/kubernetes/admin.conf $manage_conf
  chown $(id -u):$(id -g) $manage_conf

  # view whether kube-proxy is in IPVS mode
  _logger info "7.4 Verifying kube-proxy is using IPVS mode"
  kubectl -n kube-system get cm kube-proxy -o yaml | grep mode  # k8s > v1.17, default ipvs

  # get cluster node and kube-system's pod status
  _logger info "7.5 Verifying get node status and pod status via $manage_conf"
  kubectl get node
  _chk_pod kube-system   # ensure the cluster can accept resource creation requests normally
}


#############################################################################
## Function: install_calico
## Overview: Function to install Calico and Calicoctl.
## Description:
##  Retrieve the official Calico Operator and CRD YAML, modify the image 
##  addresses to point to the private registry, set the image pull policy to
##  "IfNotPresent", configure the network policy to automatically detect node
##  addresses based on the specified network interface name, and then deploy
##  the calico components. And install calicoctl cli tools to /usr/local/bin.
##
## Parameters:
##
## Returns:
##   -  0: Success (init a single master node cluster successfully)
##   - !0: Failure (...)
##
## Example:
##   GITHUB_PROXY="https://ghproxy.net"
##   CALICO_VER="xxx"
##   INIT_NODE_IP="xxx"
##   POD_SUBNET="10.244.0.0/16"
##   init_cluster
#############################################################################
function install_calico() {
  local calico_config_path="/etc/kubernetes/plugins/calico"
  local calico_url=(
    # tigera-operator.yaml deploys and upgrades Calico, while custom-resources.yaml configures its behavior
    "$GITHUB_PROXY/https://raw.githubusercontent.com/projectcalico/calico/v$CALICO_VER/manifests/tigera-operator.yaml"
    "$GITHUB_PROXY/https://raw.githubusercontent.com/projectcalico/calico/v$CALICO_VER/manifests/custom-resources.yaml"
    "$GITHUB_PROXY/https://github.com/projectcalico/calico/releases/download/v$CALICO_VER/calicoctl-linux-amd64"
  )

  _print_line title "8. Install the Calico network plugin to connect node networks (current machine: $(hostname))"

  _logger info "8.1 download the Calico Operator and CRD YAML files and deployment"
  _remote_get_resource download calico $offline_pkg_path/download/calico ${calico_url[@]}
  mkdir -p $calico_config_path
  cp -v $offline_pkg_path/download/calico/* $calico_config_path

  sed -i "/image: /s/quay.io/$INIT_NODE_IP:5000/g" $calico_config_path/tigera-operator.yaml
  kubectl create -f $calico_config_path/tigera-operator.yaml
  _chk_pod tigera-operator

  # update pod subnet, images repo url, nodeAddressAutodetection based on the specified network interface name
  local iface="$(ip addr | grep "$SRV_IP" | awk '{print $NF}')"
  local spec_line=$(awk '/spec:/ { print NR; exit }' "$calico_config_path/custom-resources.yaml")
  sed -i \
    -e "${spec_line}a\  registry: \"$INIT_NODE_IP:5000\"\n  imagePath: \"calico\"\n  imagePrefix: \"\"" \
    -e "s|cidr: 192.168.0.0/16|cidr: $POD_SUBNET|" \
    -e "/calicoNetwork:/a \    nodeAddressAutodetectionV4:\n      interface: \"$iface\"" \
    $calico_config_path/custom-resources.yaml

  kubectl apply -f $calico_config_path/custom-resources.yaml

  _logger info "8.2 install calicoctl cli tools"
  cp $calico_config_path/calicoctl-linux-amd64 /usr/local/bin/calicoctl && chmod +x $_
  # fix error for calicoctl version: ClusterInformation(default) with error: clusterinformations.crd.projectcalico.org "default" not found
  _chk_pod calico-system
  _logger info "The Calicoctl version:"
  calicoctl version
  _logger info "The current status of a Calico node:"
  calicoctl node status
}

#############################################################################
## Function: generate_token
## Overview: Function to generate cluster token for master and node machines.
## Description:
##   Generate passwords in advance for nodes that are about to join the 
##   cluster during the initialization of the nodes, and pass them as variables
##   to accommodate one-way passwordless scenarios.
##
## Parameters:
##
## Returns:
##   -  0: Success (generate tokens successfully)
##   - !0: Failure (failed to ...)
##
## Example:
##   declare -A join_cmds
##   generate_token
#############################################################################
function generate_token() {
  _print_line title " Gererate token for join cluster"

  certificate_key="$(kubeadm init phase upload-certs --upload-certs | tail -n 1 | awk '{print $NF}')"
  join_cmds[master]="$(kubeadm token create --print-join-command --certificate-key $certificate_key)"
  join_cmds[node]="$(kubeadm token create --print-join-command)"

  _logger info "The token of master join cluster is: \n${join_cmds[master]}"
  _logger info "The token of node join cluster is: \n${join_cmds[node]}"
}


#############################################################################
## Function: remote_dist
## Overview: Function for concurrent remote resource distribution.
## Description:
##  Call the general remote resource distribution function '_remote_dist' to
##  proactively push essential packages to remote machines, which works in 
##  tandem with the remote resource acquisition function, the latter being 
##  suitable for pulling resources from remote machines.
##
## Parameters:
##
## Returns:
##   -  0: Success (distributed resources to remote machines successfully)
##   - !0: Failure (...)
##
## Example:
##   resource_paths=(
##     "$offline_pkg_path/rpm/lrzsz"
##     "$offline_pkg_path/rpm/sshpass"
##     "$offline_pkg_path/rpm/parallel"
##   )
##   exclude_ip="$INIT_NODE_IP"
##
##   # chk args
##   _remote_get_ip2host
##
##   _remote_dist "$exclude_ip" "${resource_paths[@]}"
#############################################################################
function remote_dist() {
  # define resources

  local -a resource_paths=(
    "/root/$dep_script"
    "$offline_pkg_path/rpm"
    "$offline_pkg_path/download"
  )
  local exclude_ip="$INIT_NODE_IP" # Define remote machines to exclude from the loop

  _print_line title "9. Parallel remote execution"

  # chk args
  _remote_get_ip2host
  
  if [[ ${#ip2host[@]} -eq 0 ]]; then
    _logger error "The remote host IP list is empty, please run the $script_path at least once."
    exit 1
  fi

  cp $workdir/$dep_script /root/$dep_script
  echo -e "rm -- "/root/\$0"" >> /root/$dep_script
  
  # distributed resources
  _remote_dist "$exclude_ip" "${resource_paths[@]}"
}


#############################################################################
## Function: remote_parallel
## Overview: Function for remote parallel script execution.
## Description:
##  Call the remote script execution function '_remote_parallel' to 
##  concurrently run the specified script on remote machine nodes.
##
## Parameters:
##
## Returns:
##   -  0: Success (run the specified script on remote machine nodes successfully)
##   - !0: Failure (...)
##
## Example:
##   scp_script_path="xxx"
##   exclude_ip="$INIT_NODE_IP"
##   local -a env_vars=(ip2host INIT_NODE_IP DASHBOARD_TOKEN join_cmds tag)
##   local -a script_args=("$@")
##
##   # chk args
##   if grep -q -E '^source[[:space:]]+\"?[^[:space:]]+\.sh\"?' "$scp_script_path"; then
##     _logger error "Remote script contains external dependencies, cannot execute on remote nodes."
##     _logger error "Please generate a complete independent script first by run ${blue}bash build.sh gr $(basename $scp_script_path)"
##     exit 1
##   fi
##
##   _remote_get_ip2host
##
##   _remote_parallel parallel "$scp_script_path" "$exclude_ip" "${env_vars[@]}" -- "${script_args[@]}"
#############################################################################
function remote_parallel() {
  local scp_script_path=$abs_script_path
  local exclude_ip="$INIT_NODE_IP" # Define remote machines to exclude from the loop
  local -a env_vars=(ip2host INIT_NODE_IP DASHBOARD_TOKEN join_cmds tag)
  local -a script_args=("$@")

  _print_line title "10. Parallel remote execution"

  # chk script
  if grep -q -E '^source[[:space:]]+\"?[^[:space:]]+\.sh\"?' "$scp_script_path"; then
    _logger error "Remote script contains external dependencies, cannot execute on remote nodes."
    _logger error "Please generate a complete independent script first by run ${blue}bash build.sh gr $(basename $scp_script_path)"
    exit 1
  fi

  # get ip2host
  _remote_get_ip2host

  [[ ${#ip2host[@]} -eq 0 ]] && { \
    _logger error "The remote host IP list is empty, please run the $scp_script_path at least once." && exit 1; }

  # call _remote_parallel parallel execution
  _remote_parallel parallel "$scp_script_path" "$exclude_ip" "${env_vars[@]}" -- "${script_args[@]}"
}


#############################################################################
## Function: join_cluster
## Overview: Function to remotely generate cluster tokens and join the cluster.
## Description:
##   Read the cluster password from the variable definitions in the script 
##   passed remotely, or generate the cluster password by executing commands
##   remotely. Nodes use the corresponding password to join the cluster based 
##   on their roles(master/node).
##
## Parameters:
##
## Returns:
##   -  0: Success (join cluster successfully)
##   - !0: Failure (failed to ...)
##
## Example:
##   declare -A join_cmds
##   join cluster
#############################################################################
function join_cluster() {
  _print_line title "11. Add all nodes to cluster (current machine: $(hostname))"

  # generating token
  local node_role=$(hostname -s | grep -oE 'master|node')

  if [[ ${#join_cmds[@]} -ne 2 ]]; then
    _logger info "Failed to read token from script variable definitions, generating cluster join command remotely ..."
    case $node_role in
      master)
        certificate_key=$(ssh $USER@$INIT_NODE_IP "kubeadm init phase upload-certs --upload-certs | tail -n 1 | awk '{print $NF}'")
        join_cmds[master]=$(ssh $USER@$INIT_NODE_IP "kubeadm token create --print-join-command --certificate-key $certificate_key")
        ;;
      node)
        join_cmds[node]=$(ssh $USER@$INIT_NODE_IP "kubeadm token create --print-join-command")
        ;;
      *)
        _logger info "Failed to get role type from hostname, please check the current hostname."
        exit 1
        ;;
    esac
  else
    _logger info "Read the password from script variable definitions, attempting to join the cluster."
  fi

  # join cluster
  if [[ -z ${join_cmds[$node_role]} ]]; then
    _logger error "Token is empty, please manually execute the command on the master node (init management node) to generate:"
    master_join_cmd="kubeadm token create --print-join-command --certificate-key $(kubeadm init phase upload-certs --upload-certs \
        | tail -n 1 | awk '{print $NF}')"
    node_join_cmd="kubeadm token create --print-join-command"

    local cmd="${role}_join_cmd"
    echo -e "${red}${!cmd}${reset}"
  else
    ${join_cmds[$node_role]}
  fi
}


#############################################################################
## Function: install_helm
## Overview: Function to install helm latest version.
## Description:
##  Download the latest Helm binary package to the offline path and install it.
##
## Parameters:
##
## Returns:
##   -  0: Success (install helm successfully)
##   - !0: Failure (...)
##
## Example:
##   offline_pkg_path="/usr/local/src/k8s_offline_$K8S_V"
##   install_helm
#############################################################################
function install_helm() {
  _print_line title "12. Install helm: package manager for kubernetes"

  local latest_ver=$(curl -s https://api.github.com/repos/helm/helm/releases/latest | grep -oP '"tag_name": "\K(v[0-9.]+)')
  latest_ver=${latest_ver:-v3.17.3}
  local helm_url=(
    #"https://get.helm.sh/helm-v${latest_ver}-linux-amd64.tar.gz"
    #"https://get.helm.sh/helm-v${latest_ver}-linux-amd64.tar.gz.sha256"
    "https://files.m.daocloud.io/get.helm.sh/helm-${latest_ver}-linux-amd64.tar.gz"
  )
    
  _remote_get_resource download helm $offline_pkg_path/download/helm ${helm_url[@]}
  tar -zxvf $offline_pkg_path/download/helm/helm-${latest_ver}-linux-amd64.tar.gz -C /tmp --wildcards --no-anchored 'helm'
  mv /tmp/linux-amd64/helm /usr/local/bin/
  helm version

  _logger info "Helm install successfully."
}


#############################################################################
## Function: install_k9s_cli
## Overview: Function to install k9s cli tool.
## Description:
##  Download the latest k9s binary package to the offline path and install it.
##
## Parameters:
##
## Returns:
##   -  0: Success (install k9s cli successfully)
##   - !0: Failure (...)
##
## Example:
##   offline_pkg_path="/usr/local/src/k8s_offline_$K8S_V"
##   install_k9s_cli
#############################################################################
function install_k9s_cli() {
  _logger info "13. Install k9s tool"
  local latest_ver="$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | grep tag_name | cut -d '"' -f 4)"
  local k9s_ver=${latest_ver:-"v0.50.4"}
  local k9s_url="https://files.m.daocloud.io/github.com/derailed/k9s/releases/download/$k9s_ver/k9s_Linux_amd64.tar.gz"
  
  _remote_get_resource download k9s $offline_pkg_path/download/k9s $k9s_url
  tar -zxvf $offline_pkg_path/download/k9s/k9s_Linux_amd64.tar.gz -C /usr/bin --wildcards --no-anchored 'k9s'
  chmod +x /usr/bin/k9s
  k9s version
}


#############################################################################
## Function: install_board
## Overview: Function to install various Kubernetes UI Board.
## Description:
##  Download the latest k9s binary package to the offline path and install it.
##
## Parameters:
##   $1: UI_BOARD_TY (such as kubernetes-dashboard, kuboard)  # If empty, an 
##       interactive selection will be prompted.
##
## Returns:
##   -  0: Success (install Kubernetes UI Board successfully)
##   - !0: Failure (...)
##
## Example:
##   install_board
##   or 
##   install_board kuboard
#############################################################################
function install_board() {
  _print_line title "14. Install Kubernetes UI Board"

  # get board type
  UI_BOARD_TY="$1"

  if [[ -z $UI_BOARD_TY ]]; then
    echo -e "Please select the Kubernetes UI Board to deploy:
${green}1 kubernetes-dashboard ${reset} A lightweight Kubernetes dashboard provided officially, suitable for quick access and monitoring
${green}2 kuboard ${reset} A powerful open-source Kubernetes management interface with enhanced experience and advanced features
  ..."

    read -rp "Enter the number: " SN
    [[ "$SN" == '1' ]] && UI_BOARD_TY="kubernetes-dashboard"
    [[ "$SN" == '2' ]] && UI_BOARD_TY="kuboard"
  fi

  # Define function to install dashboard
  function install_dashboard() {
    # local latest_ver=$(curl -s https://api.github.com/repos/kubernetes/dashboard/releases/latest | grep -oP '"tag_name": "\K(kubernetes-dashboard-[0-9.]+)')
    local dashboard_ver="${latest_ver:-"kubernetes-dashboard-7.12.0"}"
    local dashboard_url="$GITHUB_PROXY/https://github.com/kubernetes/dashboard/releases/download/$dashboard_ver/${dashboard_ver}.tgz"
    local dashboard_path="/etc/kubernetes/plugins/dashboard"

    # get dashboard related chart pkg
    _remote_get_resource download dashboard $offline_pkg_path/download/dashboard $dashboard_url
    mkdir -p $dashboard_path
    tar -zxvf $offline_pkg_path/download/dashboard/${dashboard_ver}.tgz -C $dashboard_path

    # update values.yaml
    sed -i \
      #-e 's/^ingress:[[:space:]]*enabled:[[:space:]]*true/ingress:\n  enabled: false/' \
      -e "s|\(repository:[[:space:]]*\)\([^/]*\)/\(.*\)|\1$INIT_NODE_IP:5000/\3|" \
    $dashboard_path/kubernetes-dashboard/values.yaml

    sed -i "/repository: kong$/s#kong#$INIT_NODE_IP:5000/kong#g" $dashboard_path/kubernetes-dashboard/charts/kong/values.yaml

    # helm install chart pkg
    helm upgrade --install kubernetes-dashboard $dashboard_path/kubernetes-dashboard --create-namespace --namespace kubernetes-dashboard


    # _print_line split -
    # local dashboard_path="/etc/kubernetes/plugins/dashboard"
    # local dashboard_url="$GITHUB_PROXY/https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml"

    # _remote_get_resource download dashboard $offline_pkg_path/download/dashboard $dashboard_url
    # mkdir -p $dashboard_path
    # cp -v $offline_pkg_path/download/dashboard/recommended.yaml $dashboard_path

    # local rcmd_yml="$dashboard_path/recommended.yaml"
    # local line_number=$(grep -n 'targetPort: 8443' $rcmd_yml | cut -d: -f1)
    # local insert_line=$((line_number - 2))
    # sed -i -e "${insert_line}i\\  type: NodePort" \
    #   -e "/targetPort: 8443/a \      nodePort: 30443" \
    #   -e "/imagePullPolicy/s/Always/IfNotPresent/g" $rcmd_yml
    # grep -4 "targetPort: 8443" $rcmd_yml
    # kubectl apply -f $rcmd_yml

    # check related pods
    _logger info "Show the status of $UI_BOARD_TY"
    _print_line split -
    # kubectl get pod -n $UI_BOARD_TY -o wide
    _chk_pod $UI_BOARD_TY
    echo
    kubectl get svc -n $UI_BOARD_TY -o wide

    # create ServiceAccount
    _logger info "Create ServiceAccount and Token"
    _print_line split -
    tee $dashboard_path/dashboard-user.yaml <<-EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
EOF
    kubectl apply -f $dashboard_path/dashboard-user.yaml

    # create token
    DASHBOARD_TOKEN=$(kubectl -n kubernetes-dashboard create token admin-user)
  }

  # Define function to install kuboard
  function install_kuboard() {
    _logger info "Download and deploy Kuboard"
    _print_line split -
    _logger info "Reference tutorial: https://kuboard.cn/install/v3/install-in-k8s.html"

    local kuboard_path="/etc/kubernetes/plugins/kuboard"
    local kuboard_url="https://addons.kuboard.cn/kuboard/kuboard-v3-swr.yaml"

    # get kuboard related yaml
    _remote_get_resource download kuboard $offline_pkg_path/download/kuboard $kuboard_url
    mkdir -p $kuboard_path
    cp $offline_pkg_path/download/kuboard/* $kuboard_path

    # update imagePullPolicy
    sed -i -e "/image: /s#swr.cn-east-2.myhuaweicloud.com#$INIT_NODE_IP:5000#g" \
      -e "/imagePullPolicy/s/Always/IfNotPresent/g" -e "/KUBOARD.*PORT/d" \
      $kuboard_path/kuboard-v3-swr.yaml

    kubectl apply -f $kuboard_path/kuboard-v3-swr.yaml

    # check related pods
    _logger info "Show the status of $UI_BOARD_TY"
    _print_line split -
    kubectl get pod -n $UI_BOARD_TY -o wide
    echo
    kubectl get svc -n $UI_BOARD_TY -o wide
  }

  # Deploy board when node ready
  _logger info "Deploy board when node ready"
  while true; do
    if [[ $(kubectl get node | grep "Ready" | grep -v "control-plane" | wc -l) -gt 0 ]]; then
      case $UI_BOARD_TY in
        kubernetes-dashboard)
          install_dashboard
          ;;
        kuboard)
          install_kuboard
          ;;
        *)
          _logger warn "Invalid input, no Kubernetes UI Board will be installed this time."
          ;;
      esac
      break
    else
      _logger warn "No worker nodes in the "Ready" state, cannot deploy $UI_BOARD_TY resources."
    fi
    sleep 3
  done
}


#############################################################################
## Function: cluster_health_chk
## Overview: Function to check the cluster health status after deployment.
## Description:
##  Check important pods like calico and dashboard until they are running, 
##  print the status of all nodes and pods in the cluster, and finally provide
##  access and usage instructions for the dashboard.
##
## Parameters:
##
## Returns:
##   -  0: Success (cluster running successfully)
##   - !0: Failure (...)
##
## Example:
##   SRV_IP="xxx"
##   UI_BOARD_TY="xxx"
##   cluster_health_chk
#############################################################################
function cluster_health_chk() {
  _print_line title "15. Check the health metrics of the cluster"

  # check pods of calico-system namespace
  _logger info "Check the stauts of calico pods"
  _print_line split -
  _chk_pod calico-system

  # check pods of $UI_BOARD_TY namespace
  if [[ $UI_BOARD_TY =~ ^(kubernetes-dashboard|kuboard)$ ]]; then
    _logger info "Check the stauts of $UI_BOARD_TY pods"
    _chk_pod $UI_BOARD_TY
  fi

  # show the status of all nodes and pods in cluster
  _print_line split blank 3
  _logger info "Show the status of the entire cluster."
  _logger info "The status of the cluster's nodes:"
  kubectl get node -o wide
  _logger info "The status of the cluster's services:"
  kubectl get svc --all-namespaces -o wide
  _logger info "The status of the cluster's pods:"
  kubectl get pod --all-namespaces -o wide

  # summary
  if [[ -n $UI_BOARD_TY ]]; then
    _print_line title "Information of the Kubernetes UI Board:"
    case $UI_BOARD_TY in
      kubernetes-dashboard)
        echo -e "${green}$UI_BOARD_TY is deployed, please visit https://$SRV_IP:30443/, Login TOKEN: \n{reset}$DASHBOARD_TOKEN"
        ;;
      kuboard)
        echo -e "${green}$UI_BOARD_TY is deployed, please visit http://$SRV_IP:30080/, default username/password: admin/Kuboard123"
        ;;
    esac
  fi
  echo

  # export script variable definitions for later functions or future scripts to retrieve historical variable values
  declare -p DASHBOARD_TOKEN >> /tmp/${tag}_var
}


#############################################################################
## Function: display_cmd
## Overview: Function to print examples of commonly used k8s commands.
## Description:
##  Provide commonly used commands categorized by different levels of 
##  resources, allow inputting corresponding numbers for quick command entry, 
##  and wait for user modifications before execution.
##
## Parameters:
##
## Returns:
##   -  0: Success (...)
##   - !0: Failure (...)
##
## Example:
##   display_cmd
#############################################################################
display_cmd() {
  _print_line title "Display frequently used commands"

  # display node related cmds

  # display pod related cmds

  # display svc related cmds

  # display endpoint related cmds

  # display ingress related cmds

  # TODO
  # 获取传入的数字
  # number=$1

  # # 构造命令
  # command="your_command $number"

  # # 输出命令并等待用户修改
  # read -p "$command " user_input

  # # 执行修改后的命令
  # eval $user_input
}


#############################################################################
## Function: reset
## Overview: Function to reset the cluster.
## Description:
##  Reset the cluster, clear IPVS rules, and remove related user files and
##  environment variables.
##
## Parameters:
##
## Returns:
##   -  0: Success (...)
##   - !0: Failure (...)
##
## Example:
##   tag="k8s_cluster"
##   INIT_NODE_IP=""
##   reset
#############################################################################
function reset() {
  _print_line title "Reset cluster"

  # get var
  if [[ ! -f /tmp/${tag}_var ]]; then
    _logger error "Already cleaned up, skipping, clean manually if needed."
  else
    source /tmp/${tag}_var
  fi

  # define the list of files to be removed. 
  clean_files=(
    $HOME/.kube
    $HOME/kubeadm_init.yaml
  )

  # reset
  for ip in ${!ip2host[@]}; do
    _logger info "// Start clean node: ${ip2host[$ip]} ($ip)"
    _print_line split -

    # kubeadm reset -f
    if [[ "$ip" == "$INIT_NODE_IP" ]]; then
      _logger info "1. Execute 'kubeadm reset'"
      printf "${gray}"
      ssh -o StrictHostKeyChecking=no -t "$USER@$ip" "kubeadm reset -f || true;"
    else
      _logger warn "1. Non-cluster initializing node, no reset needed"
    fi

    # ipvsadm --clear
    echo
    _logger info "2. Clean up IPVS load balancing rules"
    printf "${gray}"
    ipvsadm --clear || true

    # rm -rvf
    echo
    _logger info "3. Clean up residual dirs/files, but keep '$offline_pkg_path/k8s_offline_${K8S_V}.tar.gz' and '/tmp/${tag}_var'."
    printf "${gray}"
    ssh -o StrictHostKeyChecking=no -t "$USER@$ip" "rm -rvf ${clean_files[@]} || true"

    # rollback /etc/profile
    echo
    _logger info "4. Clear environment variables"
    printf "${gray}"
    ssh -o StrictHostKeyChecking=no -t "$USER@$ip" "sed -i -e '/KUBE.*/d' -e '/kube.*/d' /etc/profile || true"

    echo
    _print_line split -
    _logger info "6. Cluster node ${ip2host[$ip]} ($ip) cleaned up."
    echo && printf "${reset}"
  done
}


#############################################################################
## Function: remove_and_clean
## Overview: Function to fully revert system to pre-k8s state.
## Description:
##  Reset the cluster, clear IPVS rules, and remove related user files and
##  environment variables.
##
## Parameters:
##
## Returns:
##   -  0: Success (...)
##   - !0: Failure (...)
##
## Example:
##   tag="k8s_cluster"
##   INIT_NODE_IP=""
##   reset
#############################################################################
function remove_and_clean() {
  _print_line title "Remove installation and clean up completely"

  if [[ ! -f /tmp/${tag}_var ]]; then
    _logger error "Already cleaned up, skipping, clean manually if needed."
  else
    source /tmp/${tag}_var
  fi

  # TODO:  需要未使用的磁盘，后续考虑看是否引导用户在部署前自动建快照，以提供回滚干净环境的能力
  # df -h
  # lsblk
  # lvcreate --size 10G --snapshot --name rl-root-snapshot /dev/mapper/rl-root
  # lvs
  # lvconvert --merge /dev/mapper/rl-root-snapshot
  # reboot

  clean_files=(
    $HOME/.kube
    $HOME/kubeadm_init.yaml
    $offline_pkg_path/k8s_offline_${K8S_V}.tar.gz
    /root/containerd_with_nerdctl.sh
    /tmp/${tag}_var
  )

  for ip in ${!ip2host[@]}; do
    echo
    _logger info "// Start cleaning node ${ip2host[$ip]} ($ip)"
    _print_line split -
    if [[ "$ip" == "$INIT_NODE_IP" ]]; then
      _logger info "1. Execute 'kubeadm reset'"
      printf "${gray}"
      ssh -o StrictHostKeyChecking=no -t "$USER@$ip" "kubeadm reset -f || true;"
    else
      _logger warn "1. Non-cluster init node, no reset needed"
    fi

    echo
    _logger info "2. Remove related images"
    printf "${gray}"
    ssh -o StrictHostKeyChecking=no -t "$USER@$ip" "nerdctl -n k8s.io images -aq | xargs -r nerdctl rmi || true"

    echo
    _logger info "3. Remove kubeadm, kubelet, kubectl"
    printf "${gray}"
    ssh -o StrictHostKeyChecking=no -t "$USER@$ip" "systemctl stop kubelet || true && systemctl disable kubelet || true && \
    dnf remove -y kubeadm && rm -rf /etc/yum.repos.d/kubernetes.repo && rm -rf /etc/kubernetes"

    echo
    _logger info "4. Remove containerd"
    printf "${gray}"
    ssh -o StrictHostKeyChecking=no -t "$USER@$ip" "systemctl stop containerd || true && systemctl disable containerd || true && \
    systemctl stop stargz-snapshotter || true && systemctl disable stargz-snapshotter || true && \
    systemctl stop buildkit || true && systemctl disable buildkit || true && \
    rmdir /sys/fs/cgroup/memory/system.slice/stargz-snapshotter.service || true
    find / -type d -name cni -o -name containerd -o -name nerdctl* \
    -type f -name containerd* -o -name buildkit* -o -name buildctl* -o -name buildg* -o -name bypass4netns* \
    -o -name ctd-decoder -o -name ctr* -o -name ipfs* -o -name rootless* -o -name runc -o -name slirp4netns \
    -o -name tini -o -name stargz-snapshotter* -exec rm -rf {} + || true && \
    rm -rf /etc/containerd /var/log/containerd* || true"

    echo
    _logger info  "5. Remove IPVS rules, container networks, and related tools"
    printf "${gray}"
    ssh -o StrictHostKeyChecking=no -t "$USER@$ip" "ipvsadm -C && ip link delete kube-ipvs0 && ip link delete vxlan.calico && \
    dnf remove -y lrzsz sshpass ipset ipvsadm parallel || true"

    echo
    _logger info "6. Revert kernel parameters: routing forwarding, bridge filtering, swap tendency, etc."
    printf "${gray}"
    ssh -o StrictHostKeyChecking=no -t "$USER@$ip" << 'EOF'
    cat > /etc/sysctl.d/k8s.conf <<EOF2
net.bridge.bridge-nf-call-ip6tables = 0
net.bridge.bridge-nf-call-iptables = 0
net.ipv4.ip_forward = 0
vm.swappiness = 60
EOF2
    sysctl -p /etc/sysctl.d/k8s.conf
EOF

    echo
    _logger info  "7. Disable related kernel modules"
    printf "${gray}"
    ssh -o StrictHostKeyChecking=no -t "$USER@$ip" "rm -rvf /etc/modules-load.d/{ipvs,br_netfilter}.conf \
    && systemctl daemon-reload && systemctl restart systemd-modules-load"

    echo
    _logger info "8. Enable swap"
    printf "${gray}"
    ssh -o StrictHostKeyChecking=no -t "$USER@$ip" "sed -ri '/^#(.*swap.*)/s/^#//g' /etc/fstab"

    echo
    _logger info "9. Clear environment variables"
    printf "${gray}"
    ssh -o StrictHostKeyChecking=no -t "$USER@$ip" "sed -i -e '/KUBE.*/d' -e '/kube.*/d' /etc/profile || true"

    echo
    _logger info "10. Clean up hosts entries"
    printf "${gray}"
    for i in ${!ip2host[@]}; do  
      ssh -o StrictHostKeyChecking=no -t "$USER@$ip" "sed -i '/$i ${ip2host[$i]}/d' /etc/hosts"
    done
    ssh -o StrictHostKeyChecking=no -t "$USER@$ip" "sed -i '/raw.githubusercontent.com/d' /etc/hosts"

    echo
    _logger info "11. Clean dirs/files, include '$offline_pkg_path/k8s_offline_${K8S_V}.tar.gz'"
    printf "${gray}"
    ssh -o StrictHostKeyChecking=no -t "$USER@$ip" "rm -rvf ${clean_files[@]} || true"

    echo
    _print_line split -
    _logger info "12. Cluster node ${ip2host[$ip]} ($ip) cleaned up."
    echo && printf "${reset}"
  done
}

function main() {
  function _help() {
    printf "Invalid option ${@:1}\n"
    printf "${green}Usage: ${reset}\n"
    printf "    ${gray}bash ${blue}$0 ${green}dp${gray}(deploy) ${green}cluster${gray}/node 1.29${reset}\n"
    printf "    ${gray}bash ${blue}$0 ${green}reset${gray}/remove${reset}\n"
    printf "    ${gray}bash ${blue}$0 ${green}dis${reset}\n\n"
  }

  case "$1-$2" in
    dp-cluster|deploy-cluster)
      plan_nodes $2
      config_sys
      install_containerd
      install_kubeX
      config_private_registry
      load_and_push_image
      init_cluster
      install_calico
      generate_token
      time remote_dist
      shift 2
      time remote_parallel deploy node ${@:1}
      install_k9s_cli
      install_board kuboard
      cluster_health_chk
      ;;
    dp-node|deploy-node)
      plan_nodes $2
      config_sys
      install_containerd
      install_kubeX
      config_private_registry
      join_cluster
      ;;
    reset-)
      reset
      ;;
    remove-)
      remove_and_clean
      ;;
    dis)
      display_cmd
      ;;
    *)
      _help ${@:1} && exit 1
      ;;
  esac
}

main ${@:1}
