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
##   Capture errors and print variable values before exiting. This function
##   supports printing values of scalar variables, indexed arrays, and
##   associative arrays using the `declare -p` command.
##
## Parameters:
##   - $@: List of variable names to print
##
## Returns:
##   - 0: Success (var value printed successfully and exit script)
##
## Example:
##   scalar_var="scalar value"
##   indexed_array=("one" "two" "three")
##   declare -A assoc_array=(["key1"]="value1" ["key2"]="value2")
##   trap '_trap_print_env scalar_var indexed_array assoc_array' ERR
##
##   trap '_trap_print_env \
##     SRV_IP NGX_VER NGX_HOME NGX_CONF NGX_LISTEN_PORT NGX_COMPILE_OPTS \
##     NGX_ACCESS_URL WEB_ROOT_PATH WEB_DOMAINS ... <VAR_NAME>
##   ' ERR
#############################################################################
_trap_print_env() {
  local env_vars=("$@")

  echo -e "\n${red}Error occurred. Printing current environment variables:${reset}"

  for var in "${env_vars[@]}"; do
    # Print variable declaration information using declare -p
    # This supports:
    # - Scalar variables (e.g., var="value")
    # - Indexed arrays (e.g., array=("one" "two" "three"))
    # - Associative arrays (e.g., declare -A assoc_array=(["key1"]="value1" ["key2"]="value2"))
    declare -p "$var" 2>/dev/null
  done
  
  exit 1
}