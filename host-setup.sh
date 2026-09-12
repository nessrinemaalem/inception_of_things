#!/bin/bash
# Prepare la machine hote pour les parties 1 et 2 : Vagrant + libvirt/KVM.
# (La partie 3 a ses propres prerequis : voir p3/scripts/install.sh)
#
#     sudo bash host-setup.sh
#
# Puis se deconnecter/reconnecter pour que le groupe libvirt prenne effet.
set -eu

TARGET_USER="${SUDO_USER:-$(id -un)}"
echo ">>> Utilisateur cible : ${TARGET_USER}"

echo ">>> Installation de Vagrant + libvirt/KVM + QEMU..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  vagrant vagrant-libvirt \
  libvirt-daemon-system libvirt-clients \
  qemu-system-x86 dnsmasq-base

echo ">>> Ajout de ${TARGET_USER} au groupe libvirt..."
usermod -aG libvirt "${TARGET_USER}"

# QEMU doit pouvoir ouvrir le dossier partage 9p situe dans le home de
# l'utilisateur. On le fait donc tourner sous cet utilisateur et on ecarte
# AppArmor, sinon le partage est bloque. (Acceptable sur une VM de dev dediee.)
QEMU_CONF=/etc/libvirt/qemu.conf
if ! grep -q "Ajouts IoT" "${QEMU_CONF}"; then
  echo ">>> Configuration de ${QEMU_CONF}..."
  cat >> "${QEMU_CONF}" <<CONF

# --- Ajouts IoT (VM de dev) ---
user = "${TARGET_USER}"
group = "${TARGET_USER}"
security_driver = "none"
CONF
else
  echo ">>> ${QEMU_CONF} deja configure."
fi

echo ">>> Activation du demon libvirt..."
systemctl enable --now libvirtd
systemctl restart libvirtd

echo
echo "============================================================"
echo "OK. Hote pret."
echo "Deconnecte-toi puis reconnecte-toi (groupe libvirt), puis :"
echo "    cd p1 && vagrant up --no-parallel"
echo "============================================================"
