#!/bin/bash
# =============================================================================
# k3s-server.sh — provisioning de la VM imaalemS (p2)
#
# 1. installe K3s en mode server (AVEC Traefik, contrairement a la p1)
# 2. rend kubectl utilisable par l'utilisateur vagrant
# 3. attend que le cluster et Traefik soient prets
# 4. applique les manifests de /vagrant/confs
#
# Execute automatiquement par Vagrant au "vagrant up".
# =============================================================================
set -eu

SERVER_IP="192.168.56.110"
MANIFESTS_DIR="/vagrant/confs"

# kubectl lance en root a besoin de savoir ou est le kubeconfig
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# -----------------------------------------------------------------------------
# 1. Installation de K3s
# -----------------------------------------------------------------------------
if command -v k3s >/dev/null 2>&1; then
  echo ">>> K3s est deja installe, on saute l'installation."
else
  command -v curl >/dev/null 2>&1 || (apt-get update && apt-get install -y curl)

  # La VM a deux cartes reseau (management Vagrant + reseau prive). On repere
  # celle qui porte 192.168.56.110 pour que Flannel utilise la bonne.
  IFACE=$(ip -4 -o addr show | awk -v ip="${SERVER_IP}" '$4 ~ ip {print $2}')
  echo ">>> Interface du reseau prive detectee : ${IFACE}"

  echo ">>> Installation de K3s (mode server)..."
  # /!\ DIFFERENCE MAJEURE AVEC LA P1 /!\
  # En p1 on passait "--disable traefik". SURTOUT PAS ICI : Traefik est
  # l'Ingress Controller, c'est lui qui execute notre objet Ingress et qui
  # ecoute sur le port 80 de la VM. Sans lui, l'Ingress existerait dans
  # "kubectl get ingress" mais rien ne l'appliquerait -> connection refused.
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
    --node-ip=${SERVER_IP} \
    --advertise-address=${SERVER_IP} \
    --flannel-iface=${IFACE} \
    --write-kubeconfig-mode 644" sh -s -
fi

# -----------------------------------------------------------------------------
# 2. kubectl utilisable via "vagrant ssh imaalemS"
# -----------------------------------------------------------------------------
mkdir -p /home/vagrant/.kube
cp /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube
chmod 600 /home/vagrant/.kube/config

# Binaire kubectl officiel (le sujet le demande, en plus du "k3s kubectl")
if [ ! -f /usr/local/bin/kubectl ] || [ -L /usr/local/bin/kubectl ]; then
  echo ">>> Installation du binaire kubectl officiel..."
  KUBECTL_VERSION=$(curl -sL https://dl.k8s.io/release/stable.txt)
  curl -sLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm -f kubectl
fi

# -----------------------------------------------------------------------------
# 3. Attentes : le node, puis Traefik
# -----------------------------------------------------------------------------
# L'API server met quelques secondes a repondre apres l'installation.
# Sans cette boucle, le "kubectl wait" suivant echouerait immediatement sur un
# "connection refused" au lieu de patienter.
echo ">>> Attente de l'API server..."
for _ in $(seq 1 60); do
  kubectl get --raw='/readyz' >/dev/null 2>&1 && break
  sleep 5
done

# Meme piege que pour Traefik : "kubectl wait --all" echoue immediatement si
# AUCUNE ressource ne correspond ("error: no matching resources found"). Juste
# apres l'installation, l'API repond deja mais le node n'est pas encore
# enregistre. On attend donc son APPARITION avant d'attendre son etat.
echo ">>> Attente de l'enregistrement du node..."
for _ in $(seq 1 60); do
  [ -n "$(kubectl get nodes --no-headers 2>/dev/null)" ] && break
  sleep 5
done

echo ">>> Attente que le node soit Ready..."
kubectl wait --for=condition=Ready node --all --timeout=180s

# Traefik n'est pas installe instantanement : K3s le deploie via un job Helm,
# donc le Deployment "traefik" n'existe pas encore dans les premieres secondes.
# On attend d'abord son APPARITION, puis son demarrage complet.
echo ">>> Attente de l'apparition du Deployment Traefik..."
for _ in $(seq 1 60); do
  kubectl -n kube-system get deployment traefik >/dev/null 2>&1 && break
  sleep 5
done

echo ">>> Attente que Traefik soit operationnel..."
kubectl -n kube-system rollout status deployment/traefik --timeout=180s

# -----------------------------------------------------------------------------
# 4. Application des manifests
# -----------------------------------------------------------------------------
# /vagrant/confs est le dossier p2/confs de l'hote, partage via 9p.
# "kubectl apply -f <dossier>" applique tous les .yaml qu'il contient.
# apply est idempotent : on peut relancer "vagrant provision" sans risque.
echo ">>> Application des manifests depuis ${MANIFESTS_DIR}..."
kubectl apply -f "${MANIFESTS_DIR}/"

echo ">>> Attente du demarrage des 3 applications..."
for app in app1 app2 app3; do
  kubectl rollout status "deployment/${app}" --timeout=180s
done

# -----------------------------------------------------------------------------
# 5. Recapitulatif
# -----------------------------------------------------------------------------
echo
echo "================= ETAT DU CLUSTER ================="
kubectl get all
echo
echo "===================== INGRESS ====================="
kubectl get ingress
echo
echo "Provisioning termine. Depuis l'hote :"
echo "    curl -H \"Host: app1.com\" ${SERVER_IP}"
echo "    curl -H \"Host: app2.com\" ${SERVER_IP}"
echo "    curl ${SERVER_IP}"
