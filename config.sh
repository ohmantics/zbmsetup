#!/bin/bash
# config.sh - User-editable variables for zbmsetup Proxmox + ZFSBootMenu install
# Edit these before running install.sh

# --- Disks -------------------------------------------------------------------
# Explicit list of drives to use. These will be COMPLETELY WIPED.
DRIVES=("/dev/nvme0n1" "/dev/nvme1n1")

# Pool topology: mirror | stripe | single | raidz | raidz2 | raidz3
# "single" uses first drive only. "stripe" spreads across all drives (no redundancy).
POOL_TOPOLOGY="mirror"

# --- ZFS ---------------------------------------------------------------------
POOL_NAME="rpool"

# Name of the first boot environment dataset (created under rpool/ROOT/)
BE_NAME="pve-1"

# ashift: 12 = 4K sectors (most NVMe), 13 = 8K sectors (some enterprise NVMe)
ASHIFT=12

# ZFS feature compatibility level
ZFS_COMPATIBILITY="openzfs-2.1-linux"

# Enable ZFS native encryption on rpool
ENCRYPTION=false

# --- Partitions --------------------------------------------------------------
# Size of the EFI System Partition (sgdisk format, e.g. "+512M", "+1G")
EFI_SIZE="+512M"

# --- System ------------------------------------------------------------------
TARGET_HOSTNAME="proxmox2"
TIMEZONE="UTC"
LOCALE="en_US.UTF-8"

# --- Network -----------------------------------------------------------------
# Physical NIC to use for the Proxmox bridge (vmbr0)
IFACE="eno1"

# IP address: "dhcp" or a CIDR like "192.168.1.10/24"
IP_ADDR="10.2.0.249/24"

# Required when IP_ADDR is not "dhcp"
GATEWAY="10.2.0.1"

# DNS server
DNS="10.2.0.1"

# --- Security ----------------------------------------------------------------
# Root password. Leave empty to be prompted at runtime.
ROOT_PASS=""

# --- ZFSBootMenu -------------------------------------------------------------
# Pin a specific ZBM version tag (e.g. "v3.0.1"), or leave empty for latest
ZBM_VERSION=""

# Extra kernel command-line parameters appended to ZBM's commandline property
# Example: "intel_iommu=on iommu=pt"
EXTRA_CMDLINE="quiet loglevel=4 intel_iommu=on"

# --- Host ID -----------------------------------------------------------------
# Leave empty to generate a random hostid, or pin one (e.g. "0x00bab10c")
HOSTID=""
