#cloud-config
timezone: UTC
resize_rootfs: true

# Set the default user
system_info:
    default_user:
        name: "{{ssh_username}}"
        ssh_authorized_keys:
            - "{{ssh_public_key}}"
        sudo: "ALL=(ALL) NOPASSWD:ALL"
