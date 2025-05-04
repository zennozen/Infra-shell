#!/usr/bin/env bash
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
  ip2host SRV_IP INIT_NODE_IP ES_VER ES_HOME CLUSTER_NAME ES_CONF DISCOVER_DOMAIN TOKEN passwd
' ERR

# define golabal variables
SRV_IP="$(ip -4 addr show | grep inet | grep -v 127.0.0.1 | awk 'NR==1 {print $2}' | cut -d'/' -f1)"
INIT_NODE_IP=""
declare -A ip2host
HH_HOME="/etc/etc/"
tag="test_cluster"

#######################################
## Main Business Logic Begins
#######################################

# Provide an override entry for environment variables for remote execution
source /tmp/${tag}_var &>/dev/null || true

function plan_nodes() {
  # plan cluster nodes, configure SSH passwordless, update hostnames
  _remote_ssh_passfree config "$tag"

  # get ips and hosts save to ${!ip2host[@]}
  while IFS=' ' read -r ip host; do
    ip2host["$ip"]=$host
  done < <(awk -v tag="$tag" '
    /# '"$tag"' ssh passfree start/ {start=1; next}
    /# '"$tag"' ssh passfree end/ {start=0; next}
    start && !/^#/ && NF > 1 {print $1, $2}
  ' /etc/hosts)

  # obtain the IP address of the initialization node
  INIT_NODE_IP="$SRV_IP"
}

function print() {
  hostname -s
  cat /tmp/${tag}_var
  echo -e "server ip is: $SRV_IP"
  echo -e "init ip is: $INIT_NODE_IP"
}

function remote_parallel() {
  local script_path="$abs_script_path"
  local exclude_ip="$INIT_NODE_IP" # Define remote machines to exclude from the loop
  local -a env_vars=(ip2host SRV_IP INIT_NODE_IP HH_HOME tag)
  local -a script_args=(test "$HH_HOME" node)

  _remote_parallel "$script_path" "$exclude_ip" "${env_vars[@]}" "--" "${script_args[@]}"
}


function main() {
  function _help() {
    printf "Invalid option ${@:1}\n"
    printf "${green}Usage: ${reset}\n"
    printf "    ${gray}bash ${blue}$0 ${green}test${reset}\n"
    printf "    ${gray}bash ${blue}$0 ${green}remote${reset}\n"
  }

  case $1 in
    test)
      print ${@:1}
      ;;
    remote)
      plan_nodes
      remote_parallel
      ;;
    *)
      _help ${@:1} && exit 1 ;;
  esac
}

main ${@:1}
