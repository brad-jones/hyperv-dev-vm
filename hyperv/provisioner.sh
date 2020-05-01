#!/usr/bin/env bash
set -euxo pipefail;

# Ensure the base system is up to date
#sudo dnf update -y;

# Install some basic tools
#sudo dnf groupinstall -y "Development Tools";
#sudo dnf install -y expect rng-tools wget jq tree bash-completion mlocate tar;

# Install our remote vscode shortcut
sudo dnf install -y tar;
sudo mkdir -p /usr/local/bin;
sudo cp /tmp/code /usr/local/bin/code;
sudo chmod +x /usr/local/bin/code;

# Install chezmoi
# see: <https://www.chezmoi.io/>
#chezmoiV="$(wget https://github.com/twpayne/chezmoi/releases/latest -O /dev/null 2>&1 | grep Location: | sed -r 's~^.*tag/v(.*?) \[.*~\1~g')";
#sudo dnf install -y https://github.com/twpayne/chezmoi/releases/download/v$chezmoiV/chezmoi-$chezmoiV-x86_64.rpm;

# Install gopass
# see: <https://www.gopass.pw/>
#sudo dnf copr enable -y daftaupe/gopass;
#sudo dnf install -y gopass;

# Clean up anything left over in the tmp dir
sudo rm -rf /tmp/*;
ls -hal /tmp;
