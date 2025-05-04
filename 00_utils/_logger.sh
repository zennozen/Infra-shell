#!/usr/bin/env bash
############################## usage #######################################
# script_path="$(dirname ${BASH_SOURCE[0]})"
# abs_script_path="$(realpath "${BASH_SOURCE[0]}")"
# workdir="$(dirname "$abs_script_path")"
#
# source "$script_path/../00_utils/_logger.sh"
#
# _logger debug "This is a debug message."
# _logger info "This is an informational message."
# _logger warn "This is a warning message."
# _logger error "This is an error message."
############################## usage #######################################

function _logger() {
  local time_lineno="${blue}$(date +'%Y-%m-%d %H:%M:%S') [$(basename "${BASH_SOURCE[1]}"):${BASH_LINENO[0]}]${reset}"

  case "$1" in
    debug)
      echo -e "${time_lineno} ${blue}[DEBUG] $2 ${reset}"
      ;;
    info)
      echo -e "${time_lineno} ${green}[INFO] $2 ${reset}"
      ;;
    warn)
      echo -e "${time_lineno} ${yellow}[WARN] $2 ${reset}"
      ;;
    error)
      echo -e "${time_lineno} ${red}[ERROR] $2 ${reset}"
      ;;
    *)
      printf "Invalid option $*\n"
      printf "${green}Usage: ${reset}\n"
      printf "    ${green}$FUNCNAME info${gray}/debug/warn/error ${green}"This is an message."${reset}\n"
      exit 2 ;;
  esac
}