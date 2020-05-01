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
# executed the command on the native windows shell.
#
# It achieves this by opening an ssh connection to the `ssh-server` project
# which can either be accessed via `dom0.wslhv.local` if you open your
# windows firewall to allow the connection or via a reverse SSH tunnel.
#
# At the expense of some overhead, the reverse SSH tunnel is a more portable,
# more secure option and is what we do by default now.
sudo mkdir -p /usr/local/bin;
sudo cp /tmp/code /usr/local/bin/code;
sudo chmod +x /usr/local/bin/code;


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
