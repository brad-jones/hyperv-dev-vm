#!/usr/bin/env bash
set -euxo pipefail;

# We put a few scripts into here so lets make sure it exists
sudo mkdir -p /usr/local/bin;

# It is handy to be able to call out to the host on occasion which is
# effectively the default gateway, this will add a new host file entry
# at boot time.
#sudo cp /tmp/set-default-gateway-host /usr/local/bin/set-default-gateway-host;
#sudo cp /tmp/set-default-gateway-host.service /etc/systemd/system/set-default-gateway-host.service;
#sudo chmod +x /usr/local/bin/set-default-gateway-host;
#sudo systemctl daemon-reload;
#sudo systemctl enable \
#	systemd-networkd.service \
#	systemd-networkd-wait-online.service \
#	set-default-gateway-host.service;

# The intension is to spend almost all our time with-in this VM's shell and so
# I still want to be able to use VsCode just by executing `code ./some/path`.
#
# I was using an X11 server on the host to do this previously but that had
# issues with multiple monitors, HiDPI and performance was sub par.
#
# This solution connects to an SSH server running on the host which then
# executes VsCode with the SSH remote extension which then connects back
# into this guest.
#
# One day I will learn how to use vim properly haha
sudo dnf install -y tar;
sudo cp /tmp/code /usr/local/bin/code;
sudo chmod +x /usr/local/bin/code;

# The plan is to do 99% of our work with-in the confines of this VM, just using
# Windows as a dumb GUI of sorts. But there will be times when I want to share
# files between the guest and host. CIFS/Samba is slow, NFS should be faster.
#
# Consider https://github.com/billziss-gh/sshfs-win as an alternative?
#sudo dnf install -y nfs-utils;
#sudo systemctl enable rpcbind nfs-server;
#sudo sh -c "echo '/home/$USER dom0.hyper-v.local(rw,async,all_squash,anonuid=$(id -u),anongid=$(id -g))' >> /etc/exports";

# Make sure this image is as small as possible
sudo rm -rf /tmp/*;
ls -hal /tmp;