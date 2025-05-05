# dnf groupinstall -y "Development Tools"
dnf install -y vim tree shellcheck

development_tools=(gcc gcc-c++ make cmake clang llvm ninja-build autoconf automake pkg-config doxygen valgrind gdb git ctags cscope)
network_tools=(wget curl nmap tcpdump iftop iperf netperf traceroute whois bind-utils)
monitoring_tools=(sysstat atop htop iotop glances procps-ng lsof net-tools iproute strace)
archiving_tools=(zip unzip p7zip gzip bzip2 tar lzma xz)
sync_tools=(rsync openssh-clients ncftp lftp unison syncthing rclone duplicity)
text_processing_tools=(jq pandoc discount dos2unix diffutils patch)
terminal_tools=(zsh fish fzf tmux screen terminator bash-completion bat ripgrep)
security_tools=(openssl coreutils)
database_tools=(sqlite mysql postgresql redis)
development_libs=(glibc-devel zlib-devel openssl-devel libcurl-devel libxml2-devel libxslt-devel sqlite-devel mysql-devel postgresql-devel python3-devel java-1.8.0-openjdk-devel)