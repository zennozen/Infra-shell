#!/usr/bin/env bash
############################## import #######################################
# tag="xx_cluster"
# script_path="$(dirname ${BASH_SOURCE[0]})"
#
# # import some define
# source "$script_path/../00_utils/_print.sh"
# source "$script_path/../00_utils/_trap.sh"
# source "$script_path/../00_utils/_logger.sh"
# source "$script_path/../00_utils/_remote.sh"
############################## import #######################################

# The dependencies will be imported by the functional script itself to avoid duplication and conflicts here.
# script_path="$(dirname ${BASH_SOURCE[0]})"
# import some define
# source "$script_path/_print.sh"
# source "$script_path/_logger.sh"

# define golabal variables
SRV_IP="$(ip -4 addr show | grep inet | grep -v 127.0.0.1 | awk 'NR==1 {print $2}' | cut -d'/' -f1)"

# Enable the DNF RPM package cache to achieve offline installation of related packages
if ! grep -q '^keepcache=1' /etc/dnf/dnf.conf; then
  echo "keepcache=1" | tee >> /etc/dnf/dnf.conf
fi

#############################################################################
## Function: _d_remote_ssh_passfree_config
## Overview：General SSH passwordless function. 
## Description:
##   Plan for passwordless authentication and hosts setup on multiple nodes.
##
## Parameters:
##   - $HOME/.hosts
##
## Returns:
##   -  0: Success (get ips and hostnames, config ssh passwordfree successfully)
##   - !0：Failure (...)
##
## Example:
##   1. (Optional) create $HOME/.hosts
##     192.168.85.111 master1
##     192.168.85.112 master2
##     192.168.85.113 master3
##     192.168.85.121 node1
##     192.168.85.122 node2
##     192.168.85.123 node3
##     one-way="master"
##     sync-hostname=true
##   2.
##     _d_remote_ssh_passfree_config
#############################################################################
function _d_remote_ssh_passfree_config() {
  _print_line title "Plan $tag nodes ip and hostname, configure ssh passwordfree"

  # Get ips and hostnames list
  _logger info "1. Get the list of IP addresses and hostnames from \$HOME/.hosts file or user input."
  local ipSegment=$(echo $SRV_IP | cut -d'.' -f-3)
  echo -e "${green} \$HOME/.hosts context example:${reset}"
  echo "
$ipSegment.111 k8s-master1
$ipSegment.112 k8s-master2
$ipSegment.113 k8s-master3
$ipSegment.121 k8s-node1
$ipSegment.122 k8s-node2
$ipSegment.123 k8s-node3
one-way=\"master\"
sync-hostname=true
srv_passwd=\"AAAaaa12#$\"
  "
  # from $HOME/.hosts
  if [[ -f $HOME/.hosts ]]; then
    _logger info "found $HOME/.hosts file, reading from it"
    echo -e "${green} Current \$HOME/.hosts context:${reset}"
    echo
    cat $HOME/.hosts
    echo

    one_way_host_str=""
    sync_hostname=true

    while IFS= read -r line; do
      # skip empty lines and comments
      [[ -z "$line" || "$line" =~ ^#.* ]] && continue

      if [[ "$line" =~ ^one-way= ]]; then
        one_way_host_str=$(echo "$line" | cut -d'=' -f2 | tr -d '"')
        continue
      fi

      if [[ "$line" =~ ^sync-hostname= ]]; then
        sync_hostname=$(echo "$line" | cut -d'=' -f2 | tr -d '"')
        continue
      fi

      # validate IP address format
      if [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+[a-zA-Z0-9_-]+$ ]]; then
        ip=$(echo "$line" | awk '{print $1}')
        hostname=$(echo "$line" | awk '{print $2}')
        ip2host["$ip"]="$hostname"
      else
        echo -e "${yellow}Skipping invalid line: $line${reset}"
      fi
    done < "$HOME/.hosts"
  else
    # from user input
    _logger info "No $HOME/.hosts file found, entering interactive input mode"
    echo -e "${green}Enter IPs and hostnames, one per line, an empty line completes the input, example:"
    echo -e "${gray}192.168.85.121 server-01\n192.168.85.122 server-02\n192.168.85.123 server-03${reset}"

    while true; do
      read -p "" line
      [[ -z $line ]] && break

      ip=$(echo "$line" | awk '{print $1}')
      hostname=$(echo "$line" | awk '{print $2}')
      ip2host["$ip"]="$hostname"
    done
  fi

  # Exclude running the script on non-planned machines
  if [[ -z "${ip2host[$SRV_IP]}" ]]; then
    _logger error "If the primary network card's IP is not in the cluster nodes, the installation will exit."
    return 1
  fi

  # Support one-way passwordless
  _logger info "2. Get and identify the host for one-way password-free login"
  declare -a matched_one_way_hosts
  while true; do
    if [[ ! -f $HOME/.hosts ]] && [[ -z "$one_way_host_str" ]]; then
      echo -e "${green}Please enter the hostname of the host that only allows one-way password-free login to other hosts,"
      printf "${green}(e.g., ${red}master/controller${green}) [Enter for none]: ${reset}"
      read -p "" one_way_host_str
      echo
    fi

    if [[ -n "$one_way_host_str" ]]; then
      matched_one_way_ips=()
      found=false

      for ip in "${!ip2host[@]}"; do
        hostname=${ip2host[$ip]}
        if [[ $hostname =~ ^$one_way_host_str ]]; then
          matched_one_way_ips+=("$ip")
          found=true
        fi
      done

      if [[ "$found" = true ]]; then
        for ip in "${matched_one_way_ips[@]}"; do
          echo -e "$ip ${red}${ip2host[$ip]}${reset}"
        done

        echo -e "${green}Matched the above machines.${reset}"
        break
      else
        echo -e "${yellow}No match found for host pattern: $one_way_host_str ${reset}"
      fi
    else
      matched_one_way_ips=("${!ip2host[@]}")
      echo -e "${green}No matching required this time.${reset}"
      break
    fi
  done

  _logger info "Installing sshpass ..."
  _remote_get_resource rpm sshpass $offline_pkg_path/rpm/sshpass -q >/dev/null

  # Get servers password
  while true; do
    if [[ -z $srv_passwd ]]; then
      printf "Ensure all servers have ${red}the same password ${reset}and enter it: "
      read -rsp "" srv_passwd
      echo
    fi

    conn_status=1
    for ip in "${!ip2host[@]}"; do
      if sshpass -p "$srv_passwd" ssh -q -o StrictHostKeyChecking=no -o LogLevel=QUIET "$ip" true; then
        echo -e "${green}SSH connection to $ip succeeded using password.${reset}"
      else
        echo -e "${red}SSH connection to $ip failed using password. Please re-enter.${reset}"
        conn_status=0
        break
      fi
    done

    if [[ $conn_status -eq 1 ]]; then
      break
    fi
  done

  # Configure password-free SSH login
  _print_line split blank
  _logger info "3. Start configuring password-free SSH login"

  # generate a ssh key pair
  _logger info "3.1 Start generate a ssh key pair"

  for ip in "${!ip2host[@]}"; do
    sshpass -p "$srv_passwd" ssh -q -o StrictHostKeyChecking=no -o LogLevel=QUIET "$ip" <<-EOF
mkdir -p ${HOME}/.ssh
[[ -f ${private_key_file} ]] || ssh-keygen -t ed25519 -b 4096 -N '' -f ${private_key_file} -q
EOF
  # collect the public key from current node
  ssh_keys[$ip]=$(sshpass -p "$srv_passwd" ssh -q -o StrictHostKeyChecking=no -o LogLevel=QUIET "$ip" "cat ${public_key_file}")
  done

  # distribute hosts and authorized_key
  _logger info "3.2 Start add hosts and authorized_key"

  for ip in "${!ip2host[@]}"; do
    declare -p ip2host matched_one_way_ips ssh_keys > /tmp/cmd
    cat >> /tmp/cmd <<-EOF
# clear hosts
sed -i "/# $tag ssh passfree start/,/# $tag ssh passfree end/d" /etc/hosts

echo "# $tag ssh passfree start" >> /etc/hosts
for hip in "\${!ip2host[@]}"; do
  # update hosts
  echo "\$hip \${ip2host[\$hip]}" >> /etc/hosts
done

for aip in "\${matched_one_way_ips[@]}"; do
  # authorized_keys
  touch ${auth_key_file}
  echo \${ssh_keys[\$aip]} "#$tag" >> ${auth_key_file}
  chmod 600 ${auth_key_file}
done
echo "# $tag ssh passfree end" >> /etc/hosts

rm -- "\$0"
EOF
    sshpass -p "$srv_passwd" scp -o StrictHostKeyChecking=no "/tmp/cmd" "$USER@$ip:/tmp/"
    sshpass -p "$srv_passwd" ssh -q -o StrictHostKeyChecking=no -o LogLevel=QUIET "$ip" "bash /tmp/cmd"
  done

  # distribute known_hosts
  _logger info "3.3 Start add known_hosts"

  for ip in "${matched_one_way_ips[@]}"; do
    declare -p ip2host > /tmp/fcmd
    cat >> /tmp/fcmd <<-EOF
for kip in "\${!ip2host[@]}"; do
    touch ${known_hosts_file}
    sed -i "/^\$kip/d" ${known_hosts_file}
    ssh-keyscan -t ed25519 \$kip 2>/dev/null | sed "s/$/ #$tag/" >> ${known_hosts_file}
    ssh-keyscan -t ed25519 \${ip2host[\$kip]} 2>/dev/null | sed "s/$/ #$tag/" >> ${known_hosts_file}
done

rm -- "\$0"
EOF
    sshpass -p "$srv_passwd" scp -o StrictHostKeyChecking=no "/tmp/fcmd" "$USER@$ip:/tmp/"
    sshpass -p "$srv_passwd" ssh -q -o StrictHostKeyChecking=no -o LogLevel=QUIET "$ip" "bash /tmp/fcmd"
  done

  # verify ssh passwordless
  _logger info "3.4 Start verify ssh passwordless ..."

  conn_status=1

  for ip in "${!ip2host[@]}"; do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "$USER@$ip" true; then
      echo -e "${green}SSH passwordless login verification succeeded for ${ip2host[$ip]} ($ip).${reset}"
    else
      echo -e "${red}SSH passwordless login verification failed for ${ip2host[$ip]} ($ip).${reset}"
      conn_status=0
      break
    fi
  done

  [[ $conn_status -eq 1 ]] ||  return 1

  _print_line split blank
  # update hostname
  _logger info "4. Start update hostname on the remote host"
  if [[ -z "$sync_hostname" ]]; then
    read -p "Sync setting hostname on each node? (y/n) [Enter for y]: " answer
    answer=${answer:-"y"}
    [[ "$answer" =~ ^[Yy]$ ]] || { _logger error "User cancelled, exiting..." && return 1; }
    sync_hostname=true
  else
    for ip in "${!ip2host[@]}"; do
      if ssh -o BatchMode=yes -o ConnectTimeout=5 "$USER@$ip" "hostnamectl set-hostname ${ip2host[$ip]}"; then
        echo -e "${green}Hostname updated successfully on ${ip2host[$ip]} ($ip).${reset}"
      else
        echo -e "${red}Failed to update hostname on ${ip2host[$ip]} ($ip).${reset}"
      fi
    done
  fi

  _print_line split -
  _logger info "SSH passwordless login configuration succeeded!\n"
}

#############################################################################
## Function: _d_remote_ssh_passfree_undo
## Overview：General passwordless fallback function. 
## Description:
##   Revert the passwordless SSH configuration on multiple nodes.
##
## Parameters:
##
## Returns:
##   -  0: Success (clear ssh passwordfree and hosts successfully)
##   - !0：Failure (...)
##
## Example:
##   _d_remote_ssh_passfree_undo
#############################################################################
function _d_remote_ssh_passfree_undo() {

  # clear ssh passfree
  sed -i "/$tag/d" ${auth_key_file} ${known_hosts_file}

  # clear hosts
  sed -i "/# $tag ssh passfree start/,/# $tag ssh passfree end/d" /etc/hosts

  _print_line split -
  _logger info "SSH passwordless login has been successfully undone!\n"
}

#############################################################################
## Function: _remote_ssh_passfree
## Overview: General SSH passwordless function.
## Description:
##   Create a unified entry function for SSH passwordless configuration
##   by calling _d_remote_ssh_passfree_config and _d_remote_ssh_passfree_undo
##   based on the passed parameters.
##
## Parameters:
##   - tag : $tag (such as: es_cluster， k8s_cluster, xxxx)
##   -   $1: config/undo
##
## Returns:
##   - 0: Success (config/clear ssh passwordfree and hosts successfully)
##   - 1: Failure (Invalid option ... Usage ...)
##
## Example:
##   tag="k8s_cluster"
##   _remote_ssh_passfree config  /  _remote_ssh_passfree undo
#############################################################################
function _remote_ssh_passfree() {
  local -A ip2host
  local -A ssh_keys
  local private_key_file="${HOME}/.ssh/id_ed25519"
  local public_key_file="${HOME}/.ssh/id_ed25519.pub"
  local auth_key_file="${HOME}/.ssh/authorized_keys"   # About who can connect to me
  local known_hosts_file="${HOME}/.ssh/known_hosts"    # About who I have connected to

  case $1 in
    config)
      shift
      _d_remote_ssh_passfree_config
      ;;
    undo)
      shift
      _d_remote_ssh_passfree_undo
      ;;
    *)
      printf "Invalid option $*\n"
      printf "${green}Usage: ${reset}\n"
      printf "    ${green}$FUNCNAME config${gray}/undo xx-cluster${reset}\n"
      return 2
      ;;
  esac
}

#############################################################################
## Function: _remote_get_ip2host
## Overview: General remote metadata acquisition function.
## Description:
##   Retrieve IP addresses and hostnames of passwordless hosts from 
##   '/etc/hosts' based on '$tag'.
##
## Parameters:
##   - tag : $tag (such as: es_cluster， k8s_cluster, xxxx)
##
## Returns:
##   -  0: Success (get ips and hostnames from /etc/hosts successfully)
##   - !0: Failure (...)
##
## Example:
##   tag="k8s_cluster"
##   _remote_get_ip2host
#############################################################################
function _remote_get_ip2host() {
  if [[ ${#ip2host[@]} -eq 0 ]]; then
    # get ip and host from /etc/hosts and save to ip2host
    while IFS=' ' read -r ip host; do
      ip2host["$ip"]=$host
    done < <(awk -v tag="$tag" '
      /# '"$tag"' ssh passfree start/ {start=1; next}
      /# '"$tag"' ssh passfree end/ {start=0; next}
      start && !/^#/ && NF > 1 {print $1, $2}
    ' /etc/hosts)
  fi
}


#############################################################################
## Function: _remote_get_resource
## Overview: General remote resource acquisition function.
## Description:
##   Supports offline or online acquisition of RPM, download, 
##   and image resources.
##
## Parameters:
##   - offline_pkg_path: $offline_pkg_path
##   - $1: rpm/download/image
##   - $2: resource_name (such as lrzsz, k9s, k8s_cluster )
##   - $3: resource_offline_path ($offline_pkg_path/rpm/lrzsz, $offline_pkg_path/download/k9s, $offline_pkg_path/image/registry)
##   - ${@:4} : view the corresponding definitions in the function
##
## Returns:
##   - 0: Success (get corresponding resources successfully)
##   - 2: Failure (...)
##
## Example:
##   # get rpm
##     offline_pkg_path="/usr/local/src/k8s_offline_$K8S_V"
##     _remote_get_resource rpm bash-completion $offline_pkg_path/rpm/bash-completion -q
##     for s in ipset ipvsadm; do _remote_get_resource rpm $s $offline_pkg_path/rpm/$s -q; done
##   # get download
##     calico_url=(
##      # tigera-operator.yaml deploys and upgrades Calico, while custom-resources.yaml configures its behavior
##      "$GITHUB_PROXY/https://raw.githubusercontent.com/projectcalico/calico/v$CALICO_VER/manifests/tigera-operator.yaml"
##      "$GITHUB_PROXY/https://raw.githubusercontent.com/projectcalico/calico/v$CALICO_VER/manifests/custom-resources.yaml"
##      )
##     _remote_get_resource download calico $offline_pkg_path/download/calico ${calico_url[@]}
##
##   # get some images
##     _remote_get_resource image registry $offline_pkg_path/image/registry default docker.io/library/registry:2
##
##   # get many images
##     dashboard_imgs=(
##       "docker.io/kubernetesui/dashboard-auth:1.2.4"
##       "docker.io/kubernetesui/dashboard-api:1.12.0"
##       "docker.io/kubernetesui/dashboard-web:1.6.2"
##       "docker.io/kubernetesui/dashboard-metrics-scraper:1.2.2"
##       "docker.io/library/kong:3.8"
##     )
##     kuboard_imgs=(
##       "swr.cn-east-2.myhuaweicloud.com/kuboard/kuboard:v3"
##       "swr.cn-east-2.myhuaweicloud.com/kuboard/etcd-host:3.4.16-2"
##       "swr.cn-east-2.myhuaweicloud.com/kuboard-dependency/metrics-server:v0.6.2"
##       "swr.cn-east-2.myhuaweicloud.com/kuboard-dependency/metrics-scraper:v1.0.8"
##     )
##     for i in k8s_cluster calico dashboard kuboard; do
##       _logger info "Start loading $i related images ..."
##       local imgs_array_name="${i}_imgs"
##       declare -n imgs_ref="$imgs_array_name"
##    
##       printf "[$i]: %s\n" "${imgs_ref[@]}"
##       _remote_get_resource image $i $offline_pkg_path/image/$i k8s.io "${imgs_ref[@]}"
##     done
#############################################################################
function _remote_get_resource() {
  local res_type="$1"  # rpm/download/image
  local res_name="$2"
  local res_parent_path="$3"
  [[ $res_type == "rpm" ]] && \
    local add_repo="$4" && \
    local quiet="${@: -1}" && [[ "$quiet" == "-q" ]] || quiet=""
  [[ $res_type == "download" ]] && \
    local res_url_list=("${@:4}")
  [[ $res_type == "image" ]] && \
    local ns="$4" && \
    local res_img_list=("${@:5}") && \
    local img_file="$res_parent_path/${res_name}_imgs.tar.gz" && \
    local img_count=0 && \
    local retries=0
  local max_retries=3

  mkdir -p $res_parent_path
  case $res_type in
    # Get rpm resoures
    rpm)
      cd $res_parent_path
      # support add epel repo
      if [[ $add_repo == "epel" ]] && ! dnf repolist | grep epel 2>/dev/null; then
        _logger warn "No epel repo, will auto install epel yum source."
        tee /etc/yum.repos.d/epel.repo <<-EOF
[epel]
name=Extra Packages for Linux \$releasever - \$basearch
baseurl=https://mirrors.aliyun.com/epel/\$releasever/Everything/\$basearch/
gpgcheck=1
enabled=1
gpgkey=https://mirrors.aliyun.com/epel/RPM-GPG-KEY-EPEL-\$releasever
EOF
        dnf repolist
        dnf makecache --refresh
      fi

      if ! rpm -q "$res_name" &>/dev/null; then
        _logger info "No $res_name installed detected, trying to install"

        # offline get rpm pkg from nodes's $res_parent_path
        if [[ -z $(ls -A $res_parent_path) ]] &>/dev/null && grep "# $tag ssh passfree start" /etc/hosts >/dev/null; then
          for ip in "${!ip2host[@]}"; do
            if ssh "$USER@$ip" "[[ -n \"\$(ls -A $res_parent_path)\" ]] &>/dev/null"; then
              _logger info "$res_name rpm for ${ip2host[$ip]}, pulling and installing ..."
              scp -r $USER@$ip:$res_parent_path $(dirname $res_parent_path)
              break
            else
              _logger warn "no $res_name rpm detected in ${ip2host[$ip]}."
            fi
          done
        fi

        # online download rpm pkg to node local $res_parent_path
        if [[ -z $(ls -A $res_parent_path ) ]] &>/dev/null; then
          _logger warn "No $res_name rpm detected on any nodes, try online install with dnf."
          dnf install -y $quiet $res_name --downloadonly --downloaddir=$res_parent_path || true
        fi

        # rpm -Uvh --force --nodeps $quiet $res_parent_path/*.rpm || true
        # use dnf to enhance dependency handling instead of forcing upgrades or downgrades during rpm installation
        # disable repository and install already downloaded RPM packages from $res_parent_path
        dnf install --disablerepo=* -y $quiet $res_parent_path/*.rpm 2>/dev/null || { \
          _logger error "$res_name rpm install failed!" && return 1; }

        if [[ "$res_name" == "parallel" ]]; then
          timeout 10 parallel --citation <<< "will cite" &>/dev/null
        fi
      else
        _logger info "$res_name rpm is already installed."
      fi
      ;;
    # get download resoures
    download)
      cd $res_parent_path
      if [[ -z $(ls -A $res_parent_path ) ]] &>/dev/null; then
        _logger warn "No local $res_name resource detected, try to get"

        # offline get download resources from nodes's $res_parent_path
        for ip in "${!ip2host[@]}"; do
          if ssh "$USER@$ip" "[[ -n \"\$(ls -A $res_parent_path)\" ]] &>/dev/null"; then
            _logger info "$res_name for ${ip2host[$ip]}, pulling ..."
            scp -r $USER@$ip:$res_parent_path $(dirname $res_parent_path)
            break
          else
            _logger warn "no $res_name rpm detected in ${ip2host[$ip]}."
          fi
        done

        # online get download resources to node local $res_parent_path
        if [[ -z $(ls -A $res_parent_path) ]] &>/dev/null; then
          _remote_get_resource rpm wget $offline_pkg_path/rpm/wget -q
          _logger warn "No $res_name detected on any nodes, try to download with wget ..."
          for url in ${res_url_list[@]}; do
            if ! wget --progress=bar -c "$url" -P $res_parent_path; then
              read -rp "Download failed. Connection to GitHub is unstable. Upload manually? (y/n): " answer
              [[ "$answer" =~ ^[Yy]$ ]] && { which rz || _remote_get_resource rpm lrzsz $offline_pkg_path/rpm/lrzsz -q; } && rz -y
            fi
          done
        fi

        [[ -n $(ls -A $res_parent_path ) ]] &>/dev/null || { \
          _logger error "Failed to get $res_name. Please manually place it at $res_parent_path and rerun the script." && \
          return 1; }
      else
        _logger info "$res_name already exists in $res_parent_path."
      fi
      ;;
    # get image resoures
    image)
      cd $res_parent_path
      if [[ ! -f $img_file ]]; then
        _logger warn "No local $res_name offline image package detected, try to get ..."

        # offline get image resources from nodes's $res_parent_path
        for ip in "${!ip2host[@]}"; do
          if ssh "$USER@$ip" "test -f $img_file 2>/dev/null"; then
            _logger info "$res_name offline image package for ${ip2host[$ip]}, pulling and loading ..."
            scp $USER@$ip:$img_file $res_parent_path
            break
          else
            _logger warn "no $res_name offline image package in $ip(${ip2host[$ip]})."
          fi
        done
      fi

      if [[ -f $img_file ]]; then
        nerdctl -n $ns load -i "$img_file"
      else

        # online get image resources
        _logger warn "No $res_name offline image package detected on any nodes, try pulling online ..."

        while [[ $img_count -ne ${#res_img_list[@]} ]] && [[ $retries -lt $max_retries ]]; do
          _remote_get_resource rpm parallel $offline_pkg_path/rpm/parallel -q >/dev/null && cd $res_parent_path
          parallel -j 4 --tag --progress "nerdctl -n $ns pull -q {}" ::: "${res_img_list[@]}" || true

          img_count=0
          for img in ${res_img_list[@]}; do
            if nerdctl -n $ns images --names | grep "$img" &>/dev/null; then
              img_count=$((img_count + 1))
            fi
          done

          if [[ $img_count -ne ${#res_img_list[@]} ]]; then
            _logger warn "image get failed, retrying ... ($((retries + 1))/$max_retries)"
            retries=$((retries + 1))
            sleep 3
          fi
        done

        # save image resources to node local $res_parent_path
        if [[ $img_count -eq ${#res_img_list[@]} ]]; then
          _logger info "The image for $res_name has been obtained."
          nerdctl -n $ns save -o ${res_name}_imgs.tar.gz ${res_img_list[@]}
        else
          _logger error "Failed to obtain the image for ${res_name}. "
          read -rp "Upload ${res_name}_imgs.tar.gz manually and load? (y/n): " answer
          if [[ "$answer" =~ ^[Yy]$ ]]; then
            which rz || { _remote_get_resource rpm lrzsz $offline_pkg_path/rpm/lrzsz -q && cd $res_parent_path; }
            rz -y
            _remote_get_resource image $res_name $res_parent_path ${res_img_list[@]}
          fi
        fi
      fi
      ;;
    *)
      _logger error "Unknown resource type: $res_type"
      return 2
      ;;
    esac
}


#############################################################################
## Function: _remote_dist
## Overview: General remote resource distribution function.
## Description:
##   Distribute specified resources to remote target nodes.
##
## Parameters:
##   - $1: exclude_ip
##   - ${@:2}: resource_paths
##
## Returns:
##   -  0: Success (distribute corresponding resources successfully)
##   - !0: Failure (...)
##
## Example:
##   exclude_ip="$INIT_NODE_IP"
##   resource_paths=(
##     "$offline_pkg_path/rpm/lrzsz"
##     "$offline_pkg_path/rpm/sshpass"
##     "$offline_pkg_path/rpm/parallel"
##   )
##
##   # chk args
##   _remote_get_ip2host
##   _remote_dist "$exclude_ip" "${resource_paths[@]}"
#############################################################################
function _remote_dist() {
  local exclude_ip="$1"
  local -a resource_paths=("${@:2}")

  _remote_get_resource rpm parallel $offline_pkg_path/rpm/parallel -q >/dev/null

  _logger info "Will execute on remote nodes. Parallel execution is enabled by default."

  _print_line split -
  _logger info "Parallel execution will be used this time ..."

  # construct the command string to be executed
  local cmd=""
  for path in "${resource_paths[@]}"; do
    cmd+="ssh -o BatchMode=yes -o ConnectTimeout=5 '$USER@{}' \"mkdir -p $(dirname $path)\" && "
    if [[ -d "$path" ]]; then
      cmd+="scp -r -o BatchMode=yes -o ConnectTimeout=5 '$path' '$USER@{}:$path' && "
    elif [[ -f "$path" ]]; then
      cmd+="scp -o BatchMode=yes -o ConnectTimeout=5 '$path' '$USER@{}:$path' && "
    fi
    cmd+="echo -e \"$path copied to {}\" && "
  done
  # remove the last redundant "&&"
  cmd=${cmd%&& }
  cmd+=" && ssh -o BatchMode=yes -o ConnectTimeout=5 '$USER@{}' \"ls -lh ${resource_paths[*]}\""

  # filter out the excluded ip from the list of ips
  local -a filtered_ips=()
  for ip in "${!ip2host[@]}"; do
    if [[ "$ip" != "$exclude_ip" ]]; then
      filtered_ips+=("$ip")
    fi
  done

  parallel -j 0 --tag --line-buffer --halt now,fail=1 "$cmd" ::: "${filtered_ips[@]}"
}

#############################################################################
## Function: _remote_parallel
## Overview: General remote execution function.
## Description:
##   Distribute and execute specified scripts in parallel on remote nodes.
##
## Parameters:
##   - $1: parallel/sequential
##   - $2: remote_script_path
##   - $3: exclude_ip
##   - ${env_vars[@]}: view the corresponding definitions in the function
##   - --
##   - ${script_args[@]}: view the corresponding definitions in the function
##
## Returns:
##   - 0: Success (distribute corresponding resources successfully)
##   - 2: Failure (...)
##
## Example:
##   scp_script_path="xxx"
##   exclude_ip="xxx"
##   local -a env_vars=(ip2host INIT_NODE_IP DASHBOARD_TOKEN join_cmds tag)
##   local -a script_args=("$@")
##
##   _remote_parallel parallel "$scp_script_path" "$exclude_ip" "${env_vars[@]}" -- "${script_args[@]}"
#############################################################################
function _remote_parallel() {
  local execution_mode="$1"
  local remote_script_path="$2"
  local remote_script_name="$(basename "$remote_script_path")"
  local exclude_ip="$3"
  shift 2
  local -a env_vars=()
  local -a script_args=()
  local separator_found=false

  > /tmp/${tag}_var
  # handle color variables separately
  tee >> /tmp/${tag}_var <<-EOF
# Define color codes
red="\033[1;31m"
green="\033[1;32m"
yellow="\033[1;33m"
blue="\033[1;36m"
gray="\033[1;90m"
reset="\033[0m"
EOF
  # handle array variable splitting
  for param in "$@"; do
    if [[ "$param" == "--" ]]; then
      separator_found=true
      continue
    fi
    if [[ "$separator_found" = false ]]; then
      env_vars+=("$param")
    else
      script_args+=("$param")
    fi
  done

  # handler env_vars
  for var in "${env_vars[@]}"; do
    [[ -n $var ]] || continue
    declare -p $var &>/dev/null || continue
    echo "$(declare -p $var 2>/dev/null)" >> /tmp/${tag}_var
  done

  _remote_get_resource rpm parallel $offline_pkg_path/rpm/parallel -q >/dev/null

  # execute scripts
  _logger info "Parallel execution: Faster deployment, but terminal output may be mixed. Suitable for many remote nodes.
Sequential execution: View each node's process in order. Suitable for few nodes or first-time runs."

  case $execution_mode in
    parallel)
      _logger info "Parallel execution will be used this time ..."
      parallel -j 0 --tag --line-buffer --halt now,fail=1 '
        if [[ "{}" != '$exclude_ip' ]]; then
          scp -o BatchMode=yes -o ConnectTimeout=5 '/tmp/${tag}_var' '$USER@{}:/tmp/' && echo -e "Env vars copied to {}"
          scp -o BatchMode=yes -o ConnectTimeout=5 '$remote_script_path' '$USER@{}:' && echo -e "Script copied to {}"
          ssh -o BatchMode=yes -o ConnectTimeout=5 '$USER@{}' "export TERM=xterm-256color; bash '/tmp/${tag}_var' && \
            bash '$remote_script_name' '${script_args[@]}' && rm -rf '$remote_script_name'"
        fi
      ' ::: "${!ip2host[@]}"
      ;;
    sequential)
      _logger info "Sequential execution will be used this time ..."
      for ip in "${!ip2host[@]}"; do
        if [[ "$ip" != "$exclude_ip" ]]; then
          scp -o BatchMode=yes -o ConnectTimeout=5 "/tmp/${tag}_var" "$USER@$ip:/tmp/" && echo -e "Env vars copied to ${ip2host[$ip]} ($ip)"
          scp -o BatchMode=yes -o ConnectTimeout=5 "$remote_script_path" "$USER@$ip:$HOME/" && echo "script copied to ${ip2host[$ip]} ($ip)"
          ssh -o BatchMode=yes -o ConnectTimeout=5 "$USER@$ip" "export TERM=xterm-256color; bash /tmp/${tag}_var && bash $remote_script_name \
            ${script_args[@]} && rm -rf $remote_script_name"
        fi
      done
      ;;
    *)
      _logger error "$execution_mode is an invalid remote execution mode and will exit."
      return 2
      ;;
  esac
}
