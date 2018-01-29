#!/bin/bash -xe

WORKDIR="$PWD"

cleanup() {
    docker kill "$DOCKER_ID"
    docker rm "$DOCKER_ID"
}

docker pull treens/hp-testenv

DOCKER_ID="$(docker run --privileged --cap-add=NET_ADMIN -dw /root/VPN hp-deploy openvpn vpnlab2017.conf)"

set -e

trap "cleanup" ERR

# Wait for the VPN client to get connected
sleep 10

docker cp -L "$WORKDIR" "$DOCKER_ID:/root/CNA"
docker cp -L "$HOME/.ssh/deploy-key.pem" "$DOCKER_ID:/root"
docker cp -L "$HOME/.ssh/key-prod.pem" "$DOCKER_ID:/root"

docker exec -w "/root/CNA/deploy" "$DOCKER_ID" /root/update.sh

trap "" ERR
set +e

cleanup
