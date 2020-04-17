#cloud-config
timezone: UTC
resize_rootfs: true

# Set the default user
system_info:
  default_user:
    name: "{{username}}"
    ssh_authorized_keys:
      - "{{sshkey}}"
    sudo: "ALL=(ALL) NOPASSWD:ALL"
