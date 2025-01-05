#!/bin/bash
set -e

# set of environment variables
# NGINX variable set
export NGINXNAMESPACE=ingress-nginx
export CLUSTER=production
export HTTPPORT=80
# PROMETHEUS variable set
export PROMETHEUSNAMESPACE=monitoring
export GRAFANAPASS=operator123
# POSTGRESQL variable set
export POSTGRESQLNAMESPACE=postgres
export POSTGRESPASSWORD=""
# DOCKER HUB variable set
export REPOHOSTNAME="https://index.docker.io/v1/"
export REPOUSERNAME="pcarlos"
export DOCKERCONFIGJSON=""

# remove existing cluster
if [[ ! -z $(k3d cluster list | grep "^${CLUSTER}") ]]; then
  echo
  echo "==== remove existing cluster"
  read -p "K3D cluster \"${CLUSTER}\" exists. Ok to delete it and restart? (y/n) " -n 1 -r
  echo
  if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
    echo "bailing out..."
    exit 1
  fi
  k3d cluster delete ${CLUSTER}
fi  

echo 
echo "==== Docker login"
#read -p "Enter Docker username: " username
read -sp "Enter Docker password: " password
echo "$password" | docker login --username "${REPOUSERNAME}" --password-stdin "${REPOHOSTNAME}"
[ $? -eq 0 ] && echo "Login successful to $registry!" && DOCKERCONFIGJSON=$(cat ~/.docker/config.json | base64 -w 0) || echo "Login failed!"


echo
echo "==== install app packages"
# npm install
# export APP=`cat package.json | grep '^  \"name\":' | cut -d ' ' -f 4 | tr -d '",'`         # extract app name from package.json
# export VERSION=`cat package.json | grep '^  \"version\":' | cut -d ' ' -f 4 | tr -d '",'`  # extract version from package.json

echo "==== create new cluster ${CLUSTER}" # "for app ${APP}:${VERSION}"
cat k3d/template-k3d-config.yaml | envsubst > /tmp/k3d-config.yaml
k3d cluster create --config /tmp/k3d-config.yaml
export KUBECONFIG=$(k3d kubeconfig write ${CLUSTER})
echo "export KUBECONFIG=${KUBECONFIG}"
rm /tmp/k3d-config.yaml


echo "==== running helm for ingress-nginx"

kubectl create namespace ${NGINXNAMESPACE}
helm install ingress-nginx ./ingress/nginx/ --set namespaceOverride="${NGINXNAMESPACE}"

echo 
echo "---- waiting for ingress-nginx controller deployment"
kubectl rollout status deployment.apps ingress-nginx-controller -n ${NGINXNAMESPACE} --request-timeout 5m
kubectl rollout status daemonset.apps svclb-ingress-nginx-controller -n ${NGINXNAMESPACE} --request-timeout 5m

echo
echo "---- looking for IP of ingress-nginx controller"
i=0
while [ true ]; do
    loadbalancerip=$(kubectl get svc ingress-nginx-controller --template="{{range .status.loadBalancer.ingress}}{{.ip}}{{end}}" -n ${NGINXNAMESPACE})
    [ ! -z "${loadbalancerip}" ] && break
    echo -n "."
    x=$(( ${x} + 2 ))
    [ $x -gt "100" ] && echo "ingress-nginx-controller not ready after ${x} seconds. Exit" && exit 1
    sleep 2
done
echo

echo
echo "==== show info about the cluster ${CLUSTER}"
kubectl cluster-info
echo
kubectl get all -A

# validation of the ingress installation
# kubectl get svc -A | grep traefik

echo "==== Information of ingress-nginx-controller in the namespace ${NGINXNAMESPACE}"
NGINXCONTROLLERPOD=$(kubectl get pods -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].metadata.name}' -n ${NGINXNAMESPACE})
kubectl exec -it ${NGINXCONTROLLERPOD} -n ${NGINXNAMESPACE} -- /nginx-ingress-controller --version

echo
echo "==== Installation of prometheus-community stack"
kubectl create namespace ${PROMETHEUSNAMESPACE}

cat prometheus-stack/template-prometheus-stack-values.yaml | envsubst | helm install prometheus ./prometheus-stack/kube-prometheus-stack -n ${PROMETHEUSNAMESPACE} --values -

kubectl rollout status deployment.apps prometheus-grafana -n ${PROMETHEUSNAMESPACE} --request-timeout 5m
kubectl rollout status deployment.apps prometheus-kube-state-metrics -n ${PROMETHEUSNAMESPACE} --request-timeout 5m
kubectl rollout status deployment.apps prometheus-kube-prometheus-operator -n ${PROMETHEUSNAMESPACE} --request-timeout 5m

echo
echo "==== Installation of postgresql"
kubectl create namespace ${POSTGRESQLNAMESPACE}

cat database/template-postgresql.yaml | envsubst | helm install postgresql ./database/postgresql -n ${POSTGRESQLNAMESPACE} --values - 
POSTGRESPASSWORD=$(kubectl get secret --namespace postgres postgresql -o jsonpath="{.data.postgres-password}" | base64 -d)
cat database/template-prometheus-postgres-exporter.yaml | envsubst | helm install prometheus-postgres-exporter ./database/prometheus-postgres-exporter -n ${POSTGRESQLNAMESPACE} --values -

echo
echo "==== Installation of database tools"
cat app/template-pgimporter-values.yaml | envsubst | helm install pgimporter ./app/pgimporter -n ${POSTGRESQLNAMESPACE} --values -

#kubectl rollouts TODO