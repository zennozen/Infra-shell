#!/usr/bin/env bash
# https://maven.apache.org/download.cgi
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
  latest_version VERSION MVN_HOME URL
' ERR

function install() {
  _print_line title "Install maven environment"

  ! which mvn || { _logger info "Maven environment already installed on the system." && exit 1; }

  latest_version=$(curl -s "https://maven.apache.org/download.cgi" | grep -oP 'Apache Maven \K\d+\.\d+\.\d+' | head -1)
  VERSION=${1:-$latest_version}
  MVN_HOME="/usr/local/apache-maven-$VERSION"
  URL="https://dlcdn.apache.org/maven/maven-$(echo $VERSION | cut -d'.' -f1)"/$VERSION/binaries/apache-maven-$VERSION-bin.tar.gz
  PKG=$(basename $URL)

  cd /usr/local/src
  if [[ -f $PKG ]]; then
    _logger warn "$PKG is already exists in /usr/local/src/, will extract and use ..."
  else
    wget -c $URL
  fi
  tar -zxf $PKG -C /usr/local/
  cd -

  echo "export MVN_HOME=$MVN_HOME" >> /etc/profile
  echo "export PATH=\$PATH:\$MVN_HOME/bin" >> /etc/profile
  # source /etc/profile   # Avoid potential issues from erroneous environment variables
  export MVN_HOME=$MVN_HOME
  export PATH=$PATH:$MVN_HOME/bin
  echo -e "PATH: $PATH"

  _print_line split -
  _logger info "Maven environment has been successfully installed. Summary:"
  echo -e "${green}Command to show version: ${blue}mvn -v${reset}"
  mvn -v
  echo
  if grep MVN_HOME /etc/profile; then
    echo -e "${red}Note: Detected the above environment variables are not in effect."
    echo -e "      Please run ${blue}source /etc/profile ${red}to apply them.${reset}"
  fi
}

function remove() {
  # check args
  which mvn || { _logger error "Maven is not installed on the system." && exit 1; }\

  _print_line title "Remove Maven environment"

  _logger info "1. Delete related files ..."
  rm -rfv $(sed -n 's/export MVN_HOME=//p' /etc/profile)

  _logger info "2. Remove the corresponding environment variable"
  sed -i "/MVN_HOME/d" /etc/profile

  _print_line split -
  _logger info "Maven environment has been successfully removed.\n"
}

function main() {
  function _help() {
    printf "Invalid option ${@:1}\n"
    printf "${green}Usage: ${reset}\n"
    printf "    ${gray}bash ${blue}$0 ${green}install ${gray}3.9.9 ${gray}/usr/local${reset}\n"
    printf "    ${gray}bash ${blue}$0 ${green}remove${reset}\n"
  }

  case $1 in
    install)
      shift
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
