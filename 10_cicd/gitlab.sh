#!/usr/bin/env bash
# https://packages.gitlab.com/gitlab/gitlab-ce/install#bash-rpm
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
  SRV_IP GITLAB_CONF GITLAB_DOMAIN GITLAB_ROOT_PASSWORD AUTO_CERT SSL_CERT_PATH GITLAB_DATA_PATH \
  ENABLE_PROMETHEUS ENABLE_GRAFANA ENABLE_SMTP
' ERR

# define golabal variables
SRV_IP="$(ip -4 addr show | grep inet | grep -v 127.0.0.1 | awk 'NR==1 {print $2}' | cut -d'/' -f1)"
GITLAB_CONF="/etc/gitlab/gitlab.rb"
GITLAB_DOMAIN="${2:-my.gitlab.com}"
export GITLAB_ROOT_PASSWORD="${3:-AAAaaa12#$}"
BIND_IP="0.0.0.0"  # Bind IP (use internal IP in production; bind multiple for HA)
BIND_PORT="443"    # Listening port (non-standard HTTPS port enhances security)
AUTO_CERT="false"  # Enable Let's Encrypt auto certificate (false: use self-signed)
readonly SSL_CERT_PATH="/etc/gitlab/ssl/"
GITLAB_DATA_PATH="/data" && mkdir -p $GITLAB_DATA_PATH
ENABLE_PROMETHEUS="false"
ENABLE_GRAFANA="false"
ENABLE_SMTP="true"

#######################################
## Main Business Logic Begins
#######################################

function install() {
  _print_line title "Install Gitlab"

  [[ -z $(ls -A /etc/gitlab 2>/dev/null) ]] || { _logger error "Gitlab already installed on the system." && exit 1; }

  _logger info "1. Check hardware specs"
  local machine_free_mem_mb=$(free -m | awk 'NR==2{print $4}')
  if [[ $machine_free_mem_mb -ge 4096 ]]; then
    echo -e "${green}        The current system has more than 4GB of free memory, 
    meeting the installation requirements for a testing/experience environment.${reset}"
  else
    echo -e "${red}        The current system has less than 4GB of free memory,
    which does not meet the installation requirements for a testing/experience environment.${reset}"
    exit 1
  fi

  local swappiness=$(sysctl vm.swappiness | awk '{print $3}')
  if [[ $swappiness -le 10 ]]; then
    echo -e "${green}        The current system's swappiness is less than 10,
    which meets the application's requirement to use more physical memory and avoid using swap space.${reset}"
  else
    echo -e "${red}        The current system's swappiness is greater than 10,
    which does not meet the application's requirement to use more physical memory and avoid using swap space.${reset}"
    exit 1
  fi

  _logger info "2. Disable selinux"
  sed -i '/^SELINUX/s/enforcing/disabled/g' /etc/selinux/config
  grubby --update-kernel ALL --args selinux=0
  setenforce 0 && sestatus

  _logger info "3. Install dependencies"
  dnf install -y curl policycoreutils openssh-server perl postfix
  systemctl enable --now postfix

  _logger info "4. Add official repo and install software"
  curl -sS https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.rpm.sh | sudo bash
  # replace with domestic source
  sed -i.bak \
      -e "/\[gitlab_gitlab-ce\]/,/baseurl=/s#https.*#https://mirrors.tuna.tsinghua.edu.cn/gitlab-ce/yum/el\$releasever/#g" \
      -e "/\[gitlab_gitlab-ce\]/,/repo_gpgcheck=/s/1/0/g" \
      /etc/yum.repos.d/gitlab_gitlab-ce.repo
  dnf list installed gitlab-ce 2>/dev/null && _logger warn "Gitlab-ce already installed." || dnf install -y gitlab-ce

  _logger info "5. Update the configuration: $GITLAB_CONF"
  [[ -f $GITLAB_CONF ]] && cp -fv $GITLAB_CONF $GITLAB_CONF_$(date +'%Y%m%d-%H%M').bak

  ## Use openssl for self-signed certificates in local testing;
  #  production can use free certificates from cloud providers.
  if [[ "$AUTO_CERT" == "false" ]]; then
    _logger info "Generating self-signed certificate for local testing."
    mkdir -p $SSL_CERT_PATH
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout $SSL_CERT_PATH/$GITLAB_DOMAIN.key \
      -out $SSL_CERT_PATH/$GITLAB_DOMAIN.crt \
      -days 3650 \
      -subj "/C=CN/ST=Beijing/L=Beijing/O=YourCompany/CN=$GITLAB_DOMAIN" \
      -addext "subjectAltName=IP:$BIND_IP,DNS:$GITLAB_DOMAIN"
  fi
  openssl x509 -in $SSL_CERT_PATH/$GITLAB_DOMAIN.crt -noout -text | grep "DNS:"

  _logger info "add the certificate to the system CA trust store"
  cp -fv $SSL_CERT_PATH/$GITLAB_DOMAIN.crt /etc/pki/ca-trust/source/anchors/
  update-ca-trust

  ## Pre-acquired environment resource specifications
  local total_memory_mb=$(grep MemTotal /proc/meminfo | awk '{printf "%d", $2/1024}')
  # Calculate PostgreSQL's shared_buffers recommended value: 25% of total memory, maximum 8192MB
  local shared_buffers_mb=$(awk -v mem_mb="$total_memory_mb" 'BEGIN {sb=mem_mb*0.25; sb=(sb>8192)?8192:sb; printf "%d", sb}')
  # Calculate the recommended Redis memory value: 30% of total memory, unit: MB
  local redis_max_memory_mb=$(( total_memory_mb * 30 / 100 ))

  tee $GITLAB_CONF <<-EOF
################################################################################
## Core Network and Security Configuration
################################################################################

## Access URLs and HTTPS
external_url 'https://$GITLAB_DOMAIN'
nginx['listen_addresses'] = ['$BIND_IP']  # listen on all IPv4 and IPv6 addresses
nginx['listen_port'] = $BIND_PORT
nginx['http2_enabled'] = true
nginx['redirect_http_to_https'] = true
# use Let's Encrypt automatic certificate
letsencrypt['enable'] = $AUTO_CERT
letsencrypt['contact_emails'] = ['admin@example.com']
letsencrypt['auto_renew'] = true
letsencrypt['auto_renew_hour'] = 0     # check for renewal at 0:00 daily
# or manually specify certificate path
# nginx['ssl_certificate'] = "$SSL_CERT_PATH/$GITLAB_DOMAIN.crt"
# nginx['ssl_certificate_key'] = "$SSL_CERT_PATH/$GITLAB_DOMAIN.key"
nginx['client_max_body_size'] = '1024m'  # support large file uploads

## SSH Service Configuration
gitlab_rails['gitlab_shell_ssh_port'] = 22
gitlab_rails['gitlab_shell_ssh_host'] = '$BIND_IP'
gitlab_rails['gitlab_shell_git_timeout'] = 600   # adjust timeout duration

## Firewall and Access Control
# add trust for reverse proxies like Nginx or HAProxy
# gitlab_rails['trusted_proxies'] = ['10.0.0.0/8', '192.168.0.0/16']
# gitlab_rails['monitoring_whitelist'] = ['10.100.0.50']    # monitor IP for prometheus


## Time Zone Setting
gitlab_rails['time_zone'] = 'Asia/Shanghai'

################################################################################
## Performance Adaptive Configuration (Dynamic Resource Allocation)
################################################################################

## Puma Worker Processes (Dynamically Adjusted Based on CPU Cores)
puma['worker_processes'] = $(nproc)   # automatically get CPU core count
puma['min_threads'] = 10
puma['max_threads'] = 20
puma['somaxconn'] = 4096  # high concurrency connection queue

## Sidekiq Configuration
sidekiq['concurrency'] = 20       # based on CPU core count
sidekiq['shutdown_timeout'] = 30  # graceful shutdown timeout
sidekiq['memory_control'] = {     # memory control in version 17.9+
    'max_memory' => '4G',
    'soft_memory' => '3.5G',
    'oom_score_adj' => -500
}

## PostgreSQL Optimization
postgresql['max_connections'] = 500
postgresql['shared_buffers'] = "${shared_buffers_mb}MB"
postgresql['work_mem'] = '32MB'

## Redis Memory Policy (30% of Total Memory)
redis['maxmemory'] = "${redis_max_memory_mb}MB"
redis['maxmemory_policy'] = "volatile-lru"    # Safer for Mixed Data Scenarios


################################################################################
## Enterprise Authentication and Security
################################################################################

## Disable Public Registration
gitlab_rails['signup_enabled'] = false
gitlab_rails['password_authentication_requirements'] = {
    'minimum_length' => 8,
    'require_digit' => true,
    'require_symbol' => true
}

# ## LDAP Integration (Example: Microsoft AD)
# gitlab_rails['ldap_servers'] = YAML.load <<-'EOS'
#   main:
#     label: 'Corporate AD'
#     host: 'ad.yourcompany.com'
#     port: 636
#     encryption: 'simple_tls'
#     bind_dn: 'CN=GitLab Sync,OU=Service Accounts,DC=yourcompany,DC=com'
#     password: 's3cur3P@ssw0rd!'
#     uid: 'sAMAccountName'
#     base: 'OU=Users,DC=yourcompany,DC=com'
#     verify_certificates: true
# EOS

################################################################################
## Storage and Backup
################################################################################
## Git Repository Data
gitaly['configuration'] = {
    storage: [
    { name: 'default', path: '$GITLAB_DATA_PATH/gitlab/repositories' }
    ]
}

## Core Data Storage Paths
gitlab_rails['uploads_directory'] = "$GITLAB_DATA_PATH/gitlab/uploads"     # upload file storage
gitlab_rails['artifacts_path'] = "$GITLAB_DATA_PATH/gitlab/artifacts"      # CI/CD artifacts
gitlab_rails['lfs_storage_path'] = "$GITLAB_DATA_PATH/gitlab/lfs-objects"  # LFS large files
gitlab_rails['shared_path'] = "$GITLAB_DATA_PATH/gitlab/shared"            # shared data

## Full Backup Schedule
# local backup configuration
gitlab_rails['backup_path'] = "$GITLAB_DATA_PATH/gitlab/backups"   # local backup directory
gitlab_rails['backup_keep_time'] = 2592000                         # retain for 30 days

# # (Optional) Upload to Object Storage (Example: AWS S3)
# gitlab_rails['object_store']['enabled'] = true
# gitlab_rails['object_store']['connection'] = {
#   'provider' => 'AWS',
#   'region' => 'us-east-1',
#   'aws_access_key_id' => 'AKIAXXX',
#   'aws_secret_access_key' => 'SECRETXXX'
# }
# gitlab_rails['object_store']['objects']['artifacts']['bucket'] = "gitlab-artifacts-prod"


################################################################################
## Monitoring and Logging
################################################################################

## Prometheus Monitoring
prometheus['monitor_kubernetes'] = $ENABLE_PROMETHEUS    # can be disabled when memory is low
prometheus['listen_address'] = '0.0.0.0:9090'

# ## Grafana Integration
# grafana['enable'] = $ENABLE_GRAFANA
# grafana['admin_password'] = 'grafana-admin-p@ss'

## Log Management
# GitLab Rails application logs
gitlab_rails['log_group'] = 'git'
gitlab_rails['log_directory'] = '/var/log/gitlab/gitlab-rails'
# global log definition
logging['log_directory'] = '/var/log/gitlab'
logging['log_group'] = 'git'
logging['log_permissions'] = '0700'
# log rotation policy
logging['logrotate_compress'] = 'compress'
logging['logrotate_frequency'] = 'daily'
logging['logrotate_rotate'] = 30    # retain 30 days of logs


################################################################################
## Email Service Configuration (Corporate Email Example)
################################################################################

## Enable SMTP and Configure Tencent Corporate Email
gitlab_rails['smtp_enable'] = $ENABLE_SMTP
gitlab_rails['smtp_address'] = "smtp.qq.com"
gitlab_rails['smtp_port'] = 465
gitlab_rails['smtp_user_name'] = "12345678@qq.com"
gitlab_rails['smtp_password'] = "xxxxxxxx"
gitlab_rails['smtp_domain'] = "qq.com"
gitlab_rails['smtp_authentication'] = "login"
gitlab_rails['smtp_tls'] = true
gitlab_rails['smtp_enable_starttls_auto'] = false

## Sender Information Customization
user['git_user_email'] = "12345678@qq.com"
gitlab_rails['gitlab_email_from'] = "12345678@qq.com"
gitlab_rails['gitlab_email_display_name'] = "GitLab Server"


################################################################################
## High Availability Configuration (Multi-Node Example)
################################################################################

# ## PostgreSQL Master/Slave
# postgresql['ha'] = true
# postgresql['master_node'] = 'pg-master.yourcompany.com'
# postgresql['slave_nodes'] = ['pg-replica1.yourcompany.com', 'pg-replica2.yourcompany.com']

# ## Redis Sentinel
# redis['master_name'] = 'gitlab-redis'
# redis['sentinels'] = [
#   {'host' => 'sentinel1.yourcompany.com', 'port' => 26379},
#   {'host' => 'sentinel2.yourcompany.com', 'port' => 26379}
# ]


################################################################################
## Containerization Extensions
################################################################################

# ## Kubernetes Integration
# gitlab_rails['gitlab_kas_enabled'] = true
# gitlab_rails['gitlab_kas_external_url'] = 'ws://yourcompany.com/-/kubernetes-agent/'

# ## Container Registry High Availability
# registry['storage'] = {
#   's3' => {
#     'bucket' => 'gitlab-registry-prod',
#     'region' => 'us-east-1'
#   }
# }
EOF

  _logger info "6. Starting and checking gitlab releated services"
  gitlab-ctl show-config && gitlab-ctl reconfigure
  if ! gitlab-ctl restart && sleep 5 && gitlab-ctl status; then
    _logger error "There are services that failed to start.
    Please refer to the following commands for checking:
    gitlab-ctl tail <name-of-failed-service>"
  fi

  _logger info "7. Check and open the corresponding firewall ports, and test remote connection"
  if systemctl status firewalld | grep "active (running)" &>/dev/null; then
    # web, Git repository SSH cloning and pushing, Redis/PostgreSQL,
    # Git protocol, Prometheus/Alertmanager, Sidekiq background tasks
    firewall-cmd --add-port={80,443,22,6379,5432,9418,9090,9093,25760}/tcp --permanent &>/dev/null
    firewall-cmd --reload &>/dev/null
    echo -e "Current open ports in the firewall: ${green}$(firewall-cmd --list-ports)${reset}"
  else
    _logger warn "System firewalld is currently disabled."
  fi


  _print_line split -
  _logger info "Gitlab has been installed successfully.
${green}Summary:
  Version: please run ${blue}gitlab-rake gitlab:env:info ${green}to show
  Config: $GITLAB_CONF
  Certs dir: $SSL_CERT_PATH
  Data dir: $GITLAB_DATA_PATH

${blue}Web:
  Access URL: https://$GITLAB_DOMAIN
  User: root
  Password: $GITLAB_ROOT_PASSWORD
  /**
    **   If the browser reports an insecure connection,
    **   enter "thisisunsafe" to trust the certificate and bypass the alert.
    **/

${yellow}Other:
  If you have a requirement for a complete backup and restore of GitLab instance data,
  please follow the steps below:
    1. Complete instance backup
      gitlab-rake gitlab:backup:create
    2. Backup core configurations
      cp -v /etc/gitlab/{gitlab.rb,gitlab-secrets.json} ./
    3. Install the same version of GitLab on the new machine
    4. Stop processes connected to the database
      gitlab-ctl stop puma && gitlab-ctl stop sidekiq
    5. Restore from backup file
      mv ./{gitlab.rb,gitlab-secrets.json} /etc/gitlab/
      gitlab-rake gitlab:backup:restore BACKUP=1742328467_2025_03_19_14.1.7
    6. Restart GitLab
      gitlab-ctl restart
  "
}


function remove() {
  _print_line title "Remove Gitlab"

  _logger info "1. Stop gitlab related service"
  gitlab-ctl stop || { _logger error "Gitlab is not installed." && exit 1; }

  _logger info "2. Remove gitlab related package and cache"
  rm -rvf /etc/yum.repos.d/gitlab_gitlab-ce.repo*
  dnf remove -y gitlab-ce
  dnf clean all

  _logger info "3. Delete files"
  rm -rvf /etc/gitlab /var/log/gitlab /var/opt/gitlab

  _logger info "4. Delete related user"
  for u in git gitlab-redis gitlab-www gitlab-psql registry gitlab-prometheus; do
    id $u && userdel $_
  done

  _print_line split -
  _logger info "Gitlab has been removed successfully."
}


function main() {
  function _help() {
    printf "Invalid option ${@:1}\n"
    printf "${green}Usage: ${reset}\n"
    printf "    ${gray}bash ${blue}$0 ${green}install ${gray}my.gitlab.com gitlab_root_passwd(AAAaaa12#$)${reset}\n"
    printf "    ${gray}bash ${blue}$0 ${green}remove${reset}\n\n"

    printf "${yellow}Note: The gitlab root password must comply with the security policy.\n${reset}"
  }

  case $1 in
    install)
      install
      ;;
    remove)
      remove
      ;;
    *)
      _help ${@:1} && exit 1 ;;
  esac
}

main
