#!/usr/bin/env bash
# https://www.postgresql.org/download/
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
  SRV_IP PG_VER PG_HOME PG_DATA PG_LISTEN_PORT PG_PASSWD
' ERR

# define golabal variables
SYS_VER=$(grep -oP 'release \K[0-9.]' /etc/redhat-release)
SRV_IP="$(ip -4 addr show | grep inet | grep -v 127.0.0.1 | awk 'NR==1 {print $2}' | cut -d'/' -f1)"
PG_VER="$2"
PG_PASSWD="${3:-AAAaaa12#$}"
PG_LISTEN_PORT="${4:-5432}"

#######################################
## Main Business Logic Begins
#######################################

function rpm_install() {
  _print_line title "Install postgresql via rpm"

  _logger info "1. Install postgres repo"
  dnf install -y "https://download.postgresql.org/pub/repos/yum/reporpms/EL-${SYS_VER}-x86_64/pgdg-redhat-repo-latest.noarch.rpm"
  dnf -qy module disable postgresql

  _logger info "2. Install postgresql${PG_VER}-server"
  dnf install -y postgresql${PG_VER}-server
  echo "export PG_HOME=$PG_HOME" >> /etc/profile
  echo "export PATH=\$PATH:\$PG_HOME/bin" >> /etc/profile
  # source /etc/profile   # Avoid potential issues from erroneous environment variables
  export PG_HOME=$PG_HOME
  export PATH=$PATH:$PG_HOME/bin
  echo -e "PATH: $PATH"

  _logger info "3. Init postgresql-${PG_VER}-setup"
  /usr/pgsql-${PG_VER}/bin/postgresql-${PG_VER}-setup initdb
}


function source_install() {
  _print_line title "Install postgresql by compiling source code to binary"

  [[ -z $(ls -A $PG_HOME &>/dev/null) ]] || { _logger error "PostgreSQL is already installed in $PG_HOME." && exit 1; }

  _logger info "1. Install necessary rpm dependencies"
  dnf install -y gcc make bison flex perl zlib-devel readline-devel openssl-devel libicu-devel python3-devel

  _logger info "2. Download source code and extract"
  local LATEST_VER=$(curl -s https://www.postgresql.org/ftp/source/ | grep -oP 'v\K[0-9]+\.[0-9]+' | grep "^$PG_VER" | head -1)
  local PG_PKG_PREFIX="postgresql-$LATEST_VER"
  local PG_URL="https://ftp.postgresql.org/pub/source/v$LATEST_VER/${PG_PKG_PREFIX}.tar.gz"

  cd /usr/local/src
  if [[ -f ${PG_PKG_PREFIX}.tar.gz ]]; then
    _logger warn "${PG_PKG_PREFIX}.tar.gz is already exists in /usr/local/src/, will extract and use ..."
  else
    wget -c ${PG_URL}
  fi
  tar -zxf ${PG_PKG_PREFIX}.tar.gz

  _logger info "3. Configure, make and make install"
  cd $PG_PKG_PREFIX
  ./configure --prefix=$PG_HOME --with-python
  local make_threads=$(( (t=($((nproc))*3/2+1)/2*2, t>0 ? t : 1) ))
  time make -j$make_threads | tee -a make.log
  time make install -j$make_threads  | tee -a make_install.log
  cd .. && rm -rf $PG_PKG_PREFIX

  _logger info "4. Create necessary user and directories, update permissions and PATH"
  id postgres 2>/dev/null || useradd -r -d $PG_HOME postgres
  mkdir -p $PG_DATA
  chown -R postgres:postgres $PG_HOME

  echo "export PG_HOME=$PG_HOME" >> /etc/profile
  echo "export PATH=\$PATH:\$PG_HOME/bin" >> /etc/profile
  # source /etc/profile   # Avoid potential issues from erroneous environment variables
  export PG_HOME=$PG_HOME
  export PATH=$PATH:$PG_HOME/bin
  echo -e "PATH: $PATH"

  _logger info "5. Init database"
  sudo -i -u postgres $PG_HOME/bin/initdb -D $PG_HOME/data
}


function update_config() {
  local PG_CONF="$PG_DATA/postgresql.conf"
  if [[ $PG_HOME == "/usr/pgsql-$PG_VER" ]]; then
    local UNIX_SOCKET_DIR="/run/postgresql"
    mkdir -p $UNIX_SOCKET_DIR && chown -R postgres:postgres $_
  else
    local UNIX_SOCKET_DIR="/tmp"
  fi

  _logger info "6. Backup and update postgres config, write connection information to ~/.pgpass"
  [[ -f $PGSQL_CONF ]] && cp -v $PGSQL_CONF ${PGSQL_CONF}_$(date +'%Y%m%d-%H%M').bak
  tee $PG_CONF <<-EOF
listen_addresses = '*'
port = $PG_LISTEN_PORT
unix_socket_directories = '$UNIX_SOCKET_DIR'
max_connections = 200
shared_buffers = '2GB'             # Typically set to 25% - 50% of system memory, used for caching data blocks
work_mem = '64MB'
maintenance_work_mem = '512MB'
wal_buffers = '64MB'               # WAL buffer size, usually 3% - 5% of shared_buffers
fsync = on
synchronous_commit = on
effective_cache_size = '4GB'       # Cache size used by the query optimizer, typically 50% - 75% of system memory

max_wal_size = 1GB
min_wal_size = 80MB

max_worker_processes = 8
max_parallel_workers_per_gather = 4
max_parallel_workers = 8

log_timezone = 'Asia/Shanghai'
log_destination = 'csvlog'
logging_collector = on
log_statement = 'mod'

enable_parallel_append = on
enable_parallel_hash = on
enable_partition_pruning = on
enable_partitionwise_aggregate = on
enable_incremental_sort = on

checkpoint_timeout = '30min'
vacuum_cost_delay = 2ms
vacuum_cost_limit = 200

datestyle = 'iso, ymd'
timezone = 'Asia/Shanghai'
default_text_search_config = 'pg_catalog.english'
EOF

  [[ -f ~/.pgpass ]] && cp -fv ~/.pgpass ~/.pgpass.bak
  echo "localhost:$PG_LISTEN_PORT:*:postgres:$PG_PASSWD" | tee ~/.pgpass
  chmod 0600 ~/.pgpass
}

function create_service() {
  _logger info "7. Create the service unit file, manage using systemctl"
  local PG_SERVICE_UNIT="/etc/systemd/system/postgresql-$PG_VER.service"
  [[ -f $PG_SERVICE_UNIT ]] && cp -fv $PG_SERVICE_UNIT $PG_SERVICE_UNIT.bak
  tee $PG_SERVICE_UNIT <<-EOF
[Unit]
Description=PostgreSQL database server
Documentation=man:postgres(1)
After=network.target

[Service]
Type=forking
User=postgres
Group=postgres
ExecStart=$PG_HOME/bin/pg_ctl start -D $PG_DATA
ExecStop=$PG_HOME/bin/pg_ctl stop -D $PG_DATA -m fast
ExecReload=$PG_HOME/bin/pg_ctl reload -D $PG_DATA
Restart=on-failure
LimitNOFILE=65536
LimitNPROC=65536
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF
}


function start_service() {
  _logger info "8. Start and enable PostgreSQL service"
  systemctl enable --now postgresql-$PG_VER && sleep 3
  systemctl status --no-pager -l postgresql-$PG_VER
  echo

  _logger info "9. Check and open the corresponding firewall ports"
  if systemctl status firewalld | grep "active (running)" &>/dev/null; then
    firewall-cmd --add-port=$PG_LISTEN_PORT/tcp --permanent &>/dev/null
    firewall-cmd --reload &>/dev/null
    echo -e "Current open ports in the firewall: ${green}$(firewall-cmd --list-ports)${reset}"
  else
    _logger warn "System firewalld is currently disabled."
  fi
}

function execute_init_sql() {
  local INIT_SQL="ALTER USER postgres WITH PASSWORD '$PG_PASSWD';"
  local REMOTE_LOGIN_CMD="PGPASSWORD=$PG_PASSWD psql -h $SRV_IP -p $PG_LISTEN_PORT -U postgres"

  _logger info "10. Essential client CLI tools installed and executed custom SQL"
  sudo -i -u postgres psql -c "$INIT_SQL"
  echo

  _logger info "11. Modify pg_hba.conf to allow password authentication, and restart service"
  local pg_hba_conf="$PG_DATA/pg_hba.conf"
  cp -fv $pg_hba_conf $pg_hba_conf.bak
  sed -i -e "/local   all/s/peer/md5/g" \
    -e "/# IPv6 local/i host all all 0.0.0.0/0 md5" $pg_hba_conf
  systemctl restart postgresql-$PG_VER && sleep 3
  systemctl status --no-pager -l postgresql-$PG_VER

  _print_line split -
  _logger info "PostgreSQL service has been successfully installed. Summary:"
  $PG_HOME/bin/pg_ctl --version
  echo
  if grep PG_HOME /etc/profile; then
    echo -e "${red}Note: Detected the above environment variables are not in effect."
    echo -e "      Please run ${blue}source /etc/profile ${red}to apply them.${reset}"
  fi
  echo
  echo -e "${green}Local login command: ${blue}psql -U postgres${reset}"
  echo -e "${green}Remote login command: ${blue}$REMOTE_LOGIN_CMD${reset}"
}

function remove() {
  local PG_HOME="$(ls -ld /usr/pgsql-* 2>/dev/null | awk '{printf $9}')"
  local PG_HOME="${PG_HOME:-/usr/local/pgsql}"
  local PG_DATA=$(ls -ld /var/lib/pgsql/* 2>/dev/null | awk '{printf $9}')
  local PG_DATA="${PG_DATA:-/usr/local/pgsql/data}"
  local PG_CONF="$PG_DATA/postgresql.conf"
  local PG_LISTEN_PORT="$(awk '/port/ {print $3}' $PG_CONF 2>/dev/null | xargs)"
  local PG_LISTEN_PORT="${PG_LISTEN_PORT:-5432}"

  # check args
  if [[ ! -d $PG_HOME ]]; then
      _logger error "PostgreSQL is not installed."
      exit 1
  fi

  _print_line title "Remove MySQL service"

  _logger info "1. Check and kill processes ..."
  local pg_srv_name=$(systemctl list-units --type=service --all --no-pager --no-legend \
    --plain | grep 'postgres' | awk '{print $1}')
  [[ -n $pg_srv_name ]] || { _logger error "$pg_srv_name service unit file is not found." && exit 1; }

  systemctl is-active --quiet $pg_srv_name && systemctl stop $_ || true && sleep 3
  while ps -ef | grep "[p]gsql" | grep -v "pts" &>/dev/null; do
    echo -e "${yellow}PostgreSQL service is stopping, if necessary, please manually kill: ${red}pkill -9 pgsql${reset}"
    sleep 5
  done

  _logger info "2. Delete related files ..."
  dnf list --installed | grep 'postgresql[^-]*-server' | awk '{print $1}' | xargs dnf remove -y
  rm -rfv $PG_HOME $PG_DATA /etc/postgresql
  rm -rfv /etc/systemd/system/postgresql-*.service && systemctl daemon-reload

  _logger info "3. Delete postgres user"
  id postgres && userdel -f postgres

  _logger info "4. Close the corresponding firewall ports"
  if systemctl status firewalld >/dev/null; then
    firewall-cmd --remove-port=$PG_LISTEN_PORT/tcp --permanent &>/dev/null
    firewall-cmd --reload >/dev/null
    echo -e "Current open ports in the firewall: $(firewall-cmd --list-ports)"
  else
    _logger warn "System firewalld is currently disabled."
  fi

  _logger info "5. Remove the corresponding environment variable"
  sed -i "/PG_HOME/d" /etc/profile

  _print_line split -
  _logger info "PostgreSQL has been successfully removed.\n"
}

function main() {
  function _help() {
    printf "Invalid option ${@:1}\n"
    printf "${green}Usage: ${reset}\n"
    printf "    ${gray}bash ${blue}$0 ${green}rpm_install 17${gray}/16/15 PGPASSWORD 5432${reset}\n"
    printf "    ${gray}bash ${blue}$0 ${green}source_install 17${gray}/16/15 PGPASSWORD 5432 /usr/local/pgsql${reset}\n"
    printf "    ${gray}bash ${blue}$0 ${green}remove${reset}\n"
  }

  case $1 in
    rpm_install)
      [[ $# -ge 2 ]] || { _help && exit 1; }
      PG_HOME="/usr/pgsql-$PG_VER"
      PG_DATA="/var/lib/pgsql/$PG_VER/data"
      rpm_install
      update_config
      start_service
      execute_init_sql
      ;;
    source_install)
      [[ $# -ge 2 ]] || { _help && exit 1; }
      PG_HOME="${5:-/usr/local/pgsql}"
      PG_DATA="$PG_HOME/data"
      source_install
      update_config
      create_service
      start_service
      execute_init_sql
      ;;
    remove)
      remove ${@:1}
      ;;
    *)
      _help ${@:1} && exit 1
      ;;
  esac
}

main ${@:1}
