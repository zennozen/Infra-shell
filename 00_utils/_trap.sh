#!/usr/bin/env bash
############################## import #######################################
# script_path="$(dirname ${BASH_SOURCE[0]})"
# abs_script_path="$(realpath "${BASH_SOURCE[0]}")"
# workdir="$(dirname "$abs_script_path")"
#
# source "$script_path/../00_utils/_trap.sh"
############################## import #######################################
set -o errtrace

#############################################################################
## Function: _trap_print_env
## Overview：General error capture and print variable function. 
## Description:
##   Capture errors and print variable values before exiting. 
##
## Parameters:
##   - $@: Variables name needed for trap value
##
## Returns:
##   - 0: Success (var value printed successfully and exit script)
##
## Example:
##   trap '_trap_print_env \
##     SRV_IP NGX_VER NGX_HOME NGX_CONF NGX_LISTEN_PORT NGX_COMPILE_OPTS \
##     NGX_ACCESS_URL WEB_ROOT_PATH WEB_DOMAINS ... <VAR_NAME>
##   ' ERR
#############################################################################
_trap_print_env() {
  local env_vars=("$@")

  echo -e "\n${red}Error occurred. Printing current environment variables:${reset}"

  for var in "${env_vars[@]}"; do
    echo "$var: ${!var}"  # print variable values using indirect reference
  done
  
  exit 1
}