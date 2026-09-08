#!/bin/bash
set -eu

SERVER_IP="192.168.56.110"
TOKEN_DIR="/vagrant/confs"
TOKEN_FILE="${TOKEN_DIR}/node-token"

# curl est normalement déjà présent sur la box, mais on s'assure qu'il l'est
command -v curl >/dev/null 2>&1 || (apt-get update && apt-get install -y curl)

# Détecte dynamiquement le nom de l'interface reliée au réseau privé
# (enp0sX sur Debian récent, pas eth0)
IFACE=$(ip -4 -o addr show | awk -v ip="${SERVER_IP}" '$4 ~ ip {print $2}')

# Installation de K3s en mode server
# On ne fixe PAS --bind-address : par defaut l'API server ecoute sur 0.0.0.0,
# donc a la fois sur 127.0.0.1 (kubectl local via le kubeconfig) et sur
# 192.168.56.110 (join de l'agent). --advertise-address annonce la bonne IP.
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --node-ip=${SERVER_IP} \
  --advertise-address=${SERVER_IP} \
  --flannel-iface=${IFACE} \
  --disable traefik \
  --write-kubeconfig-mode 644" sh -s -

# Attend que le token du cluster soit généré
until [ -f /var/lib/rancher/k3s/server/node-token ]; do
  sleep 2
done

# Dépose le token dans le dossier synchronisé pour que le worker puisse le lire
mkdir -p "${TOKEN_DIR}"
cp /var/lib/rancher/k3s/server/node-token "${TOKEN_FILE}"
chmod 644 "${TOKEN_FILE}"

# Rend kubectl utilisable directement via `vagrant ssh imaalemS`
mkdir -p /home/vagrant/.kube
cp /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config
chown vagrant:vagrant /home/vagrant/.kube/config
chmod 600 /home/vagrant/.kube/config

# Installation du binaire kubectl officiel (le sujet le demande explicitement,
# en plus du "k3s kubectl" embarqué)
KUBECTL_VERSION=$(curl -sL https://dl.k8s.io/release/stable.txt)
curl -sLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm -f kubectl
