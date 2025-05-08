#!/usr/bin/env bash
set -o errexit

script_path="$(dirname ${BASH_SOURCE[0]})"
abs_script_path="$(realpath "${BASH_SOURCE[0]}")"
workdir="$(dirname "$abs_script_path")"

# import some define
source "$script_path/../00_utils/_print.sh"
source "$script_path/../00_utils/_logger.sh"

# define global variables
AUDIT_CONF="/etc/audit/auditd.conf"
AUDIT_RULES_DIR="/etc/audit/rules.d"

_print_line title "Install and update auditd service"

# install auditd service
_logger info "Check and install auditd"
[[ -n "$(ls -A /etc/audit)" ]] || dnf install -y audit
_print_line split -
ls -ld /etc/audit/*
_print_line split -

# backup and update config
_logger info "Backup and update auditd config"
[[ -f $AUDIT_CONF ]] && cp -v $AUDIT_CONF ${AUDIT_CONF}_$(date +'%Y%m%d-%H%M').bak
sed -i -e "/flush/s/INCREMENTAL_ASYNC/INCREMENTAL/g" \
  -e "/freq/s/50/20/g" \
  -e "/space_left/s/75/5%/g" \
  -e "/verify_email/s/yes/no/g" \
  -e "/tcp_client_max_idle/s/0/60/g" $AUDIT_CONF && cat $_

# start service
_logger info "Start/Restart auditd service"
# The auditd service starts via dependencies, not directly with systemctl;
# use the 'service' command instead.
service auditd restart && systemctl enable auditd && systemctl status --no-pager $_

# update audit rules
_logger info "Write and reload the audit rules"
rm -rf ${AUDIT_RULES_DIR}/audit.rules
tee ${AUDIT_RULES_DIR}/00-base-config.rules <<EOF
## First rule - delete all existing rules
-D

## Increase the buffers to survive stress events.
## Make this bigger for busy systems
-b 8192

## Set the maximum number of outstanding audit buffers allowed.
## If this limit is reached, the failure action is triggered.
--backlog_wait_time 60000

## Set failure mode to syslog
-f 1

## Set the audit failure action to syslog
-a always,exit -F arch=b64 -S adjtimex -S settimeofday -k audit_time_rules
EOF

tee ${AUDIT_RULES_DIR}/10-file-system.rules <<EOF
## Monitor critical files and directories
-a always,exit -F arch=b64 -F path=/etc/passwd -F perm=wa -k user_changes
-a always,exit -F arch=b64 -F path=/etc/group -F perm=wa -k group_changes
-a always,exit -F arch=b64 -F path=/etc/shadow -F perm=wa -k shadow_changes
-a always,exit -F arch=b64 -F path=/etc/sudoers -F perm=wa -k sudoers_changes
-a always,exit -F arch=b64 -F path=/etc/audit/auditd.conf -F perm=wa -k auditd_config_changes
-a always,exit -F arch=b64 -F path=/var/log/audit/audit.log -F perm=wa -k audit_log_changes
EOF

tee ${AUDIT_RULES_DIR}/20-file-system-ops.rules <<-EOF
## Monitor file system operations
-a always,exit -F arch=b64 -S chmod -S fchmod -S chown -S fchown -S lchown
-a always,exit -F arch=b64 -S creat -S open -S truncate -S ftruncate
-a always,exit -F arch=b64 -S mkdir -S rmdir
-a always,exit -F arch=b64 -S unlink -S rename -S link -S symlink
-a always,exit -F arch=b64 -S setxattr -S lsetxattr -S fsetxattr -S removexattr -S lremovexattr -S fremovexattr
-a always,exit -F arch=b64 -S mknod
-a always,exit -F arch=b64 -S mount -S umount2
EOF

tee ${AUDIT_RULES_DIR}/30-security-config.rules <<-EOF
## Monitor security configuration files and databases
-a always,exit -F arch=b64 -F path=/etc/hosts -F perm=wa -k hosts_changes
-a always,exit -F arch=b64 -F path=/etc/sysconfig/network -F perm=wa -k sysconfig_changes
-a always,exit -F arch=b64 -F path=/etc/sysctl.conf -F perm=wa -k sysctl_changes
-a always,exit -F arch=b64 -F path=/etc/localtime -F perm=wa -k localtime_changes
-a always,exit -F arch=b64 -F path=/etc/ssh/sshd_config -F perm=wa -k ssh_changes
-a always,exit -F arch=b64 -F path=/etc/pam.d/common-auth -F perm=wa -k pam_changes
-a always,exit -F arch=b64 -F path=/etc/pam.d/common-session -F perm=wa -k pam_changes
-a always,exit -F arch=b64 -F path=/etc/pam.d/common-password -F perm=wa -k pam_changes
-a always,exit -F arch=b64 -F path=/etc/pam.d/common-account -F perm=wa -k pam_changes
-a always,exit -F arch=b64 -F path=/etc/pam.d/common-session-noninteractive -F perm=wa -k pam_changes
-a always,exit -F arch=b64 -F path=/etc/ld.so.conf -F perm=wa -k ldsoconf_changes
#-a always,exit -F arch=b64 -F path=/etc/postfix/main.cf -F perm=wa -k postfix_changes
#-a always,exit -F arch=b64 -F path=/etc/stunnel/stunnel.conf -F perm=wa -k stunnel_changes
#-a always,exit -F arch=b64 -F path=/etc/vsftpd/vsftpd.conf -F perm=wa -k vsftpd_changes
#-a always,exit -F arch=b64 -F path=/etc/modprobe.d/blacklist.conf -F perm=wa -k modprobe_changes
#-a always,exit -F arch=b64 -F path=/etc/modprobe.conf -F perm=wa -k modprobe_conf_changes
EOF

tee ${AUDIT_RULES_DIR}/40-other-syscalls.rules <<EOF
## Monitor other system calls
#-a always,exit -F arch=b64 -S access -F a1=4  # Monitor read permissions
#-a always,exit -F arch=b64 -S access -F a1=6  # Monitor read and write permissions
#-a always,exit -F arch=b64 -S access -F a1=7  # Monitor read, write, and execute permissions
EOF

auditctl -D
augenrules --load

# show audit rules
_logger info "Show rules loaded corrently"
auditctl -l

_print_line split -
_logger info "Auditd service deployed successfully!"
