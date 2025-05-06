#!/usr/bin/env bash
############################## usage #######################################
# tag="xx_cluster"
# script_path="$(dirname ${BASH_SOURCE[0]})"
#
# # import some define
# source "$script_path/../00_utils/_print.sh"
# source "$script_path/../00_utils/_trap.sh"
# source "$script_path/../00_utils/_logger.sh"
# source "$script_path/../00_utils/_remote.sh"
#
# # Provide an override entry for environment variables for remote execution
# source /tmp/${tag}_var &>/dev/null || true
#
# function plan_nodes() {
#   # plan cluster nodes, configure SSH passwordless, update hostnames
#   _remote_ssh_passfree config "$tag"
#
#   # get ips and hosts save to ${!ip2host[@]}
#   _remote_get_ip2host
#
#   # obtain the IP address of the initialization node
#   INIT_NODE_IP="$SRV_IP"
# }
#
# function remote_dist() {
#   local -a resource_paths=(
#     "/root/$dep_script"
#     "$offline_pkg_path/rpm/lrzsz"
#     "$offline_pkg_path/rpm/sshpass"
#     "$offline_pkg_path/rpm/parallel"
#   )
#   local exclude_ip="$INIT_NODE_IP" # Define remote machines to exclude from the loop
#
#   _print_line title "Parallel remote execution"
#
#   # chk args
#   _remote_get_ip2host
#
#   if [[ ${#ip2host[@]} -eq 0 ]]; then
#     _logger error "The remote host IP list is empty, please run the $script_path at least once."
#     exit 1
#   fi
#
#   cp $workdir/$dep_script /root/$dep_script
#   echo -e "rm -- "/root/\$0"" >> /root/$dep_script
#   _remote_dist "$exclude_ip" "${resource_paths[@]}"
# }
#
# function remote_parallel() {
#   local scp_script_path=$abs_script_path
#   local exclude_ip="$INIT_NODE_IP" # Define remote machines to exclude from the loop
#   local -a env_vars=(ip2host INIT_NODE_IP DASHBOARD_TOKEN join_cmds tag)
#   local -a script_args=("$@")
#
#   _print_line title "Parallel remote execution"
#
#   # chk args
#   if grep -q -E '^source[[:space:]]+\"?[^[:space:]]+\.sh\"?' "$scp_script_path"; then
#     _logger error "Remote script contains external dependencies, cannot execute on remote nodes."
#     _logger error "Please generate a complete independent script first by run ${blue}bash build.sh gr $(basename $scp_script_path)"
#     exit 1
#   fi
#
#   _remote_get_ip2host
#
#   [[ ${#ip2host[@]} -eq 0 ]] && { \
#     _logger error "The remote host IP list is empty, please run the $scp_script_path at least once." && exit 1; }
#
#   _remote_parallel "$scp_script_path" "$exclude_ip" "${env_vars[@]}" -- "${script_args[@]}"
# }
############################## usage #######################################

# The dependencies will be imported by the functional script itself to avoid duplication and conflicts here.
# script_path="$(dirname ${BASH_SOURCE[0]})"
# import some define
# source "$script_path/_print.sh"
# source "$script_path/_logger.sh"

# define golabal variables
SRV_IP="$(ip -4 addr show | grep inet | grep -v 127.0.0.1 | awk 'NR==1 {print $2}' | cut -d'/' -f1)"

#############################################
#### Remote passwordless setup
#############################################

function _remote_install_rpms() {
  local dep="$1"
  local offline_pkg_path="$(find /usr/local/src/ -type d -name $dep)"
  local add_repo="$2"
  local quiet="${@: -1}" && [[ "$quiet" == "-q" ]] || quiet=""

  if [[ $add_repo == "epel" ]] && ! dnf repolist | grep epel 2>/dev/null; then
    cat > /etc/yum.repos.d/epel.repo <<-EOF
[epel]
name=Extra Packages for Linux \$releasever - \$basearch
baseurl=https://mirrors.aliyun.com/epel/\$releasever/Everything/\$basearch/
gpgcheck=1
enabled=1
gpgkey=https://mirrors.aliyun.com/epel/RPM-GPG-KEY-EPEL-\$releasever
EOF
  fi

  if ! rpm -q "$dep" &>/dev/null; then
    if [[ -n "$offline_pkg_path" && -n "$(ls -A "$offline_pkg_path")" ]]; then
      # rpm -Uvh --force --nodeps $quiet $offline_pkg_path/*.rpm
      dnf install -y $quiet $offline_pkg_path/*.rpm 2>/dev/null
    else
      dnf install -y $quiet $dep
    fi
  fi

  if [[ "$dep" == "parallel" ]]; then
    timeout 10 parallel --citation <<< "will cite" &>/dev/null
  fi
}

function _remote_ssh_passfree_config() {
  _print_line title "Plan $tag nodes ip and hostname, configure ssh passwordfree"

  _logger info "1. Get the list of IP addresses and hostnames from user input"
  echo -e "${green}Enter IPs and hostnames, one per line, an empty line completes the input, example:"
  echo -e "${gray}192.168.85.121 server-01\n192.168.85.122 server-02\n192.168.85.123 server-03${reset}"

  while true; do
    read -p "" line
    [[ -z $line ]] && break

    ip=$(echo "$line" | awk '{print $1}')
    hostname=$(echo "$line" | awk '{print $2}')
    ip2host["$ip"]="$hostname"
  done

  if [[ -z "${ip2host[$SRV_IP]}" ]]; then
    _logger error "If the primary network card's IP is not in the cluster nodes, the installation will exit."
    exit 1
  fi

  _logger info "2. Get and identify the host for one-way password-free login"

  declare -a matched_one_way_hosts

  while true; do
    echo -e "${green}Please enter the hostname of the host that only allows one-way password-free login to other hosts,"
    printf "${green}(e.g., ${red}master/controller${green}) [Enter for none]: ${reset}"
    read -p "" one_way_host_str
    echo

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
  _remote_install_rpms sshpass -q >/dev/null

  while true; do
    printf "Ensure all servers have ${red}the same password ${reset}and enter it: "
    read -rsp "" srv_passwd
    echo

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

  _print_line split blank
  _logger info "3. Start configuring password-free SSH login"

  # Generate a ssh key pair
  _logger info "3.1 Start generate a ssh key pair"

  for ip in "${!ip2host[@]}"; do
    sshpass -p "$srv_passwd" ssh -q -o StrictHostKeyChecking=no -o LogLevel=QUIET "$ip" <<-EOF
mkdir -p ${HOME}/.ssh
[[ -f ${private_key_file} ]] || ssh-keygen -t ed25519 -b 4096 -N '' -f ${private_key_file} -q
EOF
  # Collect the public key from current node
  ssh_keys[$ip]=$(sshpass -p "$srv_passwd" ssh -q -o StrictHostKeyChecking=no -o LogLevel=QUIET "$ip" "cat ${public_key_file}")
  done

  # Add hosts and authorized_key
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

  # Add known_hosts
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

  [[ $conn_status -eq 1 ]] ||  exit 1

  _print_line split blank
  # update hostname
  _logger info "4. Start update hostname on the remote host"

  read -p "Sync setting hostname on each node? (y/n) [Enter for y]: " answer
  answer=${answer:-"y"}
  [[ "$answer" =~ ^[Yy]$ ]] || { _logger error "User cancelled, exiting..." && exit 1; }
  for ip in "${!ip2host[@]}"; do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "$USER@$ip" "hostnamectl set-hostname ${ip2host[$ip]}"; then
      echo -e "${green}Hostname updated successfully on ${ip2host[$ip]} ($ip).${reset}"
    else
      echo -e "${red}Failed to update hostname on ${ip2host[$ip]} ($ip).${reset}"
    fi
  done

  _print_line split -
  _logger info "SSH passwordless login configuration succeeded!\n"
}

function _remote_ssh_passfree_undo() {
  # clear ssh passfree
  sed -i "/$tag/d" ${auth_key_file} ${known_hosts_file}
  # clear hosts
  sed -i "/# $tag ssh passfree start/,/# $tag ssh passfree end/d" /etc/hosts

  _print_line split -
  _logger info "SSH passwordless login has been successfully undone!\n"
}

function _remote_ssh_passfree() {
  local tag=$2
  local -A ip2host
  local -A ssh_keys
  local private_key_file="${HOME}/.ssh/id_ed25519"
  local public_key_file="${HOME}/.ssh/id_ed25519.pub"
  local auth_key_file="${HOME}/.ssh/authorized_keys"   # About who can connect to me
  local known_hosts_file="${HOME}/.ssh/known_hosts"    # About who I have connected to

  case $1 in
    config)
      shift
      _remote_ssh_passfree_config
      ;;
    undo)
      shift
      _remote_ssh_passfree_undo
      ;;
    *)
      printf "Invalid option $*\n"
      printf "${green}Usage: ${reset}\n"
      printf "    ${green}$FUNCNAME config${gray}/undo xx-cluster${reset}\n"
      exit 1
      ;;
  esac
}


#############################################
#### Remote metadata retrieval
#############################################

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


#############################################
#### Remote execution
#############################################

function _remote_dist() {
  local exclude_ip="$1"
  shift
  local -a resource_paths=("$@")

  _remote_install_rpms parallel epel -q

  _logger info "Will execute on remote nodes. Parallel execution is enabled by default."

  _print_line split -
  _logger info "Parallel execution will be used this time ..."

  # Construct the command string to be executed
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

  # Filter out the excluded IP from the list of IPs
  local -a filtered_ips=()
  for ip in "${!ip2host[@]}"; do
    if [[ "$ip" != "$exclude_ip" ]]; then
      filtered_ips+=("$ip")
    fi
  done

  parallel -j 0 --tag --line-buffer --halt now,fail=1 "$cmd" ::: "${filtered_ips[@]}"
}

function _remote_get_resource() {
  local res_type="$1"  # rpm/download/image
  local res_name="$2"
  local res_parent_path="$3"
  [[ $res_type == "rpm" ]] && \
    local add_repo="$4"
    local quiet="${@: -1}" && [[ "$quiet" == "-q" ]] || quiet=""
  [[ $res_type == "download" ]] && \
    local res_url_list=("${@:4}") && \
    local timeout_s=300
  [[ $res_type == "image" ]] && \
    local ns="$4"
    local res_img_list=("${@:5}") && \
    local img_file="$res_parent_path/${res_name}_imgs.tar.gz" && \
    local img_count=0 && \
    local retries=0
  local max_retries=3

  mkdir -p $res_parent_path && cd $_
  case $res_type in
    rpm)
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

        if [[ -z $(ls -A $res_parent_path 2>/dev/null) ]]; then
          for ip in "${!ip2host[@]}"; do
            if ssh "$USER@$ip" "[[ -n \"\$(ls -A $res_parent_path 2>/dev/null)\" ]]"; then
              _logger info "$res_name rpm for ${ip2host[$ip]}, pulling and installing ..."
              scp -r $USER@$ip:$res_parent_path $res_parent_path
              break
            else
              _logger warn "no $res_name rpm detected in ${ip2host[$ip]}."
            fi
          done
        else
          _logger info "Detected existing $res_name rpm package locally, it will be used for install."
        fi

        if [[ -z $(ls -A $res_parent_path 2>/dev/null) ]]; then
          _logger warn "No $res_name rpm detected on any nodes, try online install with dnf."
          dnf install -y $quiet $res_name --downloadonly --downloaddir=$res_parent_path
        fi

        # rpm -Uvh --force --nodeps $quiet $res_parent_path/*.rpm || true
        dnf install -y $quiet $res_parent_path/*.rpm 2>/dev/null || { _logger error "$res_name rpm install failed!" && exit 1; }

      else
        _logger info "$res_name rpm is already installed."
      fi
      ;;
    download)
      if [[ -z $(ls -A $res_parent_path 2>/dev/null) ]]; then
        _logger warn "No local $res_name resource detected, try to get"

        for ip in "${!ip2host[@]}"; do
          if ssh "$USER@$ip" "[[ -n \"\$(ls -A $res_parent_path 2>/dev/null)\" ]]"; then
            _logger info "$res_name for ${ip2host[$ip]}, pulling ..."
            scp -r $USER@$ip:$res_parent_path $res_parent_path
            break
          else
            _logger warn "no $res_name rpm detected in ${ip2host[$ip]}."
          fi
        done

        if [[ -z $(ls -A $res_parent_path 2>/dev/null) ]]; then
          _logger warn "No $res_name detected on any nodes, try to download with wget, timeout limit: $timeout_s seconds ..."
          for url in ${res_url_list[@]}; do
            if ! timeout $timeout_s wget -c "$url" -P $res_parent_path &>/dev/null; then
              read -rp "Download failed. Connection to GitHub is unstable. Upload manually? (y/n): " answer
              [[ "$answer" =~ ^[Yy]$ ]] && { which rz || _remote_install_rpms lrzsz -q; } && rz -y
            fi
          done
        fi

        [[ -n $(ls -A $res_parent_path 2>/dev/null) ]] || { \
          _logger error "Failed to get $res_name. Please manually place it at $res_parent_path and rerun the script." && \
          exit 1; }
      else
        _logger info "$res_name already exists in $res_parent_path."
      fi
      ;;
    image)
      if [[ ! -f $img_file ]]; then
        _logger warn "No local $res_name offline image package detected, try to get ..."

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
        _logger warn "No $res_name offline image package detected on any nodes, try pulling online ..."

        while [[ $img_count -ne ${#res_img_list[@]} ]] && [[ $retries -lt $max_retries ]]; do
          _remote_install_rpms parallel epel -q
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

        if [[ $img_count -eq ${#res_img_list[@]} ]]; then
          _logger info "The image for $res_name has been obtained."
          nerdctl -n $ns save -o $res_name.tar.gz ${res_img_list[@]}
        else
          _logger error "Failed to obtain the image for ${res_name}. "
          read -rp "Upload ${res_name}_imgs.tar.gz manually and load? (y/n): " answer
          if [[ "$answer" =~ ^[Yy]$ ]]; then
            which rz || _remote_install_rpms lrzsz -q
            rz -y
            _remote_get_resource "image" "$res_name" "$res_parent_path" "${res_img_list[@]}"
          fi
        fi
      fi
      ;;
    *)
      _logger error "Unknown resource type: $res_type"
      exit 2
      ;;
    esac
}


function _remote_parallel() {
  local remote_script_path="$1"
  local remote_script_name="$(basename "$remote_script_path")"
  local exclude_ip="$2"
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

  _remote_install_rpms parallel epel -q

  _logger info "Parallel execution: Faster deployment, but terminal output may be mixed. Suitable for many remote nodes.
Sequential execution: View each node's process in order. Suitable for few nodes or first-time runs."

  read -rp "Will execute on remote nodes. Enable parallel execution? (y/n) [Enter 'y' by default]: " answer
  answer=${answer:-y}
  _print_line split -

  if [[ "$answer" =~ ^[Yy]$ ]]; then
    _logger info "Parallel execution will be used this time ..."
    parallel -j 0 --tag --line-buffer --halt now,fail=1 '
      if [[ "{}" != '$exclude_ip' ]]; then
        scp -o BatchMode=yes -o ConnectTimeout=5 '/tmp/${tag}_var' '$USER@{}:/tmp/' && echo -e "Env vars copied to {}"
        scp -o BatchMode=yes -o ConnectTimeout=5 '$remote_script_path' '$USER@{}:' && echo -e "Script copied to {}"
        ssh -o BatchMode=yes -o ConnectTimeout=5 '$USER@{}' "export TERM=xterm-256color; bash '/tmp/${tag}_var' && \
          bash '$remote_script_name' '${script_args[@]}' && rm -rf '$remote_script_name'"
      fi
    ' ::: "${!ip2host[@]}"
  else
    _logger info "Sequential execution will be used this time ..."
    for ip in "${!ip2host[@]}"; do
      if [[ "$ip" != "$exclude_ip" ]]; then
        scp -o BatchMode=yes -o ConnectTimeout=5 "/tmp/${tag}_var" "$USER@$ip:/tmp/" && echo -e "Env vars copied to ${ip2host[$ip]} ($ip)"
        scp -o BatchMode=yes -o ConnectTimeout=5 "$remote_script_path" "$USER@$ip:$HOME/" && echo "script copied to ${ip2host[$ip]} ($ip)"
        ssh -o BatchMode=yes -o ConnectTimeout=5 "$USER@$ip" "export TERM=xterm-256color; bash /tmp/${tag}_var && bash $remote_script_name \
          ${script_args[@]} && rm -rf $remote_script_name"
      fi
    done
  fi
}
