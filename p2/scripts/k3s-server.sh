#!/bin/bash
# Provisioning de imaalemS : K3s en mode server, puis application des manifests.
set -eu

SERVER_IP="192.168.56.110"
MANIFESTS_DIR="/vagrant/confs"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Debian lance unattended-upgrades a chaque demarrage. Sur 1 CPU / 1 Go la
# transaction apt entre en concurrence avec K3s (547 Mo a lui seul) : sans
# swap, kswapd s'emballe et l'API server devient injoignable. On le desactive
# aussi pour la reproductibilite : la VM ne doit pas changer de paquets entre
# deux "vagrant up".
systemctl disable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true

if command -v k3s >/dev/null 2>&1; then
  echo ">>> K3s deja installe."
else
  command -v curl >/dev/null 2>&1 || (apt-get update && apt-get install -y curl)

  # La VM a deux cartes reseau (management Vagrant + reseau prive) : on repere
  # celle qui porte SERVER_IP pour que Flannel utilise la bonne.
  IFACE=$(ip -4 -o addr show | awk -v ip="${SERVER_IP}" '$4 ~ ip {print $2}')
  echo ">>> Interface du reseau prive : ${IFACE}"

  # Ne PAS ajouter "--disable traefik" comme en p1 : Traefik est l'Ingress
  # Controller, sans lui l'objet Ingress existe mais rien ne l'applique.
  #
  # metrics-server (kubectl top) et local-path-provisioner (volumes
  # persistants) sont installes par defaut et inutiles ici : on les retire
  # pour tenir dans les 1024 Mo imposes par le sujet.
  echo ">>> Installation de K3s..."
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
    --node-ip=${SERVER_IP} \
    --advertise-address=${SERVER_IP} \
    --flannel-iface=${IFACE} \
    --disable metrics-server \
    --disable local-path-provisioner \
    --write-kubeconfig-mode 644" sh -s -
fi

echo ">>> Configuration de kubectl pour l'utilisateur vagrant..."
mkdir -p /home/vagrant/.kube
cp /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube
chmod 600 /home/vagrant/.kube/config

if [ ! -f /usr/local/bin/kubectl ] || [ -L /usr/local/bin/kubectl ]; then
  echo ">>> Installation du binaire kubectl officiel..."
  KUBECTL_VERSION=$(curl -sL https://dl.k8s.io/release/stable.txt)
  curl -sLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm -f kubectl
fi

echo ">>> Attente de l'API server..."
for _ in $(seq 1 60); do
  kubectl get --raw='/readyz' >/dev/null 2>&1 && break
  sleep 5
done

# "kubectl wait" echoue immediatement sur "no matching resources found" quand
# aucune ressource ne correspond encore. D'ou l'attente de l'APPARITION avant
# celle de l'etat, ici comme pour Traefik plus bas.
echo ">>> Attente de l'enregistrement du node..."
for _ in $(seq 1 60); do
  [ -n "$(kubectl get nodes --no-headers 2>/dev/null)" ] && break
  sleep 5
done

echo ">>> Attente que le node soit Ready..."
kubectl wait --for=condition=Ready node --all --timeout=180s

# K3s deploie Traefik via un job Helm : le Deployment n'existe pas encore dans
# les premieres secondes.
echo ">>> Attente de l'apparition de Traefik..."
for _ in $(seq 1 60); do
  kubectl -n kube-system get deployment traefik >/dev/null 2>&1 && break
  sleep 5
done

echo ">>> Attente que Traefik soit operationnel..."
kubectl -n kube-system rollout status deployment/traefik --timeout=180s

echo ">>> Application des manifests..."
kubectl apply -f "${MANIFESTS_DIR}/"

echo ">>> Attente du demarrage des applications..."
for app in app1 app2 app3; do
  kubectl rollout status "deployment/${app}" --timeout=180s
done

echo
echo "================= ETAT DU CLUSTER ================="
kubectl get all
echo
echo "===================== INGRESS ====================="
kubectl get ingress
echo
echo "Depuis l'hote :"
echo "    curl -H \"Host: app1.com\" ${SERVER_IP}"
echo "    curl -H \"Host: app2.com\" ${SERVER_IP}"
echo "    curl ${SERVER_IP}"
