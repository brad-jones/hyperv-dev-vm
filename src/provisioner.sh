#!/usr/bin/env bash
set -euo pipefail;

# We put a few scripts into here so lets make sure it exists
echo "mkdir -p /usr/local/bin";
sudo mkdir -p /usr/local/bin;

# Install some generic everyday tools that might also come in useful for the
# rest of this script. Hence this will always be one of the first tasks.
echo "Install Misc Tools";
echo "--------------------------------------------------------------------------------";
sudo dnf install -y jq tar tree;

# It is handy to be able to call out to the host on occasion which is
# effectively the default gateway, this will add a new host file entry
# at boot time.
echo "Make dom0.hyper-v.local avaliable as a resolvable namne";
echo "--------------------------------------------------------------------------------";
sudo curl -s http://${PACKER_HTTP_ADDR}/set-default-gateway-host -o /usr/local/bin/set-default-gateway-host;
sudo curl -s http://${PACKER_HTTP_ADDR}/set-default-gateway-host.service -o /etc/systemd/system/set-default-gateway-host.service;
echo "chmod +x /usr/local/bin/set-default-gateway-host";
sudo chmod +x /usr/local/bin/set-default-gateway-host;
echo "systemctl daemon-reload";
sudo systemctl daemon-reload;
sudo systemctl enable \
	systemd-networkd.service \
	systemd-networkd-wait-online.service \
	set-default-gateway-host.service;

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
echo "Install VsCode Executor";
echo "--------------------------------------------------------------------------------";
sudo curl -s http://${PACKER_HTTP_ADDR}/code -o /usr/local/bin/code;
echo "chmod +x /usr/local/bin/code";
sudo chmod +x /usr/local/bin/code;

# The plan is to do 99% of our work with-in the confines of this VM, just using
# Windows as a dumb GUI of sorts. But there will be times when I want to share
# files between the guest and host. CIFS/Samba is slow, NFS should be faster.
echo "Install NFS Server";
echo "--------------------------------------------------------------------------------";
sudo dnf install -y nfs-utils;
sudo systemctl enable rpcbind nfs-server;
sudo sh -c "echo '/home/$USER dom0.hyper-v.local(rw,async,all_squash,anonuid=$(id -u),anongid=$(id -g))' >> /etc/exports";

# Make sure this image is as small as possible
echo "Cleanup";
echo "--------------------------------------------------------------------------------";
sudo rm -rf /tmp/*;
ls -hal /tmp;
