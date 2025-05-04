#!/usr/bin/env bash
# https://www.elastic.co/guide/en/elasticsearch/reference/current/targz.html
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
  ip2host SRV_IP INIT_NODE_IP ES_VER ES_URL ES_HOME CLUSTER_NAME ES_CONF DISCOVER_SEEDS TOKEN passwd
' ERR

# define golabal variables
SRV_IP="$(ip -4 addr show | grep inet | grep -v 127.0.0.1 | awk 'NR==1 {print $2}' | cut -d'/' -f1)"
INIT_NODE_IP=""
declare -A ip2host
ES_VER="${3:-8.15.3}"
ES_HOME="${4:-/usr/local/elasticsearch}"
ES_CONF="$ES_HOME/config/elasticsearch.yml"
CLUSTER_NAME="${5:-my-es-cluster}"
DISCOVER_SEEDS=""
TOKEN=""
tag="es_cluster"

#######################################
## Main Business Logic Begins
#######################################

# Provide an override entry for environment variables for remote execution
source /tmp/${tag}_var &>/dev/null || true

function plan_nodes() {
  # plan cluster nodes, configure SSH passwordless, update hostnames
  _remote_ssh_passfree config "$tag"

  # get ips and hosts save to ${!ip2host[@]}
  _remote_get_ip2host

  # obtain the IP address of the initialization node
  INIT_NODE_IP="$SRV_IP"
}

function install() {
  _print_line title "Install elastic search"

  [[ -z $(ls -A $ES_HOME 2>/dev/null) ]] || { _logger error "Elasticsearch already installed on the system." && exit 1; }

  _logger info "1. Adjust system environment configuration"
  _logger info "1.1 Configure clock source and immediately synchronize time"
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

  _logger info "Immediately jump to the current time and force correction of historical errors and verifying sync status"
  chronyc -a makestep
  chronyc sources -v

  _logger info "1.2 Modify file open limits"
  tee /etc/security/limits.d/elastic.conf <<-EOF
*    soft    nofile  65535
*    hard    nofile  131070
*    hard    nproc   8192
EOF

  _logger info "1.3 Increase Linux's limit on the number of VMA (Virtual Memory Area) per process"
  tee /etc/sysctl.d/elastic.conf <<-EOF
vm.swappiness=1
vm.max_map_count=524288
EOF
  sysctl -f /etc/sysctl.d/elastic.conf

  _logger info "2 Install Elasticsearch cluster via tar.gz package"
  ES_PKG_PREFIX="elasticsearch-${ES_VER}-linux-x86_64"
  ES_URL="https://artifacts.elastic.co/downloads/elasticsearch/${ES_PKG_PREFIX}.tar.gz"

  _logger info "2.1 Download and extract"
  cd /usr/local/src/
  if [[ ! -f ${ES_PKG_PREFIX}.tar.gz ]]; then
    which shasum &>/dev/null || { _logger info "shasum package not found. Installing now ..." && dnf install -qy perl-Digest-SHA; }
    wget -c $ES_URL && wget -c ${ES_URL}.sha512 && shasum -a 512 -c ${ES_PKG_PREFIX}.tar.gz.sha512 || {
      _logger error "Failed to download ${ES_PKG_PREFIX}.tar.gz."
      exit 1
    }
  else
      _logger warn "Detected and using local package: /usr/local/src/${ES_PKG_PREFIX}.tar.gz"
  fi
  tar -xzf ${ES_PKG_PREFIX}.tar.gz -C /usr/local
  mv /usr/local/elasticsearch-$ES_VER $ES_HOME
  ls -ld $ES_HOME/*

  _logger info "2.2 Create necessary user and directories, update permissions and PATH"
  # official default does not allow running as root
  id elastic 2>/dev/null || useradd elastic -d $ES_HOME -s /bin/bash
  chown -R elastic:elastic $ES_HOME

  echo "export ES_HOME=$ES_HOME" >> /etc/profile
  echo "export PATH=\$PATH:\$ES_HOME/bin" >> /etc/profile
  # source /etc/profile   # Avoid potential issues from erroneous environment variables
  export ES_HOME=$ES_HOME
  export PATH=$PATH:$ES_HOME/bin
  echo -e "PATH: $PATH"

  _logger info "3. Initialize configuration"
  _logger info "3.1 Update $ES_CONF"
  su - elastic -c "[[ -f $ES_CONF ]] && cp -fv $ES_CONF ${ES_CONF}_$(date +'%Y%m%d-%H%M').bak"
  su - elastic -c "tee $ES_CONF <<-EOF
cluster.name: '$CLUSTER_NAME'
node.name: $(hostname -s)
node.roles: [master, data, transform, remote_cluster_client]
path.data: $ES_HOME/data
path.logs: $ES_HOME/logs
network.host: 0.0.0.0
http.port: 9200
transport.port: 9300
EOF"

  _logger info "3.2 Adjust ES JVM heap memory size for learning/mentation scenarios ..."
  local total_mem=$(free -m | awk 'NR==2{print $2}')
  local half_mem=$(( (total_mem + 1) / 2 ))
  local jvm_options_file="$ES_HOME/config/jvm.options.d/head.options"

  su - elastic -c "
  [[ -f $jvm_options_file ]] && cp -fv $jvm_options_file ${jvm_options_file}.bak
  tee $jvm_options_file <<-EOF
-Xms${half_mem}m
-Xmx${half_mem}m
EOF
    "

  _logger info "4. Check and open the corresponding firewall ports"
  if systemctl status firewalld | grep "active (running)" &>/dev/null; then
    firewall-cmd --add-port={9200,9300}/tcp --permanent &>/dev/null
    firewall-cmd --reload &>/dev/null
    echo -e "Current open ports in the firewall: ${green}$(firewall-cmd --list-port)${reset}"
  else
    _logger warn "System firewalld is currently disabled."
  fi
}

function auto_config_certs() {
  _print_line title "First start, auto-configure security certificates and settings"

  su - elastic -c "elasticsearch -d"
  cat $ES_CONF
  echo -e "\nThe path for automatically configured certificates is: \n$ES_HOME/config/certs/"
  ls -ld $ES_HOME/config/certs/*
}

function update_es_pwd() {
  _print_line title "Manual update ES cluster default password by elasticsearch-reset-password tool"
  
  [[ -n $INIT_NODE_IP ]] || read -rp "The IP address of the seed node is empty, please enter it manually: " INIT_NODE_IP
  while true; do
    ssh "$INIT_NODE_IP" "su - elastic -c 'elasticsearch-reset-password -u elastic --interactive'"
    if [[ $? -eq 0 ]]; then break; fi
  done
  passwd=""
}

function _api_test() {
  _logger info "Test connecting to the ES cluster from this machine via API"

  local conn_status=0
  local retry_times=0
  while [[ $conn_status -eq 0 ]]; do
    retry_times=$((retry_times + 1))
    [[ -n $passwd ]] || read -p "Enter the password for the Elasticsearch user 'elastic': " passwd
    echo
    if curl -X GET -u elastic:"$passwd" -k https://${SRV_IP}:9200/_cat/nodes?v 2>/dev/null; then
      _logger info "API interface connection successful, password verification ok."
      conn_status=1
    else
      if [[ $retry_times -gt 3 ]]; then
        _logger error "Retry attempts have reached 3 times, will automatically invoke the password reset tool."
        update_es_pwd
        retry_times=0
      else
        _logger error "Failed to connect to elastic cluster, please enter the correct password."
      fi
    fi
  done
}

function join_cluster() {
  _print_line title "Obtain the cluster token and join the cluster (Current machine: $(hostname))"

  local token=$(ssh $USER@$INIT_NODE_IP "su - elastic -c 'elasticsearch-create-enrollment-token -s node'")
  _logger info "Obtain es cluster token from init node (Expires after 30 minutes): \n${red}$token"

  su - elastic -c "elasticsearch -d --enrollment-token $token" && sleep 3

  _logger info "Node joined cluster, verify node status."
  _api_test
}

function update_node_discovery() {
  _print_line title "Update node discovery configuration to enable normal communication and election"

  # chk args
  _remote_get_ip2host
  if [[ ${#ip2host[@]} -eq 0 ]]; then
    _logger info "Detected a single-node installation outside the cluster."
    _logger info "Start synchronizing and updating the ${blue}discovery.seed_hosts${green} list."

    discover_seeds=$(ssh "$INIT_NODE_IP" "grep '^discovery.seed_hosts:' $ES_CONF" | sed -n 's/^discovery.seed_hosts: \[\(.*\)\]/\1/p')
    [[ -n $discover_seeds ]] || { _logger error "Failed to read discovery.seed_hosts from remote machine." && exit 1; }
    if [[ "$discover_seeds" != *"$SRV_IP"* ]]; then
        discover_seeds="$discover_seeds, \"$SRV_IP\""
    fi
    
    ssh "$INIT_NODE_IP" "sed -i 's/^discovery.seed_hosts:.*/discovery.seed_hosts: [$discover_seeds]/' $ES_CONF"
    _logger info "${blue}discovery.seed_hosts ${green}}has been updated on remote machines."
  else
    for ip in ${!ip2host[@]}; do
      discover_seeds+="\"$ip\","
    done
    discover_seeds=${discover_seeds%,}  # remove the last unnecessary comma
  fi

  su - elastic -c "
    sed -i -e '/cluster.initial_master_nodes/d' \
      -e '/^# Discover existing nodes/d' \
      -e '/discovery.seed_hosts/d' $ES_CONF && \
    tee -a $ES_CONF <<-EOF

# Discover existing nodes in the cluster
discovery.seed_hosts: [$discover_seeds]
EOF
    "
  _logger info "${blue}discovery.seed_hosts ${green}has been updated on local machines."
}

function systemd_autostart() {
  _print_line title "Use systemd to manage services, set ES to start on boot, and open firewall ports"

  _logger info "2. Create elasticsearch service unit file and enable"
  tee /etc/systemd/system/elasticsearch.service <<-EOF
[Unit]
Description=Elasticsearch Service
After=network.target

[Service]
Type=simple
User=elastic
Group=elastic
ExecStart=$ES_HOME/bin/elasticsearch
ExecStop=/bin/kill -s QUIT $MAINPID
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  systemctl restart elasticsearch && systemctl status --no-pager $_ && systemctl enable $_
  sleep 3
    
  _logger info "Cluster Token (Expires after 30 minutes): \n${red}$token"
  _logger info "Cluster Status: "
  _api_test

  _print_line split -
  _logger info "The ElasticSearch Cluster has been installed successfully."
  echo -e "${green}You can run the following command to validate:"
  echo -e "${yellow}    curl -X GET -u elastic:${passwd} -k https://$SRV_IP:9200/_cat/nodes?v${reset}"
}

function remote_dist() {
  local -a resource_paths=(
    "/usr/local/src/${ES_PKG_PREFIX}.tar.gz"
    "/usr/local/src/${ES_PKG_PREFIX}.tar.gz.sha512"
  )
  local exclude_ip="$INIT_NODE_IP" # Define remote machines to exclude from the loop

  _print_line title "Parallel remote execution"

  # chk args
  _remote_get_ip2host
  
  if [[ ${#ip2host[@]} -eq 0 ]]; then
      _logger error "The remote host IP list is empty, please run the $script_path at least once."
      exit 1
  fi

  _remote_dist "$exclude_ip" "${resource_paths[@]}"
}

function remote_parallel() {
  local scp_script_path=$abs_script_path
  local exclude_ip="$INIT_NODE_IP" # Define remote machines to exclude from the loop
  local -a env_vars=(ip2host INIT_NODE_IP ES_VER ES_HOME CLUSTER_NAME tag passwd)
  local -a script_args=("$@")

  _print_line title "Parallel remote execution"

  # chk args
  if grep -q -E '^source[[:space:]]+\"?[^[:space:]]+\.sh\"?' "$scp_script_path"; then
    _logger error "Remote script contains external dependencies, cannot execute on remote nodes."
    _logger error "Please generate a complete independent script first by run ${blue}bash build.sh gr $(basename $scp_script_path)"
    exit 1
  fi
  if [[ ${#ip2host[@]} -eq 0 ]]; then
    # get ips and hosts save to ip2host
    while IFS=' ' read -r ip host; do
      ip2host["$ip"]=$host
    done < <(awk -v tag="$tag" '
      /# '"$tag"' ssh passfree start/ {start=1; next}
      /# '"$tag"' ssh passfree end/ {start=0; next}
      start && !/^#/ && NF > 1 {print $1, $2}
    ' /etc/hosts)
  fi
  [[ ${#ip2host[@]} -eq 0 ]] && { _logger error "The remote host IP list is empty, please run the $scp_script_path at least once." && exit 1; }

  _remote_parallel "$scp_script_path" "$exclude_ip" "${env_vars[@]}" -- "${script_args[@]}"
}


function remove() {
  _print_line title "Remove ES cluster"
    
  # check args
  [[ -d $ES_HOME ]] || { _logger error "Elasticsearch is not installed." && exit 1; }
  [[ -f /tmp/es_inst_var ]] && source /tmp/es_inst_var || _logger warn "This is a single-node cleanup scenario."

  _logger info "1. Check and kill processes ..."
  systemctl is-active --quiet elasticsearch && systemctl stop elasticsearch || true && sleep 3
  while ps -ef | grep "[e]elasticsearch" | grep -v "pts" &>/dev/null; do
    echo -e "${yellow}elasticsearch service is stopping, if necessary, please manually kill: ${red}pkill -9 elasticsearch${reset}"
    sleep 5
  done

  _logger info "2. Delete related files ..."
  rm -rfv $ES_HOME
  rm -rfv /etc/systemd/system/elasticsearch.service && systemctl daemon-reload

  _logger info "3. Delete elastic user"
  id elastic && userdel -r -f elastic

  _logger info "4. Close the corresponding firewall ports"
  if systemctl status firewalld >/dev/null; then
    firewall-cmd --remove-service=elasticsearch --permanent &>/dev/null
    firewall-cmd --reload >/dev/null
    echo -e "Current open ports in the firewall: $(firewall-cmd --list-ports)"
  else
    _logger warn "System firewalld is currently disabled."
  fi

  _logger info "5. Remove the corresponding environment variable"
  sed -i "/ES_HOME/d" /etc/profile

  _logger info "6. Undo ssh login passfree"
  _remote_ssh_passfree undo "$tag"

  _print_line split -
  _logger info "Elasticsearch has been successfully removed.\n"
}


function main() {
  function _help() {
    printf "Invalid option ${@:1}\n"
    printf "${green}Usage: ${reset}\n"
    printf "    ${gray}bash ${blue}$0 ${green}deploy cluster${gray}/node ${gray}8.15.3 /usr/local/elasticsearch es-cluster-name${reset}\n"
    printf "    ${gray}bash ${blue}$0 ${green}remove cluster${gray}/node${reset}\n"
  }

  case "$1-$2" in
    deploy-cluster)
      plan_nodes
      install
      auto_config_certs
      update_es_pwd
      update_node_discovery
      systemd_autostart
      time remote_dist
      time remote_parallel deploy node "$ES_VER" "$ES_HOME" "$CLUSTER_NAME"
      ;;
    deploy-node)
      install
      join_cluster
      update_node_discovery
      systemd_autostart
      ;;
    remove-cluster)
      time remote_parallel remove
      ;;
    remove-node)
      remove
      ;;
    *)
      _help ${@:1} && exit 1
      ;;
  esac
}

main ${@:1}
