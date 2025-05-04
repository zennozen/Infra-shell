#!/usr/bin/env bash
# https://galaxy.ansible.com/ui/
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
  SRV_IP ANS_HOME ANS_REMOTE_USER ANS_MODULE_PATH
' ERR

# define golabal variables
HOSTNAME=$(hostname -s)
SRV_IP="$(ip -4 addr show | grep inet | grep -v 127.0.0.1 | awk 'NR==1 {print $2}' | cut -d'/' -f1)"
ANS_HOME="/etc/ansible"
ANS_REMOTE_USER="ansible"
ANS_MODULE_PATH="/usr/share/ansible/collections"

#######################################
## Main Business Logic Begins
#######################################

function install() {
  _print_line title "Install Ansible"

  ! which ansible || { _logger error "Ansible already installed on the system." && exit 1; }

  _logger info "1. Install and upgrade ansible using python3-pip, and install sshpass for the first-time password-based login"
  dnf install -y python3-pip sshpass
  python3 -m pip install --upgrade ansible-core passlib  # passlib for passwd_hash

  _logger info "ansible has been installed, the version info:"
  ansible --version

  _logger info "2. Create a local Ansible user, set the password, and configure sudo privileges"
  id $ANS_REMOTE_USER || useradd $ANS_REMOTE_USER
  echo "$ANS_REMOTE_USER:$ANS_REMOTE_USER" | chpasswd

  echo "$ANS_REMOTE_USER ALL=(ALL) NOPASSWD: ALL" | tee /etc/sudoers.d/$ANS_REMOTE_USER
  visudo -cf /etc/sudoers.d/$ANS_REMOTE_USER && chmod 440 $_

  _logger info "3. Install commonly used collections to the specified directory"
  local collections=(
    ansible.posix
    community.general
    community.network
    community.docker
  )
  ansible-galaxy collection install ${collections[@]} -p $ANS_MODULE_PATH

  _logger info "4. Init project related files"
  local PJ_PATHS=(
    run_logs
    playbooks
    inventory/{dev,sit,uat,prod}/group_vars
    roles/example/{vars,templates,tasks,handlers}
  )

  for pj_path in ${PJ_PATHS[@]}; do
    mkdir -p $ANS_HOME/$pj_path
  done

  tee $ANS_HOME/ansible.cfg <<-EOF
[defaults]
inventory = $ANS_HOME/inventory/dev/hosts
ask_pass = True
host_key_checking = False
retry_files_enabled = False
nocows = 1
roles_path = $ANS_HOME/roles
library = /usr/share/ansible/collections:/root/.ansible/collections
callbacks_enabled = community.general.log_plays
log_path = $ANS_HOME/run_logs/ansible.log
result_format = yaml

[privilege_escalation]
become = True
become_method = sudo
become_user = root
EOF

  tee $ANS_HOME/inventory/dev/hosts <<-EOF
[example]
# $HOSTNAME ansible_host=$SRV_IP
EOF

  tee $ANS_HOME/inventory/dev/group_vars/all.yml <<-EOF
ansible_python_interpreter: /usr/bin/python3
ansible_connection: ssh
ansible_ssh_extra_args: "-o ControlMaster=auto -o ControlPersist=60s"
ansible_ruser: $ANS_REMOTE_USER
ansible_ruser_passwd: $ANS_REMOTE_USER
EOF

  tee $ANS_HOME/playbooks/00_create_ruser.yml <<-EOF
---
- name: 01 Create user and setup SSH key for local and remote hosts
  hosts: all
  become: yes
  vars:
    ssh_key_comment: "Ansible SSH Key"
    ssh_key_bits: 2048
    ssh_key_file: "/home/{{ ansible_ruser }}/.ssh/id_rsa"

  tasks:
    - name: 00.01 Generate SSH key for existing local user
      ansible.builtin.user:
        name: "{{ ansible_ruser }}"
        generate_ssh_key: yes
        ssh_key_bits: "{{ ssh_key_bits }}"
        ssh_key_file: "{{ ssh_key_file }}"
        ssh_key_comment: "{{ ssh_key_comment }}"
      delegate_to: localhost
      register: control_user

    - name: 00.02 Create user on remote hosts
      ansible.builtin.user:
        name: "{{ ansible_ruser }}"
        state: present
        shell: /bin/bash
        create_home: yes
        password: "{{ ansible_ruser_passwd | password_hash('sha512') }}"

    - name: 00.03 Add SSH public key to remote hosts
      ansible.builtin.authorized_key:
        user: "{{ ansible_ruser }}"
        state: present
        key: "{{ lookup('file', control_user.ssh_key_file + '.pub') }}"

    - name: 00.04 Add remote host key to local known_hosts
      ansible.builtin.known_hosts:
        name: "{{ hostvars[item].ansible_host }}"
        key: "{{ lookup('pipe', 'ssh-keyscan -t rsa ' + hostvars[item].ansible_host) }}"
        path: "/home/{{ ansible_ruser }}/.ssh/known_hosts"
        state: present
      loop: "{{ groups['all'] }}"
      delegate_to: localhost
      notify: fix_known_hosts_permissions

    #- name: Configure sudoers to allow passwordless sudo for user
    #  ansible.builtin.lineinfile:
    #    path: /etc/sudoers
    #    state: present
    #    regexp: '^{{ ansible_ruser }}'
    #    line: '{{ ansible_ruser }} ALL=(ALL) NOPASSWD: ALL'
    #    validate: 'visudo -cf %s'

    - name: 00.05 Configure sudoers to allow passwordless sudo for user
      community.general.sudoers:
        name: "{{ ansible_ruser }}"
        user: "{{ ansible_ruser }}"
        commands: ALL
        nopassword: yes
        state: present

  handlers:
    - name: fix_known_hosts_permissions
      ansible.builtin.file:
        path: "/home/{{ ansible_ruser }}/.ssh/known_hosts"
        owner: "{{ ansible_ruser }}"
        group: "{{ ansible_ruser }}"
        mode: '0644'
      delegate_to: localhost
EOF

  _print_line split -
  _logger info "The installation and environment preparation of Ansible have been successfully completed."
  echo -e "${green}  Ansible root dir: $ANS_HOME${reset}"
  echo -e "${green}  Ansible remote user/passwd: $ANS_REMOTE_USER/$ANS_REMOTE_USER${reset}"

  printf "\n${green}Initialize remote users and distribute SSH key-based authentication using a playbook:
  ${yellow}1. Update the remote hosts list:
  ${green}    vim $ANS_HOME/inventory/dev/hosts
  ${yellow}2. Run the playbook to initialize and create users with SSH key-based authentication:
  ${green}    ansible-playbook -i $ANS_HOME/inventory/dev/hosts $ANS_HOME/playbooks/00_create_ruser.yml
  ${reset}"
}

function remove(){
  which ansible || { _logger error "Ansible is not installed." && exit 1; }

  _print_line title "Remove Ansible"

  _logger info "1. Remove remote user and restore settings"
  tee /tmp/remove_ruser.yml <<-EOF
---
- name: 01 Remove user and remove SSH key for local and remote hosts
  hosts: all
  become: yes

  tasks:
    - name: 00.01 Remove user from sudoers on remote hosts
      community.general.sudoers:
        name: "{{ ansible_ruser }}"
        state: absent

    - name: 00.02 Remove user on remote hosts
      ansible.builtin.user:
        name: "{{ ansible_ruser }}"
        state: absent
        remove: yes
EOF
  _logger info "Start executing this playbook ..."
  ansible-playbook /tmp/remove_ruser.yml

  _logger info "2. Remove ansible package"
  python3 -m pip uninstall -y ansible-core passlib
  dnf remove -y python3-pip sshpass

  _logger info "3. Remove local ansible user and restore settings"
  id $ANS_REMOTE_USER && userdel -r $_
  rm -rvf /etc/sudoers.d/$ANS_REMOTE_USER

  _logger info "4. Delete related files"
  rm -rvf $ANS_HOME /root/.ansible /var/lib/ansible /tmp/remove_ruser.yml

  _print_line split -
  _logger info "Ansible has been removed successfully."
}


function main() {
  function _help() {
    printf "Invalid option ${@:1}\n"
    printf "${green}Usage: ${reset}\n"
    printf "    ${gray}bash ${blue}$0 ${green}install${reset}\n"
    printf "    ${gray}bash ${blue}$0 ${green}remove${reset}\n"
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
