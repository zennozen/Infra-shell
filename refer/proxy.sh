#!/usr/bin/env bash
set -o errexit

tee >> ~/.bashrc <<-EOF

#################################### proxy start ######################################
function proxy_verify() {
    if curl --silent --head --max-time 3 https://www.google.com/ | grep "HTTP.*200" > /dev/null; then
        echo "Google is reachable."
        return 0
    else
        echo "Google unreachable."
        return 1
    fi
}

function proxy_off(){
    unset http_proxy https_proxy socks_proxy
    echo "Terminal proxy disabled."
}

function proxy_on() {
    # The LAN endpoint of the host's VMnet8 for Clash Verge.
    PROXY_ENDPOINT="192.168.55.1:7897"

    export http_proxy="http://\$PROXY_ENDPOINT"
    export https_proxy="http://\$PROXY_ENDPOINT"
    export socks_proxy="socks5://\$PROXY_ENDPOINT"
    no_proxy="localhost,127.0.0.1,192.168.*,10.*,172.16.*,.example.com"
    echo -e "Terminal proxy enabled, Windows proxy endpoint: \$PROXY_ENDPOINT."

    proxy_verify || { echo "Falling back to disable proxy." && proxy_off; }
}
##################################### proxy end #######################################

EOF

if [ -f ~/.bashrc ]; then
    source ~/.bashrc
fi

proxy_on
