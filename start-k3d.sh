#!/bin/bash
set -euo pipefail

require_command() {
  local command_name=$1

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Missing required command: ${command_name}" >&2
    exit 1
  fi
}

port_in_use() {
  local port=$1

  ss -ltn "( sport = :${port} )" | grep -q LISTEN
}

find_available_http_port() {
  local candidate_port

  for candidate_port in $(seq 8890 8999) 18080 18081 28080 30080; do
    if ! port_in_use "${candidate_port}"; then
      echo "${candidate_port}"
      return 0
    fi
  done

  return 1
}

# set of environment variables
export CLUSTER=local-lab
httpport_was_set=${HTTPPORT+x}
export HTTPPORT=${HTTPPORT:-8889}
export K3D_SERVERS=${K3D_SERVERS:-1}
export K3D_AGENTS=${K3D_AGENTS:-2}

# DOCKER HUB variable set
export REPOHOSTNAME="https://index.docker.io/v1/"
export REPOUSERNAME="pcarlos"
export DOCKERCONFIGJSON=""
DOCKER_CONFIG_PATH="${HOME}/.docker/config.json"

for required_command in base64 docker envsubst helm k3d kubectl ss; do
  require_command "${required_command}"
done

if port_in_use "${HTTPPORT}"; then
  if [[ -n "${httpport_was_set}" ]]; then
    echo "HTTPPORT ${HTTPPORT} is already in use. Set HTTPPORT to a free port and rerun." >&2
    exit 1
  fi

  if available_http_port=$(find_available_http_port); then
    echo "HTTPPORT ${HTTPPORT} is already in use; using ${available_http_port} instead."
    export HTTPPORT="${available_http_port}"
  else
    echo "HTTPPORT ${HTTPPORT} is already in use and no fallback port was found." >&2
    exit 1
  fi
fi

# remove existing cluster
if k3d cluster list | grep -q "^${CLUSTER}[[:space:]]"; then
  echo
  echo "==== remove existing cluster"
  read -p "K3D cluster \"${CLUSTER}\" exists. Ok to delete it and restart? (y/n) " -n 1 -r
  echo
  if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
    echo "bailing out..."
    exit 1
  fi
  k3d cluster delete "${CLUSTER}"
fi  

echo 
echo "==== Docker login"
echo

if [[ -f "${DOCKER_CONFIG_PATH}" && "${FORCE_DOCKER_LOGIN:-false}" != "true" ]]; then
  echo "Reusing existing Docker credentials from ${DOCKER_CONFIG_PATH}"
  DOCKERCONFIGJSON=$(base64 -w 0 < "${DOCKER_CONFIG_PATH}")
else
  #read -p "Enter Docker username: " username
  read -sp "Enter Docker password: " password
  echo

  if echo "$password" | docker login --username "${REPOUSERNAME}" --password-stdin "${REPOHOSTNAME}"; then
    echo "Login successful to ${REPOHOSTNAME}"
    DOCKERCONFIGJSON=$(base64 -w 0 < "${DOCKER_CONFIG_PATH}")
  else
    echo "Login failed"
    exit 1
  fi

  unset password
fi

echo
echo "==== Copy certificates"
cat certs/zscaler_root_ca.crt > /tmp/zscaler_root_ca.crt
cat certs/cznet_root_2035.crt > /tmp/cznet_root_2035.crt

echo "==== create new cluster ${CLUSTER}" # "for app ${APP}:${VERSION}"
envsubst < k3d/template-k3d-config.yaml > /tmp/k3d-config.yaml
if ! k3d cluster create --config /tmp/k3d-config.yaml; then
  echo "k3d cluster creation failed." >&2
  echo "If the error mentions DOCKER-ISOLATION-STAGE-2, Docker host networking is not configured correctly." >&2
  echo "Fix the host Docker networking setup, then rerun this script." >&2
  exit 1
fi
mkdir -p "${HOME}/.kube"
k3d kubeconfig write "${CLUSTER}" --output "${HOME}/.kube/kubeconfig-${CLUSTER}.yaml"
export KUBECONFIG="${HOME}/.kube/kubeconfig-${CLUSTER}.yaml"
echo "KUBECONFIG=${KUBECONFIG}"
rm /tmp/k3d-config.yaml

echo
echo "==== Cluster nodes"
kubectl get nodes -o wide
echo
read -p "Press any key to continue..." -n 1 -r
echo

echo "---- waiting for traefik deployment"
kubectl rollout status deployment.apps traefik -n kube-system --request-timeout 5m

echo
echo "---- looking for IP of traefik"
x=0
while true; do
  loadbalancerip=$(kubectl get svc traefik --template="{{range .status.loadBalancer.ingress}}{{.ip}}{{end}}" -n kube-system)
  [[ -n "${loadbalancerip}" ]] && break
  echo -n "."
  x=$(( x + 2 ))
  [[ $x -gt 100 ]] && echo "traefik not ready after ${x} seconds. Exit" && exit 1
  sleep 2
done
echo

echo
echo "==== show info about the cluster ${CLUSTER}"
kubectl cluster-info

echo
kubectl get all -A

echo "==== traefik service"
kubectl get svc traefik -n kube-system
