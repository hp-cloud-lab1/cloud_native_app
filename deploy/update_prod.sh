#!/bin/bash -xe

WORKDIR="$(dirname $0)"

cleanup() {
    docker kill "$DOCKER_ID"
    docker rm "$DOCKER_ID"
}

docker pull treens/hp-testenv

DOCKER_ID="$(docker run --privileged --cap-add=NET_ADMIN -d hp-deploy sleep infinity)"

set -e

trap "cleanup" ERR

docker cp -L "$HOME/VPN" "$DOCKER_ID:/root/VPN"
docker exec -dw /root/VPN "$DOCKER_ID" openvpn vpnlab2017.conf

# Wait for the VPN client to get connected
sleep 10

docker cp -L "$WORKDIR" "$DOCKER_ID:/root/CNA"
docker cp -L "$HOME/.ssh/deploy-key.pem" "$DOCKER_ID:/root"
docker cp -L "$HOME/.ssh/key-prod.pem" "$DOCKER_ID:/root"

MANAGER_IP="$(docker-machine ssh manager-prod ip addr show | grep inet | grep 192.168. | cut -d' ' -f 6 | sed -E 's|/[0-9]+||')"

docker exec -dw "/root/CNA/deploy" "$DOCKER_ID" bash -mx <<'EOF'
export OS_USERNAME="cna-prod"
export OS_PASSWORD="$(cat $HOME/.os_prod_pwd)"
export OS_AUTH_URL="http://$PROD_ENDPOINT:5000/v3"
export OS_PROJECT_NAME="CNA-PROD"
export OS_TENANT_NAME="CNA-PROD"
export OS_FLAVOR_NAME="m1.large"
export OS_IMAGE_NAME="Ubuntu 16.04"
export OS_DOMAIN_ID="default"
export OS_NETWORK_NAME="swarm"
export OS_SECURITY_GROUPS="default,swarm"
export OS_SSH_USER="ubuntu"
export OS_FLOATINGIP_POOL="public"

NB_AGENTS=2

LOCAL_9696=4242
LOCAL_MANAGER_2376=4243
LOCAL_AGENTS_2376=($(seq 4244 "$((NB_AGENTS+4243))"))
LOCAL_MANAGER_2377=4241
LOCAL_AGENTS_2377=($(seq 4240 -1 "$((4241-NB_AGENTS))"))

DEPLOY_DEV_IP="10.11.53.16"
DEPLOY_PROD_IP="10.11.54.10"
PROD_ENDPOINT="10.11.51.138"

# Bypass firewall

iptables -t nat -A OUTPUT -j DNAT -d "$PROD_ENDPOINT" -p tcp --dport 9696 --to-destination 127.0.0.1:"$LOCAL_9696"

manager_ext_ip="$(docker-machine ip manager-prod)"
MANAGER_IP="$(docker-machine ssh manager-prod ip addr show | grep inet | grep 192.168. | cut -d' ' -f 6 | sed -E 's|/[0-9]+||')"

ssh -oStrictHostKeyChecking=no -i "$HOME/key-prod.pem" -4NL "$LOCAL_MANAGER_2376":"$MANAGER_IP":2376 ubuntu@"$DEPLOY_PROD_IP" &
sleep 1
ssh -oStrictHostKeyChecking=no -i "$HOME/key-prod.pem" -4NL "$LOCAL_MANAGER_2377":"$MANAGER_IP":2377 ubuntu@"$DEPLOY_PROD_IP" &

iptables -t nat -A OUTPUT -j DNAT -d "$manager_ext_ip" -p tcp --dport 2376 --to-destination 127.0.0.1:"$LOCAL_MANAGER_2376"
iptables -t nat -A OUTPUT -j DNAT -d "$manager_ext_ip" -p tcp --dport 2377 --to-destination 127.0.0.1:"$LOCAL_MANAGER_2377"

for i in $(seq 1 "$NB_AGENTS"); do
agent_ext_ip="$(docker-machine ip agent-prod-"$i")"1
    agent_ip="$(docker-machine ssh agent-prod-"$i" ip addr show | grep inet | grep 192.168. | cut -d' ' -f 6 | sed -E 's|/[0-9]+||')"

    ssh -oStrictHostKeyChecking=no -i "$HOME/key-prod.pem" -4NL "${LOCAL_AGENTS_2376[$((i-1))]}":"$agent_ip":2376 ubuntu@"$DEPLOY_PROD_IP" &
    sleep 1
    ssh -oStrictHostKeyChecking=no -i "$HOME/key-prod.pem" -4NL "${LOCAL_AGENTS_2377[$((i-1))]}":"$agent_ip":2377 ubuntu@"$DEPLOY_PROD_IP" &

    iptables -t nat -A OUTPUT -j DNAT -d "$agent_ext_ip" -p tcp --dport 2376 --to-destination 127.0.0.1:"${LOCAL_AGENTS_2376[$((i-1))]}"
    iptables -t nat -A OUTPUT -j DNAT -d "$agent_ext_ip" -p tcp --dport 2377 --to-destination 127.0.0.1:"${LOCAL_AGENTS_2377[$((i-1))]}"
done

sleep 10

# Start the update

eval $(docker-machine env manager-prod)

./docker_services.sh
EOF

trap "" ERR
set +e

cleanup
