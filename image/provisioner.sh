#!/usr/bin/env bash
set -euxo pipefail;

# Update and install some essential tools to the base system
# ------------------------------------------------------------------------------
sudo dnf update -y;
sudo dnf groupinstall -y "Development Tools";
sudo dnf install -y expect rng-tools wget jq tree bash-completion mlocate tar lsof;

# Install dom0.wslhv.local
# ------------------------------------------------------------------------------
# It is handy to be able to call out to the host on occasion which is
# effectively the default gateway, this will add a new host file entry
# at boot time called: `dom0.wslhv.local`.
#
# > Keep in mind you need to allow access through the Windows firewall.
#
# UPDATE: For all access to the host system we now make use of SSH reverse
# tunnels. I am leaving this in place for the moment in case the reverse
# tunnels create too much overhead or there are future services which do
# not work over the tunnels but for now this is not really used.
sudo cp /tmp/set-default-gateway-host /usr/local/bin/set-default-gateway-host;
sudo cp /tmp/set-default-gateway-host.service /etc/systemd/system/set-default-gateway-host.service;
sudo chmod +x /usr/local/bin/set-default-gateway-host;
sudo systemctl daemon-reload;
sudo systemctl enable \
	systemd-networkd.service \
	systemd-networkd-wait-online.service \
	set-default-gateway-host.service;

# Install vscode shortcut
# ------------------------------------------------------------------------------
# This is a bash script that opens VsCode on the host system as if you had
# executed the command on the native windows shell. It achieves this by opening
# an ssh connection to the `ssh-server` project which executes the given command
# interactively inside the logged in users session.
#
# NOTE: It is assumed that the host system has VsCode installed with the
# Remote (SSH) extension.
#
# see: <https://code.visualstudio.com/remote-tutorials/ssh/getting-started>
sudo mkdir -p /usr/local/bin;
sudo cp /tmp/code /usr/local/bin/code;
sudo chmod +x /usr/local/bin/code;

# Install SSHFS
# ------------------------------------------------------------------------------
# This configures the system to mount the hosts C drive using SFTP.
# This connects to the `sftp-server` project via the `2223` SSH reverse tunnel.
sudo dnf install -y fuse-sshfs;
sudo mkdir -p /mnt/C;
sudo sh -c "echo '$USER@localhost:/ /mnt/C fuse.sshfs noauto,x-systemd.automount,_netdev,user,idmap=user,follow_symlinks,port=2223,stricthostkeychecking=no,identityfile=/home/$USER/.ssh/id_rsa,allow_other,reconnect,default_permissions,uid=$(id -u),gid=$(id -g) 0 0' >> /etc/fstab";

# Install gopass
# ------------------------------------------------------------------------------
# We use gopass for all personal secrets.
#
# see: <https://www.gopass.pw/>
sudo dnf copr enable -y daftaupe/gopass;
sudo dnf install -y gopass;

# Install chezmoi
# ------------------------------------------------------------------------------
# The rest of my setup is provided by a chezmoi repo, which consumes secrets
# from gopass. This leaves this vm image fairly generic for you to customise
# as you please.
#
# see: <https://www.chezmoi.io/>
chezmoiV="$(wget https://github.com/twpayne/chezmoi/releases/latest -O /dev/null 2>&1 | grep Location: | sed -r 's~^.*tag/v(.*?) \[.*~\1~g')";
sudo dnf install -y https://github.com/twpayne/chezmoi/releases/download/v$chezmoiV/chezmoi-$chezmoiV-x86_64.rpm;

# Clean up anything left over in the tmp dir
# ------------------------------------------------------------------------------
sudo rm -rf /tmp/*;
ls -hal /tmp;
