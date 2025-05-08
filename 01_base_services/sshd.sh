#!/usr/bin/env bash
set -o errexit

script_path="$(dirname ${BASH_SOURCE[0]})"
abs_script_path="$(realpath "${BASH_SOURCE[0]}")"
workdir="$(dirname "$abs_script_path")"

# import some define
source "$script_path/../00_utils/_print.sh"
source "$script_path/../00_utils/_logger.sh"

# define global variables
SSHD_CONF="/etc/ssh/sshd_config"

_print_line title "Install and update sshd service"

# install sshd service
_logger info "Check and install sshd"
which ssh || dnf install -y sshd
_print_line split -
ls -ld /etc/ssh/*
_print_line split -

# backup and update config
_logger info "Backup and update sshd config"
[[ -f $SSHD_CONF ]] && cp -v $SSHD_CONF ${SSHD_CONF}_$(date +'%Y%m%d-%H%M').bak
tee $SSHD_CONF <<-EOF
Port 22
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
SyslogFacility AUTHPRIV
ChallengeResponseAuthentication no
GSSAPIAuthentication yes
GSSAPICleanupCredentials no
UsePAM yes
PrintMotd no
MaxAuthTries 3
MaxSessions 10
ClientAliveInterval 300
ClientAliveCountMax 3
PermitEmptyPasswords no
UseDNS no
AllowTcpForwarding no
X11Forwarding yes
LogLevel INFO
Subsystem sftp /usr/libexec/openssh/sftp-server
EOF

# check config
if sshd -t; then
  _logger info "$SSHD_CONF check passed successfully."
else
  _logger error "$SSHD_CONF check failed."
  exit 1
fi

# start service
_logger info "Start/Restart sshd service"
systemctl restart sshd && systemctl enable $_ && systemctl status --no-pager $_

_print_line split -
_logger info "sshd service deployed successfully!"

