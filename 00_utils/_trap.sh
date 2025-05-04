#!/usr/bin/env bash
############################## usage #######################################
# script_path="$(dirname ${BASH_SOURCE[0]})"
# abs_script_path="$(realpath "${BASH_SOURCE[0]}")"
# workdir="$(dirname "$abs_script_path")"
#
# source "$script_path/../00_utils/_trap.sh"
#
# trap '_trap_print_env \
#     SRV_IP NGX_VER NGX_HOME NGX_CONF NGX_LISTEN_PORT NGX_COMPILE_OPTS \
#     NGX_ACCESS_URL WEB_ROOT_PATH WEB_DOMAINS ... VAR_NAME
# ' ERR
############################## usage #######################################
set -o errtrace

_trap_print_env() {
  local env_vars=("$@")

  echo -e "\n${red}Error occurred. Printing current environment variables:${reset}"

  for var in "${env_vars[@]}"; do
    echo "$var: ${!var}"  # print variable values using indirect reference
  done
  
  exit 1
}
