#!/usr/bin/env bash
############################## import #######################################
# script_path="$(dirname ${BASH_SOURCE[0]})"
# abs_script_path="$(realpath "${BASH_SOURCE[0]}")"
# workdir="$(dirname "$abs_script_path")"
#
# source "$script_path/../00_utils/_print.sh"
############################## import #######################################

# Define color codes
red="\033[1;31m"
green="\033[1;32m"
yellow="\033[1;33m"
blue="\033[1;36m"
gray="\033[1;90m"
reset="\033[0m"

#############################################################################
## Function: _print_line
## Overview：General print line function. 
## Description:
##   This function formats and prints log messages in different colors based 
##   on the log level, including the line number of code execution, log level, 
##   and message.
##
## Parameters:
##   - $1: (Line type) split or title
##   - $2: char when split type, title message when title type
##   - $3: line count num
##
## Returns:
##   - 0: Success (Line printed successfully)
##   - 2：Failure (Invalid option ... Usage: ...)
##
## Example:
##   _print_line split -
##   _print_line split * 2
##   _print_line title "this is a title message"
##   _print_line title "this is a title message" 2
#############################################################################
function _print_line() {
  local type="$1"
  local count="$3"
  local width=$(tput cols)

  case $type in
    split)
      local char="$2"

      if [[ "$char" == "blank" ]]; then
        for i in $(seq 1 $count); do echo; done
      else
        for i in $(seq 1 $count); do
          printf "${green}%${width}s${reset}\n" | tr ' ' "$char"
        done
      fi
      ;;
    title)
      local title="$2"
      local title_length="${#title}"
      local board="####"
      local board_length="${#board}"
      local total_padding=$(( width - title_length - 2 * board_length ))
      local left_padding=42
      local right_padding=$(( total_padding - left_padding ))
      
      _print_line split $count "#"
      printf "${green}%s%*s%s%*s%s${reset}\n" "$board" "$left_padding" " " "$title" "$right_padding" " " "$board"
      _print_line split $count "#"
      ;;
    *)
      printf "Invalid option $*\n"
      printf "${green}Usage: ${reset}\n"
      printf "    ${green}$FUNCNAME title${gray}/split ${green}-${gray}/=/# ${green}row_num${reset}\n"
      return 2
      ;;
  esac
}
