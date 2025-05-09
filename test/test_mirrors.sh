#!/usr/bin/env bash
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
  docker_mirrors test_imgs containerd_acceleration_dir
' ERR

# define golabal variables
dep_script="containerd_with_nerdctl.sh"
containerd_acceleration_dir="/etc/containerd/certs.d"
nerdctl_ver="2.0.5"
docker_mirrors=(
  "https://docker.m.daocloud.io"
  "https://register.librax.org"
  "https://docker.1ms.run"
  "https://docker.hlmirror.com"
  "https://docker-0.unsee.tech"
  "https://lispy.org"
  "https://docker.actima.top"
  "https://docker.xiaogenban1993.com"
)
test_docker_imgs=(
  "docker.io/calico/apiserver:v3.29.3"
  "docker.io/calico/node:v3.29.3"
)
k8s_mirrors=(
  "k8s.m.daocloud.io"
)
test_k8s_imgs=(
  "registry.k8s.io/kube-apiserver:v1.29.15"
  "registry.k8s.io/pause:3.9"
)


#######################################
## Main Business Logic Begins
#######################################

function chk_cri() {
  _print_line title "1. Check container runtime environment"

  if ! which nerdctl >/dev/null || ! which containerd >/dev/null; then
    _logger warn "Container runtime environment is missing. Will invoke script $dep_script to install automatically."
    cd $workdir
    [[ -f $dep_script ]] || { cd .. && bash build gr $dep_script && cd $workdir; }
    [[ -f $dep_script ]] || { _logger error "Missing script $dep_script in current directory. Please check." && exit 1; }
    bash $dep_script install $nerdctl_ver || { _logger error "Script $dep_script failed, exit code $?" && exit 1; }
  fi

  if which nerdctl && which containerd >/dev/null; then
    _logger info "1.1 Container runtime environment is available. Version details:"
    nerdctl version
  fi

  _logger info "1.2 Clear previous acceleration configurations and historical images."
  rm -rvf $containerd_acceleration_dir/*
  for i in ${test_imgs[@]}; do
    if nerdctl images --names | awk 'NR>1{print $1}' | grep $i; then
      nerdctl rmi -f $i
    fi
  done
}

function test_mirrors() {
  local mirror_type=$1  # docker.io, registry.k8s.io, docker.elastic.co, gcr.io, ghcr.io, quay.io, mcr.microsoft.com
  shift
  local -a mirrors=()
  local -a imgs=()
  local separator_found=false

  # handle array variable splitting
  for param in "$@"; do
    if [[ "$param" == "--" ]]; then
      separator_found=true
      continue
    fi
    if [[ "$separator_found" = false ]]; then
      mirrors+=("$param")
    else
      imgs+=("$param")
    fi
  done

  _print_line title "2. Detect the validity and speed of the ${blue}$mirror_type${green} container image acceleration sites"

  _logger info "2.1 Detect the reachability of the source station."
  if nerdctl pull ${imgs[0]} >/dev/null; then
    _logger info "$mirror_type Source station is reachable."
    nerdctl rmi ${imgs[0]} >/dev/null
    nerdctl image prune -a -f
  else
    _logger error "$mirror_type Source station is not reachable."
  fi

  _print_line split blank
  _logger info "2.2 Test accelerators"
  for m in ${mirrors[@]}; do
    # Update acceleration configuration
    mkdir -p $containerd_acceleration_dir/$mirror_type && cat > $_/hosts.toml <<-EOF
server = "https://$mirror_type"
[host."$m"]
  capabilities = ["pull", "resolve"]
EOF
    _logger info "Test accelerator ${blue}$m"
    time \
      for i in ${imgs[@]}; do
        nerdctl pull $i >/dev/null
      done
    # Clean images
    nerdctl rmi ${imgs[@]} >/dev/null
    nerdctl image prune -a -f
  done
}

function main() {
  function _help() {
    printf "Invalid option ${@:1}\n"
    printf "${green}Usage: ${reset}\n"
    printf "    ${gray}bash ${blue}$0 ${green}docker${gray}/k8s${reset}\n"
  }

  [[ $# -eq 1 ]] || { _help ${@:1}; exit 1; }
  chk_cri
  case $1 in
    docker)
      test_mirrors docker.io ${docker_mirrors[@]} -- ${test_docker_imgs[@]}
      ;;
    k8s)
      test_mirrors registry.k8s.io ${k8s_mirrors[@]} -- ${test_k8s_imgs[@]}
      ;;
    *)
      _help ${@:1}
      exit 1
  esac
}

main ${@:1}
