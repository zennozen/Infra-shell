#!/usr/bin/env bash
# OpenJDK: https://www.openlogic.com/openjdk-downloads, https://mirrors.tuna.tsinghua.edu.cn/Adoptium/
# OpenJDK - BiShengJDK: https://www.openeuler.org/zh/other/projects/bishengjdk/
set -o errexit

script_path="$(dirname ${BASH_SOURCE[0]})"
abs_script_path="$(realpath "${BASH_SOURCE[0]}")"
workdir="$(dirname "$abs_script_path")"

# import some define
source "$script_path/../00_utils/_print.sh"
source "$script_path/../00_utils/_trap.sh"
source "$script_path/../00_utils/_logger.sh"

# capture errors and print environment variables
trap '_trap_print_env \
  RELEASE TYPE JAVA_HOME URL
' ERR

###############################################
## Java JDK/JRE installation function: 
##   Supports installing openjdk/jre or 
##   openjdk-bishengjdk/jre based on parameters
###############################################
function install() {
  RELEASE="$(echo $1 | cut -d'-' -f1)"
  TYPE="$(echo $1 | cut -d'-' -f2)"
  VER="$2"
  INSTALL_DIR="${3:-/usr/local}"
  JAVA_HOME="$INSTALL_DIR/$RELEASE-$TYPE-$VER"

  ! which java || { _logger error "Java already installed on the system." && exit 1; }

  _print_line title "Install Java $TYPE environment"

  # determine type and version based on parameters, and generate download URL
  case $RELEASE in
    openjdk)
      SOURCE_PREFIX="https://mirrors.tuna.tsinghua.edu.cn/Adoptium/$VER/$TYPE/x64/linux"
      case $VER in
        8)
          URL="$SOURCE_PREFIX/OpenJDK8U-${TYPE}_x64_linux_hotspot_8u452b09.tar.gz"
          PKG_ROOT_NAME="jdk8u452-b09"
          [[ $TYPE == "jre" ]] && PKG_ROOT_NAME="jdk8u452-b09-jre"
          ;;
        11)
          URL="$SOURCE_PREFIX/OpenJDK11U-${TYPE}_x64_linux_hotspot_11.0.27_6.tar.gz"
          PKG_ROOT_NAME="jdk-11.0.27+6"
          [[ $TYPE == "jre" ]] && PKG_ROOT_NAME="jdk-11.0.27+6-jre"
          ;;
        17)
          URL="$SOURCE_PREFIX/OpenJDK17U-${TYPE}_x64_linux_hotspot_17.0.15_6.tar.gz"
          PKG_ROOT_NAME="jdk-17.0.15+6"
          [[ $TYPE == "jre" ]] && PKG_ROOT_NAME="jdk-17.0.15+6-jre"
          ;;
        21)
          URL="$SOURCE_PREFIX/OpenJDK21U-${TYPE}_x64_linux_hotspot_21.0.7_6.tar.gz"
          PKG_ROOT_NAME="jdk-21.0.7+6"
          [[ $TYPE == "jre" ]] && PKG_ROOT_NAME="jdk-21.0.7+6-jre"
          ;;
        *)
          _logger error "The version number $VER does not match."
          ;;
      esac
      ;;
    bishengjdk)
      SOURCE_PREFIX="https://mirrors.huaweicloud.com/kunpeng/archive/compiler/bisheng_jdk"
      case $VER in
        8)
          URL="$SOURCE_PREFIX/bisheng-${TYPE}-8u442-b12-linux-x64.tar.gz"
          PKG_ROOT_NAME="bisheng-${TYPE}1.8.0_442"
          ;;
        11)
          URL="$SOURCE_PREFIX/bisheng-${TYPE}-11.0.26-b12-linux-x64.tar.gz"
          PKG_ROOT_NAME="bisheng-${TYPE}-11.0.26"
          ;;
        17)
          URL="$SOURCE_PREFIX/bisheng-${TYPE}-17.0.14-b12-linux-x64.tar.gz"
          PKG_ROOT_NAME="bisheng-${TYPE}-17.0.14"
          ;;
        21)
          URL="$SOURCE_PREFIX/bisheng-${TYPE}-21.0.6-b12-linux-x64.tar.gz"
          PKG_ROOT_NAME="bisheng-${TYPE}-21.0.6"
          ;;
        *)
          _logger error "The version number $VER does not match."
          ;;
      esac
      ;;
    *)
      _logger error "Unrecognized release type $RELEASE."
      exit 1
      ;;
  esac
  PKG=$(basename $URL)

  # extract
  cd /usr/local/src
  if [[ -f $PKG ]]; then
    _logger warn "$PKG is already exists in /usr/local/src/, will extract and use ..."
  else
      wget -c $URL
  fi
  tar -zxf $PKG
  mv $PKG_ROOT_NAME $JAVA_HOME
  cd -

  # set env var
  echo "export JAVA_HOME=$JAVA_HOME" >> /etc/profile
  echo "export PATH=\$PATH:\$JAVA_HOME/bin" >> /etc/profile
  # source /etc/profile   # Avoid potential issues from erroneous environment variables
  export JAVA_HOME=$JAVA_HOME
  export PATH=$PATH:$JAVA_HOME/bin
  echo -e "PATH: $PATH"

  # summary
  _print_line split -
  _logger info "Java $TYPE environment has been successfully installed. Summary:"
  echo -e "${green}Command to show version: ${blue}java -version${reset}"
  java -version
  echo
  if grep JAVA_HOME /etc/profile; then
    echo -e "${red}Note: Detected the above environment variables are not in effect."
    echo -e "      Please run ${blue}source /etc/profile ${red}to apply them.${reset}"
  fi
}


#####################################################
## Java JDK/JRE removal function: 
##   Identify installation location from environment
##   variables and remove the software
#####################################################
function remove() {
  # check args
  which java || { _logger error "Java is not installed on the system." && exit 1; }\

  _print_line title "Remove Java $TYPE environment"

  # delete file
  _logger info "1. Delete related files ..."
  rm -rfv $(sed -n 's/export JAVA_HOME=//p' /etc/profile)

  # remove env var
  _logger info "2. Remove the corresponding environment variable"
  sed -i "/JAVA_HOME/d" /etc/profile

  _print_line split -
  _logger info "Java $TYPE environment has been successfully removed.\n"
}

function main() {
  function _help() {
    printf "Invalid option ${@:1}\n"
    printf "${green}Usage: ${reset}\n"
    printf "    ${gray}bash ${blue}$0 ${green}install openjdk${gray}/bishengjdk${green}-jdk${gray}/jre ${green}8${gray}/11/17/21 /usr/local${reset}\n"
    printf "    ${gray}bash ${blue}$0 ${green}remove${reset}\n"
  }

  case $1 in
    install)
      shift
      [[ $# -ge 2 ]] || { _help && exit 1; }
      install ${@:1}
      ;;
    remove)
      shift
      remove ${@:1}
      ;;
    *)
      _help ${@:1}
      exit 1
      ;;
  esac
}

main ${@:1}
