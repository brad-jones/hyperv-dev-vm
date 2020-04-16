# see: https://pykickstart.readthedocs.io/en/latest/kickstart-docs.html

# If cmdline is chosen all required installation options must be configured
# via kickstart otherwise the installation will fail.
cmdline

# Locale
lang en_AU.UTF-8
keyboard --xlayouts='au'
services --enabled="chronyd"
timezone Australia/Melbourne --isUtc

# Disk
clearpart --all --initlabel
part /boot --fstype="ext4" --ondisk=sda --size=1024
part /boot/efi --fstype="efi" --ondisk=sda --size=600 --fsoptions="umask=0077,shortname=winnt"
part / --fstype="ext4" --ondisk=sda --grow
part /home --label="/home" --fstype="ext4" --ondisk=sdb --grow
part swap --fstype="swap" --ondisk=sda --size=10240

# Network
network --bootproto=dhcp --device=eth0 --ipv6=auto --activate
network --hostname=localhost.localdomain

# Users
rootpw --lock
user --groups=wheel --name={{username}} --lock --gecos={{username}}
sshkey --username {{username}} "{{sshkey}}"

# Additional options
eula --accepted
firstboot --disabled
firewall --disabled
selinux --disabled

# Disable kdump
# see: https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/7/html/installation_guide/sect-kickstart-syntax
%addon com_redhat_kdump --disable
%end

# Install the system
url --mirrorlist=http://mirrors.fedoraproject.org/mirrorlist?repo=fedora-$releasever&arch=$basearch
%packages
@^minimal-environment
net-tools
hyperv-*
%end

# Additional tasks once system is installed
%post --erroronfail
echo "hv_sock" > /etc/modules-load.d/hv_sock.conf
sed -e 's/^%wheel/#%wheel/g' -e 's/^# %wheel/%wheel/g' -i /etc/sudoers
sed -i 's~UUID=.* /home~LABEL=/home /home~g' /etc/fstab
systemctl mask tmp.mount
echo 'fs.inotify.max_user_watches=524288' >> /etc/sysctl.conf
%end

# Finish up
reboot
