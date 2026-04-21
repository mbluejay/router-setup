#!/bin/bash
set -eu

if [ $# -lt 1 ] || [ -z "$1" ]; then
    echo "usage: ./add-direct.sh <domain>" >&2
    exit 1
fi

DIR="$(cd "$(dirname "$0")" && pwd)"

export DISPLAY=:0
export SSH_ASKPASS="$DIR/askpass.sh"
export SSH_ASKPASS_REQUIRE=force

ssh -o StrictHostKeyChecking=no \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    root@192.168.2.1 "/usr/local/bin/xray-add-direct $1" < /dev/null
