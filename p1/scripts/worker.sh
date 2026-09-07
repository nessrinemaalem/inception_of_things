#!/bin/bash
set -eu

SERVER_IP="192.168.56.110"
AGENT_IP="192.168.56.111"
TOKEN_DIR="/vagrant/confs"
TOKEN_FILE="${TOKEN_DIR}/node-token"

# curl est normalement déjà présent sur la box, mais on s'assure qu'il l'est
command -v curl >/dev/null 2>&1 || (apt-get update && apt-get install -y curl)

# Détecte dynamiquement le nom de l'interface reliée au réseau privé
# (enp0sX sur Debian récent, pas eth0)
IFACE=$(ip -4 -o addr show | awk -v ip="${AGENT_IP}" '$4 ~ ip {print $2}')

# Attend que le server ait déposé le token dans le dossier synchronisé
# (le provisioning des 2 VM peut démarrer avant que le server ait fini,
# et -s évite de lire le fichier pendant que le cp cote server l'écrit)
until [ -s "${TOKEN_FILE}" ]; do
  sleep 2
done
K3S_TOKEN=$(cat "${TOKEN_FILE}")

# Installation de K3s en mode agent, rattaché au server via le port 6443
curl -sfL https://get.k3s.io | K3S_URL="https://${SERVER_IP}:6443" \
  K3S_TOKEN="${K3S_TOKEN}" \
  INSTALL_K3S_EXEC="agent \
  --node-ip=${AGENT_IP} \
  --flannel-iface=${IFACE}" sh -s -
