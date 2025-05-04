#!/usr/bin/env bash
set -o errexit

script_path="$(dirname ${BASH_SOURCE[0]})"
abs_script_path="$(realpath "${BASH_SOURCE[0]}")"
workdir="$(dirname "$abs_script_path")"
# import some define
source "$script_path/../00_utils/_print.sh"
source "$script_path/../00_utils/_logger.sh"
source "$script_path/../00_utils/_trap.sh"

# capture errors and print environment variables
trap '_trap_print_env \
  ID
' ERR

function _rocky_linux_repo() {
  tee /etc/yum.repos.d/rockyLinux-alicloud.repo <<-EOF
[baseos]
name=Rocky Linux \$releasever - BaseOS
baseurl=https://mirrors.aliyun.com/rockylinux/\$releasever/BaseOS/\$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-\$releaserver

[appstream]
name=Rocky Linux \$releasever - AppStream
baseurl=https://mirrors.aliyun.com/rockylinux/\$releasever/AppStream/\$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-\$releaserver

[crb]
name=Rocky Linux \$releasever - CRB
baseurl=https://mirrors.aliyun.com/rockylinux/\$releasever/CRB/\$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-\$releaserver

[extras]
name=Rocky Linux \$releasever - Extras
baseurl=https://mirrors.aliyun.com/rockylinux/\$releasever/extras/\$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-\$releaserver

[devel]
name=Rocky Linux \$releasever - Devel
baseurl=https://mirrors.aliyun.com/rockylinux/\$releasever/devel/\$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-\$releaserver
EOF

  tee /etc/yum.repos.d/epel.repo <<-EOF
[epel]
name=Extra Packages for Linux \$releasever - \$basearch
baseurl=https://mirrors.aliyun.com/epel/\$releasever/Everything/\$basearch/
gpgcheck=1
enabled=1
gpgkey=https://mirrors.aliyun.com/epel/RPM-GPG-KEY-EPEL-\$releasever
EOF

  dnf repolist
  dnf makecache --refresh
}

function _centos_repo() {
  tee /etc/yum.repos.d/centos-alicloud.repo <<-EOF
[BaseOS]
name=CentOS Stream \$releasever - BaseOS
baseurl=https://mirrors.aliyun.com/centos-stream/\$releasever-stream/BaseOS/x86_64/os/
gpgcheck=1
enabled=1
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-Official

[AppStream]
name=CentOS Stream \$releasever - AppStream
baseurl=https://mirrors.aliyun.com/centos-stream/\$releasever-stream/AppStream/x86_64/os/
gpgcheck=1
enabled=1
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-Official

[CRB]
name=CentOS Stream \$releasever - CRB
baseurl=https://mirrors.aliyun.com/centos-stream/\$releasever-stream/CRB/x86_64/os/
gpgcheck=1
enabled=1
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-Official
EOF

  tee /etc/yum.repos.d/epel.repo <<-EOF
[epel]
name=Extra Packages for Linux \$releasever - \$basearch
baseurl=https://mirrors.aliyun.com/epel/\$releasever/Everything/\$basearch/
gpgcheck=1
enabled=1
gpgkey=https://mirrors.aliyun.com/epel/RPM-GPG-KEY-EPEL-\$releasever
EOF

  dnf repolist
  dnf makecache --refresh
}

function _openeluer_repo() {
  tee > /etc/yum.repos.d/openEuler-huaweiCloud.repo <<-EOF
[openEuler-everything]
name=openEuler 24 - everything
baseurl=http://repo.huaweicloud.com/openeuler/openEuler-24.03-LTS/everything/x86_64/
enabled=1
gpgcheck=1
gpgkey=http://repo.huaweicloud.com/openeuler/openEuler-24.03-LTS/everything/x86_64/RPM-GPG-KEY-openEuler

[openEuler-EPOL]
name=openEuler 24 - epol
baseurl=http://repo.huaweicloud.com/openeuler/openEuler-24.03-LTS/EPOL/main/x86_64/
enabled=1
gpgcheck=0

[openEuler-update]
name=openEuler 24 - update
baseurl=http://repo.huaweicloud.com/openeuler/openEuler-24.03-LTS/update/x86_64/
enabled=1
gpgcheck=0
EOF

  tee /etc/yum.repos.d/epel.repo <<-EOF
[epel]
name=Extra Packages for Linux \$releasever - \$basearch
baseurl=https://mirrors.aliyun.com/epel/\$releasever/Everything/\$basearch/
gpgcheck=1
enabled=1
gpgkey=https://mirrors.aliyun.com/epel/RPM-GPG-KEY-EPEL-\$releasever
EOF

  dnf repolist
  dnf makecache --refresh
}

function _ubuntu_repo() {
  tee > /etc/apt/ubuntu.list <<-EOF
deb https://mirrors.aliyun.com/ubuntu/ noble main restricted universe multiverse
deb-src https://mirrors.aliyun.com/ubuntu/ noble main restricted universe multiverse

deb https://mirrors.aliyun.com/ubuntu/ noble-security main restricted universe multiverse
deb-src https://mirrors.aliyun.com/ubuntu/ noble-security main restricted universe multiverse

deb https://mirrors.aliyun.com/ubuntu/ noble-updates main restricted universe multiverse
deb-src https://mirrors.aliyun.com/ubuntu/ noble-updates main restricted universe multiverse

deb https://mirrors.aliyun.com/ubuntu/ noble-backports main restricted universe multiverse
deb-src https://mirrors.aliyun.com/ubuntu/ noble-backports main restricted universe multiverse
EOF

  apt update
  apt apt-cache policy
}



function main() {
  [[ -f /etc/os-release ]] || { _logger error "Cannot determine OS type." && exit 1; }
  . /etc/os-release

  _print_line title "Add yum repo for $ID"
  case $ID in
    rocky)
      _rocky_linux_repo
      ;;
    centos)
      _centos_repo
      ;;
    openeluer)
      _openeluer_repo
      ;;
    ubuntu)
      _ubuntu_repo
      ;;
    *)
      _logger error "Unsupported OS: $ID."
      ;;
  esac
}

main