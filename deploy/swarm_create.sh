#!/bin/bash -xm

set -xm

NB_AGENTS=2

LOCAL_9696=4242
LOCAL_MANAGER_2376=4243
LOCAL_AGENTS_2376=($(seq 4244 "$((NB_AGENTS+4243))"))
LOCAL_MANAGER_2377=4241
LOCAL_AGENTS_2377=($(seq 4240 -1 "$((4241-NB_AGENTS))"))

DEPLOY_DEV_IP="10.11.53.16"
DEPLOY_PROD_IP="10.11.54.10"
PROD_ENDPOINT="10.11.51.138"

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

alias docker="sudo docker"

# Bypass firewall
ssh -oStrictHostKeyChecking=no -i "$HOME/deploy-key.pem" -4NL "$LOCAL_9696":"$PROD_ENDPOINT":9696 ubuntu@"$DEPLOY_DEV_IP" &
iptables -t nat -A OUTPUT -j DNAT -d "$PROD_ENDPOINT" -p tcp --dport 9696 --to-destination 127.0.0.1:"$LOCAL_9696"

cleanup() {
    set +E
    HOSTS="$(docker-machine ls -f "{{.Name}}")"

    if [ -n "$HOSTS" ]; then
        docker-machine rm -y $HOSTS
    fi

    kill $(jobs -p)
}

docker-machine create --engine-storage-driver overlay2 --driver openstack manager-prod
status="$?"

tries=0
until [ "$status" -eq 0 -o "$tries" -eq 5 ]; do
    docker-machine provision manager-prod
    status="$?"
    tries="$((tries+1))"
done

MANAGER_IP="$(docker-machine ssh manager-prod ip addr show | grep inet | grep 192.168. | cut -d' ' -f 6 | sed -E 's|/[0-9]+||')"

# Bypass firewall

ssh -oStrictHostKeyChecking=no -i "$HOME/key-prod.pem" -4NL "$LOCAL_MANAGER_2376":"$MANAGER_IP":2376 ubuntu@"$DEPLOY_PROD_IP" &
iptables -t nat -A OUTPUT -j DNAT -d "$MANAGER_IP" -p tcp --dport 2376 --to-destination 127.0.0.1:"$LOCAL_MANAGER_2376"
ssh -oStrictHostKeyChecking=no -i "$HOME/key-prod.pem" -4NL "$LOCAL_MANAGER_2377":"$MANAGER_IP":2377 ubuntu@"$DEPLOY_PROD_IP" &
iptables -t nat -A OUTPUT -j DNAT -d "$MANAGER_IP" -p tcp --dport 2377 --to-destination 127.0.0.1:"$LOCAL_MANAGER_2377"

for i in $(seq 1 "$NB_AGENTS"); do
    docker-machine create --engine-storage-driver overlay2 --driver openstack agent-prod-"$i"
    status="$?"

    tries=0
    until [ "$status" -eq 0 -o "$tries" -eq 5 ]; do
        docker-machine provision agent-prod-"$i"
        status="$?"
        tries="$((tries+1))"
    done

    agent_ip="$(docker-machine ssh agent-prod-"$i" ip addr show | grep inet | grep 192.168. | cut -d' ' -f 6 | sed -E 's|/[0-9]+||')"

    # Bypass firewall

    ssh -oStrictHostKeyChecking=no -i "$HOME/key-prod.pem" -4NL "${LOCAL_AGENTS_2376[$((i-1))]}":"$agent_ip":2376 ubuntu@"$DEPLOY_PROD_IP" &
    iptables -t nat -A OUTPUT -j DNAT -d "$agent_ip" -p tcp --dport 2376 --to-destination 127.0.0.1:"${LOCAL_AGENTS_2376[$((i-1))]}"
    ssh -oStrictHostKeyChecking=no -i "$HOME/key-prod.pem" -4NL "${LOCAL_AGENTS_2377[$((i-1))]}":"$agent_ip":2377 ubuntu@"$DEPLOY_PROD_IP" &
    iptables -t nat -A OUTPUT -j DNAT -d "$agent_ip" -p tcp --dport 2377 --to-destination 127.0.0.1:"${LOCAL_AGENTS_2377[$((i-1))]}"
done

set -eE
trap "cleanup" ERR

docker-machine scp "$HOME/proddockerCA.crt" manager-prod:/tmp

docker-machine ssh manager-prod <<'EOF'
sudo mkdir /usr/local/share/ca-certificates/docker-dev-cert
sudo mv /tmp/proddockerCA.crt /usr/local/share/ca-certificates/docker-dev-cert
sudo update-ca-certificates
EOF

for i in $(seq 1 "$NB_AGENTS"); do
    docker-machine scp "$HOME/proddockerCA.crt" agent-prod-"$i":/tmp

    docker-machine ssh agent-prod-"$i" <<'EOF'
sudo mkdir /usr/local/share/ca-certificates/docker-dev-cert
sudo mv /tmp/proddockerCA.crt /usr/local/share/ca-certificates/docker-dev-cert
sudo update-ca-certificates
EOF
done

eval $(docker-machine env manager-prod)
docker swarm init
TOKEN="$(docker swarm join-token -q worker)"

for i in $(seq 1 "$NB_AGENT"); do
    eval $(docker-machine env agent-prod-"$i")
    docker swarm join --token "$TOKEN" manager-prod "$MANAGER_IP"
done

kill $(jobs -p)
