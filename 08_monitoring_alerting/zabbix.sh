#!/usr/bin/env bash
# https://www.zabbix.com/download
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
  SRV_IP ZBX_VER ZBX_DB_TYPE ZBX_DB_PASSWD db_host db_port \
  ZBX_WEB_SRV ZBXS_CONF ZBXA2_CONF ZBX_SRVS
' ERR

# define golabal variables
SRV_IP="$(ip -4 addr show | grep inet | grep -v 127.0.0.1 | awk 'NR==1 {print $2}' | cut -d'/' -f1)"
ZBX_VER="$2"
ZBX_DB_TYPE="$3"
ZBX_DB_PASSWD="${4:-AAAaaa12#$}"
ZBX_WEB_SRV="nginx"
ZBXS_CONF="/etc/zabbix/zabbix_server.conf"
ZBXA2_CONF="/etc/zabbix/zabbix_agent2.conf"
ZBX_PKGS=(
  zabbix-nginx-conf
  zabbix-sql-scripts
  zabbix-selinux-policy
  zabbix-agent2
  zabbix-server-$ZBX_DB_TYPE
  zabbix-web-$ZBX_DB_TYPE
)
ZBX_PKG_DEPS=(
  zabbix-agent2-plugin-mongodb
  zabbix-agent2-plugin-mssql
  zabbix-agent2-plugin-postgresql
)
ZBX_SRVS=(
  zabbix-server
  zabbix-agent2
  nginx
  php-fpm
)

#######################################
## Main Business Logic Begins
#######################################

function db_cmd() {
  case $1 in
    get_info)
      _logger info "Retrieve remote database connection information and validate. Please enter the database connect info:"
      read -rp "    Host: " db_host
      read -rp "    Port: " db_port
      read -rp "    SuperManager Username: " db_super_user
      read -rsp "    Password: " db_passwd
      ;;
    conn_cmd)
      shift
      case $ZBX_DB_TYPE in
        mysql)
          mysql -h $db_host -P $db_port -u $db_super_user -p$db_passwd "$@"
          ;;
        pgsql)
          PGPASSWORD="$db_passwd" psql -h $db_host -p $db_port -U $db_super_user "$@"
          ;;
      esac
      ;;
    chk_status)
      _logger info "Validate remote database connection."
      conn_status=0
      echo "SELECT VERSION();" | db_cmd conn_cmd && conn_status=1 || _logger error "Database connection failed."
      ;;
  esac
}

function db_get_and_test() {
  _logger info "1. Check and install $ZBX_DB_TYPE client"
  case $ZBX_DB_TYPE in
    mysql)
      which mysql || dnf install -y mysql
      ;;
    pgsql)
      which psql || dnf install -y postgresql
      ;;
  esac

  _logger info "2. Get database connect status and test connect status"
  while [[ $conn_status != 1 ]]; do
    db_cmd get_info
    db_cmd chk_status
    break
  done
}

function install() {
  _print_line title "Install zabbix"

  #[[ -z $(ls -A $ES_HOME 2>/dev/null) ]] || { _logger error "Elasticsearch already installed on the system." && exit 1; }

  # check args
  if [[ ! $ZBX_VER =~ ^(6.0|7.0|7.2)$ ]]; then
    _logger error "Version mismatch. Please choose from the below."
    echo -e "official recommended versions: 6.0 7.0 7.2 7.4"
    _help ${@:1}
    exit 1
  fi
  if [[ ! $ZBX_DB_TYPE =~ ^(mysql|pgsql)$ ]]; then
    _logger error "DB type mismatch. Please choose from the below."
    echo -e "official support database type: mysql pgsql\n"
    _help ${@:1}
    exit 1
  fi

  db_get_and_test

  _logger info "3. Generate initialization SQL statements"
  case $ZBX_DB_TYPE in
    mysql)
      local init_sql="create database zabbix character set utf8mb4 collate utf8mb4_bin;
        create user zabbix@'%' identified by '$ZBX_DB_PASSWD';
        grant all privileges on zabbix.* to zabbix@'%';
        flush privileges;
        set global log_bin_trust_function_creators = 1;  # temporarily allow regular users to create stored functions
      "
      local chk_and_revoke_sql="show tables from zabbix; set global log_bin_trust_function_creators = 0;"
      ;;
    pgsql)
      local init_sql="create user zabbix with password '$ZBX_DB_PASSWD';
        create database zabbix owner zabbix;"
      ;;
  esac

  _logger info "4. Begin environment pre-processing"
  _logger info "4.1 Disable selinux"
  sed -i "/SELINUX=/s/enforcing/disabled/g" /etc/selinux/config | sed "/^#/d; /^$/d"
  setenforce 0 && sestatus

  _logger info "4.2 Configure ntp clock source and immediately synchronize time"
  _logger info "Backup and update the chrony config"
  which chronyc &>/dev/null || dnf install -y chronyd
  local chrony_conf="/etc/chrony.conf"
  [[ -f $chrony_conf ]] && cp -fv $chrony_conf $chrony_conf.bak
  tee $chrony_conf <<-EOF
server ntp.aliyun.com iburst
server cn.pool.ntp.org iburst
server ntp.ntsc.ac.cn iburst
local stratum 10
makestep 1.0 3
rtcsync
driftfile /var/lib/chrony/drift
logdir /var/log/chrony
EOF
  _logger info "Restarting/Starting Chronyd service"
  systemctl restart chronyd && systemctl enable $_ && systemctl status --no-pager $_

  _logger info "Immediately jump to the current time and force correction of historical errors"
  chronyc -a makestep

  _logger info "Verifying the time source and synchronization status"
  chronyc sources -v

  _logger info "4.3 Disable the EPEL repository for Zabbix-related packages"
  local epel_repo="/etc/yum.repos.d/epel.repo"
  if [[ -f $epel_repo ]]; then
    sed -i -e '
      /\[epel\]/,/^$/ {
        /excludepkgs=/d
        # add 'excludepkgs=zabbix*' after the last option in the '[epel]' section
        /^$/i excludepkgs=zabbix*
      }
    ' "$epel_repo"
    dnf clean all
  else
    echo "EPEL repo not found, skipping exclusion."
  fi

  _logger info "5. Add and use official repositories and install software"
  dnf install -y https://repo.zabbix.com/zabbix/$ZBX_VER/release/rocky/9/noarch/zabbix-release-latest-${ZBX_VER}.el9.noarch.rpm
  _logger info "Starting installation software, the componments include:
      Zabbix-{Server, Frontend, Agent 2}、$ZBX_DB_TYPE、nginx，and plugins-related"
  # Install Zabbix server, frontend, agent2
  dnf install -y ${ZBX_PKGS[@]}
  # Install Zabbix agent 2 plugins
  dnf install -y ${ZBX_PKG_DEPS[@]}

  _logger info "6. Starting init Zabbix Database"
  case $ZBX_DB_TYPE in
    mysql)
      _logger info "Connect to MySQL server remotely, and create zabbix user and database."
      echo "$init_sql" | db_cmd conn_cmd

      _logger info "Replay SQL statements to import initial data."
      zcat /usr/share/zabbix/sql-scripts/mysql/server.sql.gz | \
        mysql --default-character-set=utf8mb4 -h $db_host -u zabbix -p"$ZBX_DB_PASSWD" -D zabbix

      _logger info "Validate Zabbix database and reclaim tempoprary permissions."
      echo "$chk_and_revoke_sql" | db_cmd conn_cmd
      ;;
    pgsql)
      _logger info "Connect to PostgreSQL server remotely, and create zabbix user and database."
      echo "$init_sql" | db_cmd conn_cmd

      _logger info "Import initial data"
      zcat /usr/share/zabbix/sql-scripts/postgresql/server.sql.gz | \
        PGPASSWORD=$ZBX_DB_PASSWD psql -h $db_host -U zabbix -d zabbix
      ;;
  esac

  _logger info "7. Update the Zabbix-Server configuration file"
  [[ -f $ZBXS_CONF ]] && cp -fv $ZBXS_CONF $ZBXS_CONF.bak
  sed -i -e "/^# PidFile=/s/^# //g" \
    -e "/^# ListenIP/s/^# //g" \
    -e "/^# ListenPort/s/^# //g" \
    -e "/^# DBHost/s/.*/DBHost=$db_host/g" \
    -e "/^# DBPassword/s/.*/DBPassword=$ZBX_DB_PASSWD/g" \
    -e "/^# DBPort/s/.*/DBPort=$db_port/g" \
    -e "/^# StartVMwareCollectors/s/.*/StartVMwareCollectors=5/g" \
    -e "/^EnableGlobalScripts/s/0/1/g" \
    -e "/datadir/s/^# //g" \
    $ZBXS_CONF
  sed -i -c -e "/^$/d; /^#/d" $ZBXS_CONF && cat $_

  _logger info "8. Update the Zabbix-Agent2 configuration file"
  _logger info "Generate a PSK for secure communication between Agent2 and the Server using OpenSSL."
  local PSK="/etc/zabbix/zabbix_agent2.psk"
  local PSK_ID="psk01"
  openssl rand -hex 32 | tee $PSK
  chown zabbix:zabbix $PSK

  [[ -f $ZBXA2_CONF ]] && cp -fv $ZBXA2_CONF $ZBXA2_CONF.bak  
  sed -i -e "/^# LogFile=/s/^# //g" \
    -e "/^# PidFile=/s/^# //g" \
    -e "/^# UnsafeUserParameters/s/.*/UnsafeUserParameters=1/g" \
    -e "/^# TLSConnect/s/.*/TLSConnect=psk/g" \
    -e "/^# TLSAccept/s/.*/TLSAccept=psk/g" \
    -e "/^# TLSPSKIdentity/s/.*/TLSPSKIdentity=$PSK_ID/g" \
    -e "/^# TLSPSKFile/s|.*|TLSPSKFile=$PSK|g" \
    -e "/^Server=/s/127.0.0.1/127.0.0.1,$SRV_IP/g" \
    -e "/^ServerActive=/s/127.0.0.1/127.0.0.1,$SRV_IP/g" \
    -e "/^# ListenIP/s/^# //g" \
    -e "/^# ListenPort/s/^# //g" \
    $ZBXA2_CONF
  sed -i -c -e "/^$/d; /^#/d" $ZBXA2_CONF && cat $_

  _logger info "9. Check and open the corresponding firewall ports"
  if systemctl status firewalld | grep "active (running)" &>/dev/null; then
    firewall-cmd --add-port={80,10050}/tcp --permanent &>/dev/null
    firewall-cmd --reload &>/dev/null
    echo -e "Current open ports in the firewall: ${green}$(firewall-cmd --list-ports)${reset}"
  else
    _logger warn "System firewalld is currently disabled."
  fi

  _logger info "10. Starting all Zabbix services: ${ZBX_SRVS[@]}"
  systemctl enable --now ${ZBX_SRVS[@]}

  _logger info "11. If Chinese characters are garbled in charts, follow these steps to fix the issue:"
  _logger info "Step1: Select one from the Chinese fonts installed on this machine."
  zh_font=$(fc-list :lang=zh | awk -F':' 'NR==1{print $1}') && echo $zh_font
  _logger info "Step2: Change the default font in Zabbix Web to a Chinese font."
  case $ZBX_VER in
    6.0)
      local graphfont="/usr/share/zabbix/assets/fonts/graphfont.ttf"
      cp -fv $graphfont $graphfont.bak
      ln -fsv $zh_font $graphfont
      ;;
    7.0)
      local web_font="/etc/alternatives/zabbix-web-font"
      cp -fv $web_font $web_font.bak
      ln -fsv $zh_font $web_font
      ;;
    7.2)
      local web_ui_font="/etc/alternatives/zabbix-web-ui-font"
      cp -fv $web_ui_font $web_ui_font.bak
      ln -fsv $zh_font $web_ui_font
      ;;
    *) ;;
  esac

  _print_line split -
  _logger info "Zabbix has been successfully installed. Summary:
Version:${reset} 
  $(zabbix_server -V | awk 'NR==1{print}')
  $(zabbix_agent2 -V | awk 'NR==1{print}')${green}
Configs dir: /etc/zabbix
Logs dir: /var/log/zabbix
PSK: PSK (public-shared-key), Setting in Web/Monitoring/Hosts/Regit-Click/Host/Encryption/PSK.
  ${red}PSK-ID: $PSK_ID ${reset}
  ${red}PSK: $(cat $PSK) ${green}

Web init info:
  Accsess address: http://$SRV_IP
  DB connection:
    ip: $db_host
    port: $db_port
    user: zabbix
    password: $ZBX_DB_PASSWD
  Web login:
    user: Admin
    password: zabbix
  "
}

function remove() {
  # check_args
  #which zabbix_server >/dev/null || { _logger error "Zabbix is not installed on system." && exit 1; }

  _print_line title "Remove Zabbix Server/Agent2"

  db_get_and_test

  _logger info "3. Check and kill processes ..."
  for srv in ${ZBX_SRVS[@]}; do
    systemctl is-active --quiet $srv && systemctl stop $srv || true && sleep 3
    while ps -ef | grep "$srv" | grep -v "pts" &>/dev/null; do
      echo -e "${yellow}$srv is stopping, if necessary, please manually kill: ${red}pkill -9 $srv${reset}"
      sleep 5
    done
  done

  _logger info "4. Remove packages"
  dnf remove -y ${ZBX_PKGS[@]} ${ZBX_PKG_DEPS[@]}

  _logger info "5. Delete related files"
  rm -rfv /etc/zabbix /var/lib/zabbix /var/log/zabbix /var/cache/zabbix /usr/lib/zabbix
  find /usr/local/lib/systemd/system/ -name *zabbix* -exec rm -rf {} \;
  find /etc/systemd/system/ -name *zabbix* -exec rm -rf {} \;
  systemctl daemon-reload

  _logger info "6. Delete related user"
  id zabbix && userdel -r zabbix

  _logger info "7. Remove Zabbix database and user in remote $ZBX_DB_TYPE server"
  case $ZBX_DB_TYPE in
    mysql)
      local remove_sql="drop database if exists zabbix; drop user if exists zabbix@'%';"
      ;;
    pgsql)
      local remove_sql="drop database if exists zabbix; drop user if exists zabbix;"
      ;;
  esac
  echo "$remove_sql" | db_cmd conn_cmd

  _print_line split -
  _logger info "Zabbix removed successfully.\n"
}


function main() {
  function _help() {
    printf "Invalid option ${@:1}\n"
    printf "${green}Usage: ${reset}\n"
    printf "    ${gray}bash ${blue}$0 ${green}install 7.2${gray}/6.0/7.0/7.4 ${green}pgsql${gray}/mysql zabbix_password${reset}\n"
    printf "    ${gray}bash ${blue}$0 ${green}remove pgsql${gray}/mysql${reset}\n"
  }

  case $1 in
    install)
      [[ $# -ge 3 ]] || { _help && exit 1; }
      install ${@:1}
      ;;
    remove)
      [[ $# -ge 2 ]] || { _help && exit 1; }
      remove ${@:1}
      ;;
    *)
      _help ${@:1} && exit 1 ;;
  esac
}

main ${@:1}
