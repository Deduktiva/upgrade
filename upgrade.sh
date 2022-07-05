#!/bin/bash
# Upgrade script from buster to bullseye, covering mostly server usecases.
# Assumes puppet is in active use.
#
# Joint effort by SynPro.solutions and Deduktiva GmbH.
#
# Parts of this script were inspired by
# https://dsa.debian.org/howto/upgrade-to-bullseye/
# https://dsa.debian.org/howto/upgrade-to-buster/
# https://anarc.at/services/upgrades/buster/

UPGRADE_FROM="buster"
UPGRADE_TO="bullseye"
DEPRECATED_PACKAGES="ifupdown"

FORCE=false
ASK_CONFIRMATION=""
for i in "$@"
do
case $i in
    --force)
    FORCE=true
    ASK_CONFIRMATION="-y"
    ;;
    *)
            # unknown option
    ;;
esac
done

is_package_installed() {
  test -n "$(dpkg-query -f '${Version}' -W "$1" 2>/dev/null)"
}

set -u
set -x

if [ "$(id -u 2>/dev/null)" != 0 ] ; then
  echo "Error: please run this script with uid 0 (root)." >&2
  exit 1
fi

export LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true
export APT_LISTCHANGES_FRONTEND=mail

echo -n "Starting at $(date), Debian Version is"
cat /etc/debian_version

if dpkg --audit | grep -q '.' ; then
  echo "Error: dpkg --audit reports problems. Please fix before continuing. ">&2
  exit 1
fi

echo "Checking for not properly installed packages."
if dpkg --list | grep '^[a-z][a-z] ' | grep -v '^ii' | grep -v '^rc' | grep '.' ; then
  echo "Error: the packages listed above are not properly installed. Please fix before continuing." >&2
  exit 1
fi

etckeeper commit -m "${UPGRADE_FROM}, before upgrade to ${UPGRADE_TO}"

if ! which apt-show-versions &>/dev/null ; then
  echo "Ensuring dependencies are installed"
  apt-get update
  apt-get -y install apt-show-versions
fi

echo "# The following packages are not shipped via enabled Debian repositories:"
apt-show-versions | grep -v "/${UPGRADE_FROM}" | grep -v "/${UPGRADE_TO}" | grep -v 'not installed$'
echo "# END"

cat > /etc/needrestart/conf.d/upgrade_wip.conf << EOF
# installed by $0 on $(date) to disable needrestart prompts during upgrades
\$nrconf{kernelhints} = -1;
EOF

puppet agent --disable "updating Debian to ${UPGRADE_TO}, user: $(whoami)"

sed -i "s#${UPGRADE_FROM}/updates#${UPGRADE_TO}-security#g" /etc/apt/sources.list /etc/apt/sources.list.d/*
sed -i "s#${UPGRADE_FROM}#${UPGRADE_TO}#g" /etc/apt/sources.list /etc/apt/sources.list.d/*
dpkg --clear-avail
/usr/lib/dpkg/methods/apt/update /var/lib/dpkg/ apt apt
apt-get -y install apt dpkg deborphan debian-security-support
# Ensure openssh-server is updated first to avoid upgrade race
if is_package_installed openssh-server; then
  apt-get -y install -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" openssh-server
fi
# Keep fdisk installed
if is_package_installed fdisk; then
  apt-get -y install -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" fdisk
fi

apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" dist-upgrade

etckeeper commit -m "first dist-upgrade to ${UPGRADE_TO} finished"

apt-get clean

puppet agent --enable
puppet agent --test
puppet agent --test

etckeeper commit -m "executed puppet after upgrade to ${UPGRADE_TO}"

set +x
DEINSTALL_PACKAGES=$(dpkg --get-selections | awk '$2=="deinstall" {print $1}')
if [ -n "$DEINSTALL_PACKAGES" ]; then
  echo "Some packages are to be deinstalled: ${DEINSTALL_PACKAGES}"
  $FORCE || echo "really purge these [y/N]?"
  if $FORCE || ( read -r ans && [ "$ans" = "y" ] ) ; then
    # shellcheck disable=SC2086
    dpkg --purge ${DEINSTALL_PACKAGES}
    echo "These packages are not marked as 'install':"
    dpkg --get-selections | awk '$2!="install" {print $1}'
  fi
fi
set -x

apt-get clean
apt-get -y --purge autoremove
# shellcheck disable=SC2046
while deborphan -n | grep -q . ; do echo "Deborphan remove...."; apt-get "${ASK_CONFIRMATION}" purge $(deborphan -n); done
dpkg --clear-avail
apt-get -y --purge autoremove
/usr/lib/dpkg/methods/apt/update /var/lib/dpkg/ apt apt

etckeeper commit -m "post cleanup"

apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" dist-upgrade

etckeeper commit -m "another dist-upgrade run towards ${UPGRADE_TO}"

puppet agent --test
puppet agent --test

etckeeper commit -m "finished upgrade to ${UPGRADE_TO}"

set +x
if ! test -h /bin ; then
  echo "System is not usrmerged yet, installing usrmerge"
  apt-get install -y usrmerge
  etckeeper commit -m "finished usrmerge after upgrade to ${UPGRADE_TO}"
  apt-get remove --purge -y usrmerge
fi
apt-get clean
apt-get --purge "${ASK_CONFIRMATION}" autoremove

rm -f /etc/needrestart/conf.d/upgrade_wip.conf

echo -n "Upgrade Finished at $(date), Debian Version is now: "
cat /etc/debian_version

for pkg in ${DEPRECATED_PACKAGES}; do
  if is_package_installed "${pkg}"; then
    echo "Warning: system uses deprecated package ${pkg}"
  fi
done
if grep /dev/sd /etc/fstab >/dev/null; then
  echo "Warning: system uses unreliable sdX device names in /etc/fstab"
fi

echo "System ready for reboot now"
