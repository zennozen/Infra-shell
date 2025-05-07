#!/usr/bin/env bash
############################## usage #######################################
# script_path="$(dirname ${BASH_SOURCE[0]})"
# abs_script_path="$(realpath "${BASH_SOURCE[0]}")"
# workdir="$(dirname "$abs_script_path")"
#
# source "$script_path/../00_utils/_print.sh"
#
## Single-line printing:
#    _print_line split -
#    _print_line title "this is a title message"
## Multiline Printing:
#    _print_line split - 3
#    _print_line title "this is a title message" 2
############################## usage #######################################

# Define color codes
red="\033[1;31m"
green="\033[1;32m"
yellow="\033[1;33m"
blue="\033[1;36m"
gray="\033[1;90m"
reset="\033[0m"

########################################
## General print line function
########################################
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
