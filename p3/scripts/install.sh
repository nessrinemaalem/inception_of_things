#!/bin/bash
# =============================================================================
# install.sh — installe l'outillage necessaire a la p3 : Docker, kubectl, k3d.
#
# Le sujet exige ce script : "You will need Docker for K3d to work, and probably
# some other software as well. Therefore, you must write a script to install all
# the necessary packages and tools during your defense."
#
# A lancer UNE FOIS, avec sudo :
#     sudo bash p3/scripts/install.sh
#
# Puis se deconnecter/reconnecter (pour le groupe docker), et :
#     bash p3/scripts/setup.sh
# =============================================================================
set -eu

# Utilisateur non-root qui utilisera docker (celui qui a invoque sudo)
TARGET_USER="${SUDO_USER:-$(id -un)}"
echo ">>> Utilisateur cible : ${TARGET_USER}"

export DEBIAN_FRONTEND=noninteractive

# -----------------------------------------------------------------------------
# 1. Docker
# -----------------------------------------------------------------------------
# On utilise le depot officiel Docker plutot que le paquet "docker.io" de Debian
# (fige en 20.10) : k3d suit de pres les versions recentes du moteur.
if command -v docker >/dev/null 2>&1; then
  echo ">>> Docker est deja installe, on saute."
else
  echo ">>> Installation de Docker (depot officiel)..."
  apt-get update
  apt-get install -y ca-certificates curl gnupg

  # Cle GPG du depot, pour qu'apt puisse verifier les paquets telecharges
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  # shellcheck disable=SC1091
  CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME}")
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
fi

echo ">>> Activation du service Docker..."
systemctl enable --now docker

# Permet d'utiliser docker sans sudo. Comme le groupe "libvirt" en p1, cela ne
# prend effet qu'a la PROCHAINE session : il faut se deconnecter/reconnecter.
echo ">>> Ajout de ${TARGET_USER} au groupe docker..."
usermod -aG docker "${TARGET_USER}"

# -----------------------------------------------------------------------------
# 2. kubectl
# -----------------------------------------------------------------------------
# Meme methode qu'en p1/p2 : le binaire officiel, version stable du moment.
if command -v kubectl >/dev/null 2>&1; then
  echo ">>> kubectl est deja installe, on saute."
else
  echo ">>> Installation de kubectl..."
  KUBECTL_VERSION=$(curl -sL https://dl.k8s.io/release/stable.txt)
  curl -sLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm -f kubectl
  echo ">>> kubectl ${KUBECTL_VERSION} installe."
fi

# -----------------------------------------------------------------------------
# 3. k3d
# -----------------------------------------------------------------------------
# k3d n'est pas un cluster : c'est un lanceur qui demarre K3s dans des
# conteneurs Docker (1 node = 1 conteneur).
if command -v k3d >/dev/null 2>&1; then
  echo ">>> k3d est deja installe, on saute."
else
  echo ">>> Installation de k3d..."
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi

# -----------------------------------------------------------------------------
# Recapitulatif
# -----------------------------------------------------------------------------
echo
echo "================= VERSIONS INSTALLEES ================="
docker --version
kubectl version --client 2>/dev/null | head -1
k3d version | head -1
echo
echo "============================================================"
echo "OK. Outillage pret."
echo "IMPORTANT : deconnecte-toi puis reconnecte-toi (ou reboote)"
echo "pour que le groupe 'docker' prenne effet, puis lance :"
echo "    bash p3/scripts/setup.sh"
echo "============================================================"
