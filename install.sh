#!/bin/bash
# install.sh - Proxmox + ZFSBootMenu automated bare-metal installer
# Sources config.sh for user variables. Run as root from the Proxmox ISO live shell.
#
# Usage:
#   ./install.sh              - run all phases (or resume from last completed)
#   ./install.sh --phase N    - run only phase N
#   ./install.sh --from N     - run from phase N to end
#   ./install.sh --reset      - clear phase state and start over

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="/tmp/zbm-install-state"
CHROOT_SCRIPT="/tmp/zbm-chroot.sh"

# --- Source config -----------------------------------------------------------
if [[ ! -f "${SCRIPT_DIR}/config.sh" ]]; then
    echo "ERROR: config.sh not found next to install.sh" >&2
    exit 1
fi
# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"

# --- Argument parsing --------------------------------------------------------
ONLY_PHASE=""
FROM_PHASE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --phase) ONLY_PHASE="$2"; shift 2 ;;
        --from)  FROM_PHASE="$2";  shift 2 ;;
        --reset) rm -f "$STATE_FILE"; echo "Phase state cleared."; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# --- State helpers -----------------------------------------------------------
get_last_phase() {
    [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo "0"
}

set_last_phase() {
    echo "$1" > "$STATE_FILE"
}

should_run_phase() {
    local phase="$1"
    local last
    last=$(get_last_phase)

    if [[ -n "$ONLY_PHASE" ]]; then
        [[ "$phase" == "$ONLY_PHASE" ]]
        return
    fi
    if [[ -n "$FROM_PHASE" ]]; then
        [[ "$phase" -ge "$FROM_PHASE" ]]
        return
    fi
    # Normal mode: run phases not yet completed
    [[ "$phase" -gt "$last" ]]
}

# --- Logging -----------------------------------------------------------------
log()  { echo "==> $*"; }
info() { echo "    $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }


# --- Derived variables -------------------------------------------------------
# Populated in phase 1 after validation
declare -a EFI_PARTS=()
declare -a ZFS_PARTS=()
declare -a ZFS_BY_ID=()

build_derived_vars() {
    EFI_PARTS=()
    ZFS_PARTS=()
    ZFS_BY_ID=()

    for disk in "${DRIVES[@]}"; do
        # Determine partition suffix: nvme uses 'p', others don't
        if [[ "$disk" == *nvme* || "$disk" == *mmcblk* ]]; then
            EFI_PARTS+=("${disk}p1")
            ZFS_PARTS+=("${disk}p2")
        else
            EFI_PARTS+=("${disk}1")
            ZFS_PARTS+=("${disk}2")
        fi
    done

    # Resolve by-id paths for ZFS partition members
    for part in "${ZFS_PARTS[@]}"; do
        local disk_byid
        disk_byid=$(find /dev/disk/by-id -name '*-part2' -type l 2>/dev/null \
            | while read -r link; do
                target=$(readlink -f "$link")
                if [[ "$target" == "$part" ]]; then
                    echo "$link"
                    break
                fi
              done | head -1)
        if [[ -n "$disk_byid" ]]; then
            ZFS_BY_ID+=("$disk_byid")
        else
            # Fall back to raw device path if no by-id link found
            ZFS_BY_ID+=("$part")
        fi
    done
}

build_zpool_args() {
    local -a members=()
    for byid in "${ZFS_BY_ID[@]}"; do
        members+=("$byid")
    done

    case "$POOL_TOPOLOGY" in
        mirror)
            echo "mirror ${members[*]}"
            ;;
        stripe)
            echo "${members[*]}"
            ;;
        single)
            echo "${members[0]}"
            ;;
        raidz|raidz2|raidz3)
            echo "$POOL_TOPOLOGY ${members[*]}"
            ;;
        *)
            die "Unknown POOL_TOPOLOGY: $POOL_TOPOLOGY"
            ;;
    esac
}

# --- Phase 1: Preflight ------------------------------------------------------
phase1_preflight() {
    log "Phase 1: Preflight checks"

    # Must be root
    [[ $EUID -eq 0 ]] || die "Must be run as root"

    # -- Install prerequisites ------------------------------------------------
    # The Proxmox live ISO apt sources point only to the local ISO filesystem.
    # Packages not bundled on the ISO (debootstrap, curl, etc.) must be fetched
    # from a Debian mirror. Overwrite sources.list with the internet repo, update,
    # then install what the rest of the script needs.
    log "  Configuring apt sources"
    cat > /etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free-firmware
EOF
    # The Proxmox live ISO ships enterprise sources (pve-enterprise, ceph) in
    # sources.list.d that return 401 without a subscription key. Remove them so
    # apt-get update only hits the Debian mirror we just wrote above.
    rm -f /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources
    apt-get update -qq
    log "  Installing prerequisites"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        debootstrap curl dosfstools efibootmgr gdisk zfs-dkms zfsutils-linux \
        linux-headers-amd64

    # Validate drives exist
    [[ ${#DRIVES[@]} -gt 0 ]] || die "DRIVES array is empty in config.sh"
    for disk in "${DRIVES[@]}"; do
        [[ -b "$disk" ]] || die "Drive not found: $disk"
    done

    # Validate topology vs drive count
    case "$POOL_TOPOLOGY" in
        mirror)
            [[ ${#DRIVES[@]} -ge 2 ]] || die "mirror requires at least 2 drives"
            ;;
        raidz)
            [[ ${#DRIVES[@]} -ge 3 ]] || die "raidz requires at least 3 drives"
            ;;
        raidz2)
            [[ ${#DRIVES[@]} -ge 4 ]] || die "raidz2 requires at least 4 drives"
            ;;
        raidz3)
            [[ ${#DRIVES[@]} -ge 5 ]] || die "raidz3 requires at least 5 drives"
            ;;
        stripe|single)
            ;;
        *)
            die "Unknown POOL_TOPOLOGY: $POOL_TOPOLOGY"
            ;;
    esac

    # Required tools
    local tools=(sgdisk wipefs zpool zfs zgenhostid debootstrap efibootmgr curl mkfs.fat)
    local missing=()
    for tool in "${tools[@]}"; do
        command -v "$tool" &>/dev/null || missing+=("$tool")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "Missing required tools: ${missing[*]}"

    # Check for Secure Boot -- ZBM release EFI binaries are unsigned and UEFI
    # will silently refuse to execute them when Secure Boot is enabled, falling
    # through to the next boot entry instead.
    local sb_var
    sb_var=$(find /sys/firmware/efi/efivars/ -name 'SecureBoot-*' 2>/dev/null | head -1)
    if [[ -n "$sb_var" ]]; then
        # The last byte of the EFI variable is the Secure Boot state (1 = enabled)
        local sb_state
        sb_state=$(od -An -t u1 -j4 -N1 "$sb_var" 2>/dev/null | tr -d ' ')
        if [[ "$sb_state" == "1" ]]; then
            die "Secure Boot is ENABLED. ZFSBootMenu EFI binaries are unsigned and" \
                "will not boot. Disable Secure Boot in your UEFI/BIOS settings, then" \
                "re-run this script."
        fi
    fi

    # Validate network config
    if [[ "$IP_ADDR" != "dhcp" ]]; then
        [[ -n "$GATEWAY" ]] || die "GATEWAY required when IP_ADDR is not 'dhcp'"
    fi

    build_derived_vars

    # Print summary
    echo
    echo "================================================================"
    echo "  Proxmox + ZFSBootMenu Install Summary"
    echo "================================================================"
    echo "  Hostname     : $TARGET_HOSTNAME"
    echo "  Drives       : ${DRIVES[*]}"
    echo "  Topology     : $POOL_TOPOLOGY"
    echo "  Pool         : $POOL_NAME"
    echo "  Boot env     : $POOL_NAME/ROOT/$BE_NAME"
    echo "  Encryption   : $ENCRYPTION"
    echo "  Network      : $IFACE / $IP_ADDR"
    echo "  Timezone     : $TIMEZONE"
    echo "  Locale       : $LOCALE"
    echo "================================================================"
    echo
    echo "  WARNING: ALL DATA ON THE ABOVE DRIVES WILL BE DESTROYED."
    echo
    read -r -p "  Type YES to continue: " confirm
    [[ "$confirm" == "YES" ]] || { echo "Aborted."; exit 1; }
    echo

    set_last_phase 1
    log "Phase 1 complete"
}

# --- Phase 2: Partition ------------------------------------------------------
phase2_partition() {
    log "Phase 2: Partitioning disks"

    build_derived_vars

    for disk in "${DRIVES[@]}"; do
        log "  Wiping $disk"
        wipefs -a "$disk"
        sgdisk --zap-all "$disk"

        log "  Partitioning $disk"
        # p1: EFI System Partition
        sgdisk -n "1:1m:${EFI_SIZE}" -t "1:ef00" "$disk"
        # p2: ZFS partition (rest of disk)
        sgdisk -n "2:0:0" -t "2:BF00" "$disk"

        # Inform kernel of new partition table and wait for udev to settle
        partprobe "$disk" 2>/dev/null || true
        udevadm settle
    done

    # Format all EFI partitions
    for part in "${EFI_PARTS[@]}"; do
        log "  Formatting EFI partition $part"
        mkfs.fat -F32 -n EFI "$part"
    done

    set_last_phase 2
    log "Phase 2 complete"
}

# --- Phase 3: ZFS Pool & Datasets --------------------------------------------
phase3_zfs() {
    log "Phase 3: Creating ZFS pool and datasets"

    build_derived_vars

    # Generate or pin hostid. Always pass -f -- the Proxmox live ISO ships
    # /etc/hostid already, and zgenhostid without -f refuses to overwrite it.
    if [[ -n "$HOSTID" ]]; then
        zgenhostid -f "$HOSTID"
    else
        zgenhostid -f
    fi
    log "  hostid: $(hostid)"

    # Build pool topology argument
    local topo_args
    topo_args=$(build_zpool_args)

    # Base zpool create options
    local -a pool_opts=(
        -f
        -o "ashift=${ASHIFT}"
        -o autotrim=on
        -o "cachefile=/etc/zfs/zpool.cache"
        -o "compatibility=${ZFS_COMPATIBILITY}"
        -O compression=lz4
        -O acltype=posixacl
        -O xattr=sa
        -O dnodesize=auto
        -O relatime=on
        -O normalization=formD
        -O canmount=off
        -O mountpoint=/
        -R /mnt
    )

    # Encryption options - keylocation=prompt so ZFSBootMenu prompts for the
    # passphrase interactively at boot. A file-based key would require the key
    # to exist at pool-import time, which is not supported in this setup.
    if [[ "$ENCRYPTION" == "true" ]]; then
        pool_opts+=(
            -O encryption=aes-256-gcm
            -O keylocation=prompt
            -O keyformat=passphrase
        )
    fi

    log "  Creating pool: $POOL_NAME ($POOL_TOPOLOGY)"
    # shellcheck disable=SC2086
    zpool create "${pool_opts[@]}" "$POOL_NAME" $topo_args

    log "  Creating datasets"

    # ROOT container - canmount=off (intermediate, not mounted itself)
    zfs create -o canmount=off -o mountpoint=none "${POOL_NAME}/ROOT"

    # Boot environment - canmount=noauto so ZBM controls mounting
    zfs create -o canmount=noauto -o mountpoint=/ "${POOL_NAME}/ROOT/${BE_NAME}"

    # Home datasets
    zfs create                              "${POOL_NAME}/home"
    zfs create -o mountpoint=/root          "${POOL_NAME}/home/root"

    # var hierarchy - intermediate datasets need canmount=off
    zfs create -o canmount=off              "${POOL_NAME}/var"
    zfs create -o canmount=off              "${POOL_NAME}/var/lib"
    zfs create                              "${POOL_NAME}/var/lib/vz"
    zfs create                              "${POOL_NAME}/var/log"
    zfs create                              "${POOL_NAME}/var/spool"

    # usr hierarchy
    zfs create -o canmount=off              "${POOL_NAME}/usr"
    zfs create                              "${POOL_NAME}/usr/local"

    # Proxmox local-zfs storage dataset
    zfs create                              "${POOL_NAME}/data"

    # Set ZBM properties
    local cmdline="quiet loglevel=4"
    [[ -n "$EXTRA_CMDLINE" ]] && cmdline="${cmdline} ${EXTRA_CMDLINE}"
    zfs set "org.zfsbootmenu:commandline=${cmdline}" "${POOL_NAME}/ROOT"
    zpool set "bootfs=${POOL_NAME}/ROOT/${BE_NAME}" "$POOL_NAME"

    # keylocation=prompt: ZBM will prompt for the passphrase at boot.
    # org.zfsbootmenu:keysource is only needed for file-based keys; skip it here.

    # Export and cleanly reimport
    log "  Reimporting pool under /mnt"
    zpool export "$POOL_NAME"
    zpool import -N -R /mnt "$POOL_NAME"

    # Mount datasets
    zfs mount "${POOL_NAME}/ROOT/${BE_NAME}"
    zfs mount -a

    chmod 700 /mnt/root

    set_last_phase 3
    log "Phase 3 complete"
}

# --- Phase 4: Debootstrap ----------------------------------------------------
phase4_debootstrap() {
    log "Phase 4: Debootstrap Debian trixie"

    # tmpfs for /run (needed before debootstrap)
    if ! mountpoint -q /mnt/run; then
        mkdir -p /mnt/run
        mount -t tmpfs tmpfs /mnt/run
        mkdir -p /mnt/run/lock
    fi

    log "  Running debootstrap (this takes a few minutes)"
    debootstrap --arch=amd64 trixie /mnt https://deb.debian.org/debian

    log "  Copying host files into chroot"
    mkdir -p /mnt/etc/zfs
    [[ -f /etc/zfs/zpool.cache ]] && cp /etc/zfs/zpool.cache /mnt/etc/zfs/
    cp /etc/hostid /mnt/etc/hostid
    cp /etc/resolv.conf /mnt/etc/resolv.conf

    log "  Mounting /proc /sys /dev /dev/pts"
    mount -t proc  proc    /mnt/proc
    mount -t sysfs sysfs   /mnt/sys
    mount --bind /dev      /mnt/dev
    mount --bind /dev/pts  /mnt/dev/pts

    set_last_phase 4
    log "Phase 4 complete"
}

# --- Phase 5 & 6: Chroot script ----------------------------------------------
# Writes a self-contained script then executes it inside the chroot.
# Phase 5 = system config + Proxmox install
# Phase 6 = ZBM install
# Both are written as one chroot invocation to avoid multiple chroot entries.

write_chroot_script() {
    local efi_part_1="${EFI_PARTS[0]}"
    local efi_uuid
    efi_uuid=$(blkid -s UUID -o value "$efi_part_1")

    # Build fstab EFI line
    local fstab_efi="UUID=${efi_uuid}  /boot/efi  vfat  defaults  0  1"

    # Build /etc/network/interfaces content
    local net_config
    if [[ "$IP_ADDR" == "dhcp" ]]; then
        net_config="auto lo
iface lo inet loopback

auto ${IFACE}
iface ${IFACE} inet manual

auto vmbr0
iface vmbr0 inet dhcp
    bridge-ports ${IFACE}
    bridge-stp off
    bridge-fd 0"
    else
        net_config="auto lo
iface lo inet loopback

auto ${IFACE}
iface ${IFACE} inet manual

auto vmbr0
iface vmbr0 inet static
    address ${IP_ADDR}
    gateway ${GATEWAY}
    bridge-ports ${IFACE}
    bridge-stp off
    bridge-fd 0"
    fi

    # Build ZBM download URL.
    # Latest: get.zfsbootmenu.org/efi redirects to the correct GitHub asset.
    # Versioned: use the GitHub API to resolve the asset URL, because the
    # release file naming convention changed in v3.1.0 (added a kernel version
    # suffix like -linux6.12) and may change again.
    local zbm_url
    if [[ -n "$ZBM_VERSION" ]]; then
        local ver="${ZBM_VERSION#v}"  # strip leading 'v' if present
        zbm_url=$(curl -sfL "https://api.github.com/repos/zbm-dev/zfsbootmenu/releases/tags/v${ver}" \
            | grep -o '"browser_download_url": "[^"]*release-x86_64[^"]*\.EFI"' \
            | grep -o 'https://[^"]*') \
            || die "Could not find ZBM v${ver} release EFI asset on GitHub"
    else
        zbm_url="https://get.zfsbootmenu.org/efi"
    fi

    # Build efibootmgr registration commands for all drives.
    # efibootmgr -c prepends each new entry to BootOrder, so the LAST registered
    # entry ends up FIRST in boot order. Strategy: register all backup entries
    # first (drives N..0), then all primary entries (drives N..0), so drive 0's
    # primary entry is last registered and therefore first in boot order.
    local efi_reg_cmds=""
    local num_drives="${#DRIVES[@]}"
    local label_suffix=""
    # Pass 1: backup entries, reverse drive order
    for (( i=num_drives-1; i>=0; i-- )); do
        local disk="${DRIVES[$i]}"
        label_suffix=""
        # With multiple drives, number every entry so each one is distinct in
        # the UEFI menu (Drive1, Drive2, …).  A single-drive install gets no
        # suffix — just "ZFSBootMenu" / "ZFSBootMenu (Backup)".
        [[ $num_drives -gt 1 ]] && label_suffix=" Drive$((i+1))"
        efi_reg_cmds+="efibootmgr -c -d \"${disk}\" -p 1 -L \"ZFSBootMenu${label_suffix} (Backup)\" -l '\\\\EFI\\\\ZBM\\\\VMLINUZ-BACKUP.EFI'
"
    done
    # Pass 2: primary entries, reverse drive order (drive 0 registered last = boots first)
    for (( i=num_drives-1; i>=0; i-- )); do
        local disk="${DRIVES[$i]}"
        label_suffix=""
        [[ $num_drives -gt 1 ]] && label_suffix=" Drive$((i+1))"
        efi_reg_cmds+="efibootmgr -c -d \"${disk}\" -p 1 -L \"ZFSBootMenu${label_suffix}\" -l '\\\\EFI\\\\ZBM\\\\VMLINUZ.EFI'
"
    done

    # Build EFI mirroring commands (copy first EFI partition to all others)
    local efi_mirror_cmds=""
    for (( i=1; i<num_drives; i++ )); do
        efi_mirror_cmds+="dd if=\"${EFI_PARTS[0]}\" of=\"${EFI_PARTS[$i]}\" bs=4M status=progress
"
    done

    # Root password handling.
    # base64-encode so the chroot script never contains the plaintext password,
    # and so any characters (including single quotes) are safe in the script.
    local passwd_cmd
    if [[ -n "$ROOT_PASS" ]]; then
        local _pass_b64
        _pass_b64=$(printf 'root:%s\n' "${ROOT_PASS}" | base64 -w0)
        passwd_cmd="printf '%s\\n' '${_pass_b64}' | base64 -d | chpasswd"
    else
        passwd_cmd='echo ""; echo "Set root password:"; passwd root'
    fi

    # /etc/hosts IP: Proxmox requires the hostname to resolve to the real IP,
    # not 127.0.1.1, when using a static address. Strip CIDR prefix if present.
    local hosts_ip
    if [[ "$IP_ADDR" == "dhcp" ]]; then
        hosts_ip="127.0.1.1"
    else
        hosts_ip="${IP_ADDR%%/*}"   # strip /prefix-len, e.g. 192.168.1.10/24 -> 192.168.1.10
    fi

    cat > "$CHROOT_SCRIPT" <<CHROOT_EOF
#!/bin/bash
set -euo pipefail

log()  { echo "==> \$*"; }
die()  { echo "ERROR: \$*" >&2; exit 1; }

# -- Hostname -----------------------------------------------------------------
log "Configuring hostname"
echo "${TARGET_HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
${hosts_ip}   ${TARGET_HOSTNAME}
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF
# Proxmox requires hostname to resolve to real IP (not 127.0.1.1) for cluster.
# For DHCP installs, 127.0.1.1 is used as a placeholder; update after first boot.

# -- Locale & timezone --------------------------------------------------------
# Write config files now; locale-gen runs after packages are installed because
# the locales package (which provides locale-gen) is not in the debootstrap base.
log "Configuring locale and timezone"
echo "${LOCALE} UTF-8" > /etc/locale.gen
# /etc/default/locale is the standard Debian location (used by update-locale)
echo "LANG=${LOCALE}" > /etc/default/locale
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime

# -- fstab --------------------------------------------------------------------
log "Writing /etc/fstab"
cat > /etc/fstab <<EOF
# EFI System Partition
${fstab_efi}
# ZFS datasets are auto-mounted by zfs-mount-generator
EOF

# -- Network ------------------------------------------------------------------
log "Configuring network"
cat > /etc/network/interfaces <<EOF
${net_config}
EOF

cat > /etc/resolv.conf <<EOF
nameserver ${DNS}
EOF

# -- APT sources --------------------------------------------------------------
log "Configuring APT sources"
cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian trixie main contrib non-free-firmware
deb-src http://deb.debian.org/debian trixie main contrib non-free-firmware

deb http://deb.debian.org/debian-security trixie-security main contrib non-free-firmware
deb-src http://deb.debian.org/debian-security/ trixie-security main contrib non-free-firmware

deb http://deb.debian.org/debian trixie-updates main contrib non-free-firmware
deb-src http://deb.debian.org/debian trixie-updates main contrib non-free-firmware
EOF

# Purge any enterprise/ceph sources before touching apt -- they may exist from
# a previous partial run (proxmox-default-kernel adds them post-install) and
# will cause 401 errors on every apt-get update.
rm -f /etc/apt/sources.list.d/pve-enterprise.list \
      /etc/apt/sources.list.d/ceph.list \
      /etc/apt/sources.list.d/*.sources

apt-get update

# curl is not in the debootstrap base; install it before using it to fetch
# the Proxmox GPG key below.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl

# -- Proxmox APT repo ---------------------------------------------------------
log "Adding Proxmox repository"
curl -fsSL https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
    -o /etc/apt/trusted.gpg.d/proxmox-archive-keyring-trixie.gpg
# Verify checksum matches the value published on pve.proxmox.com/wiki
echo "136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45  /etc/apt/trusted.gpg.d/proxmox-archive-keyring-trixie.gpg" \
    | sha256sum -c - \
    || die "Proxmox GPG key checksum mismatch - aborting"
cat > /etc/apt/sources.list.d/pve-install-repo.list <<EOF
deb [signed-by=/etc/apt/trusted.gpg.d/proxmox-archive-keyring-trixie.gpg] http://download.proxmox.com/debian/pve trixie pve-no-subscription
EOF

# Remove enterprise/ceph sources -- they require a subscription and return 401.
# proxmox-default-kernel (below) re-adds them via post-install, so we remove
# them here and again after that package is installed.
rm -f /etc/apt/sources.list.d/pve-enterprise.list \
      /etc/apt/sources.list.d/ceph.list

# Refresh now that the Proxmox repo is in place
apt-get update

# -- Proxmox kernel (must come before proxmox-ve meta-package) ----------------
# Install the PVE kernel first. proxmox-ve depends on it, and installing it
# first ensures DKMS builds ZFS modules against the PVE kernel, not Debian's.
log "Installing Proxmox kernel"
DEBIAN_FRONTEND=noninteractive apt-get install -y proxmox-default-kernel

# proxmox-default-kernel post-install adds enterprise/ceph sources; remove them.
rm -f /etc/apt/sources.list.d/pve-enterprise.list \
      /etc/apt/sources.list.d/ceph.list

mkdir -p /etc/dkms
echo "REMAKE_INITRD=yes" > /etc/dkms/zfs.conf

# -- Proxmox VE ---------------------------------------------------------------
log "Installing Proxmox VE (this takes several minutes)"
# zfs-initramfs: needed for ZFS-root initramfs (proxmox-ve only deps zfsutils-linux)
# efibootmgr, curl: needed for ZBM install below; not part of Proxmox
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    proxmox-ve postfix open-iscsi chrony \
    zfs-initramfs efibootmgr curl locales console-setup

# Generate locale now that the locales package is installed
locale-gen

# -- ZFS services -------------------------------------------------------------
# zfs-initramfs (pulled in by proxmox-ve) provides these units; enable only now.
log "Enabling ZFS services"
systemctl enable zfs.target
systemctl enable zfs-import-cache
systemctl enable zfs-mount
systemctl enable zfs-import.target

# Remove the Debian kernel. proxmox-ve may pull linux-image-amd64 in as a
# recommended package; keeping it alongside the PVE kernel causes upgrade
# trouble on point releases (per Proxmox docs). No update-grub needed -- ZBM.
apt-get remove -y linux-image-amd64 'linux-image-6.*' 2>/dev/null || true
apt-get autoremove -y

# Remove os-prober (interferes with ZBM)
apt-get remove -y os-prober 2>/dev/null || true

# -- Proxmox storage config ---------------------------------------------------
log "Writing Proxmox storage.cfg"
mkdir -p /etc/pve
cat > /etc/pve/storage.cfg <<EOF
dir: local
    path /var/lib/vz
    content iso,import,backup,vztmpl
    shared 0

zfspool: local-zfs
    pool ${POOL_NAME}/data
    content images,rootdir
    sparse 1
EOF

# -- SSH ----------------------------------------------------------------------
log "Configuring SSH"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

# -- ZFS mount cache (zed) ----------------------------------------------------
log "Populating ZFS mount cache"
mkdir -p /etc/zfs/zfs-list.cache
touch /etc/zfs/zfs-list.cache/${POOL_NAME}
zed -F &
ZED_PID=\$!
# Trigger a zed event to populate the cache
zfs set canmount=noauto ${POOL_NAME}/ROOT/${BE_NAME}
# Wait up to 30 s for zed to write the cache file rather than sleeping blindly
_zed_retries=30
while [[ \$_zed_retries -gt 0 ]] && [[ ! -s /etc/zfs/zfs-list.cache/${POOL_NAME} ]]; do
    sleep 1
    _zed_retries=\$(( _zed_retries - 1 ))
done
[[ -s /etc/zfs/zfs-list.cache/${POOL_NAME} ]] \
    || die "zed did not populate ZFS list cache after 30 s - check zed logs"
kill \$ZED_PID 2>/dev/null || true
wait \$ZED_PID 2>/dev/null || true
# Strip the /mnt prefix that was active during install
sed -Ei "s|/mnt/?|/|" /etc/zfs/zfs-list.cache/${POOL_NAME}

# -- initramfs ----------------------------------------------------------------
log "Building initramfs"
update-initramfs -c -k all

# -- Phase 6: ZFSBootMenu -----------------------------------------------------
log "Installing ZFSBootMenu"

mount /boot/efi
mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true
# mkdir must come AFTER mount so the directory is created on the FAT partition
mkdir -p /boot/efi/EFI/ZBM

log "  Downloading ZBM EFI binary"
curl -fL "${zbm_url}" -o /boot/efi/EFI/ZBM/VMLINUZ.EFI

# Sanity-check: a valid PE/EFI binary starts with the "MZ" DOS header magic.
# A corrupted download or HTML error page will fail this check.
if ! head -c2 /boot/efi/EFI/ZBM/VMLINUZ.EFI | grep -q 'MZ'; then
    die "Downloaded file is not a valid EFI binary (missing MZ header). URL: ${zbm_url}"
fi

cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI

# Unmount before dd-mirroring: writing to an actively mounted FAT partition
# via block device is unsafe and can cause filesystem corruption.
umount /boot/efi

# Mirror first EFI partition to additional drives
${efi_mirror_cmds}

# efibootmgr writes to NVRAM via efivarfs -- /boot/efi does not need to be mounted
log "  Registering EFI boot entries"
${efi_reg_cmds}

# -- Root password ------------------------------------------------------------
${passwd_cmd}

log "Chroot configuration complete"
CHROOT_EOF

    chmod +x "$CHROOT_SCRIPT"
}

phase5_phase6_chroot() {
    log "Phase 5+6: System configuration and ZBM install (chroot)"

    build_derived_vars
    write_chroot_script

    # Copy chroot script into /mnt
    cp "$CHROOT_SCRIPT" /mnt/tmp/zbm-chroot.sh

    mkdir -p /mnt/boot/efi

    # Execute chroot script
    chroot /mnt /tmp/zbm-chroot.sh

    # Remove the script immediately -- it may contain a base64-encoded password
    rm -f /mnt/tmp/zbm-chroot.sh "$CHROOT_SCRIPT"

    set_last_phase 6
    log "Phase 5+6 complete"
}

# --- Phase 7: Finalize -------------------------------------------------------
phase7_finalize() {
    log "Phase 7: Finalizing"

    # Kill any zed processes left over from partial chroot runs before touching ZFS.
    pkill -x zed 2>/dev/null || true
    sleep 1

    # Unmount non-ZFS filesystems under /mnt (proc, sys, dev, run, efi, ...)
    log "  Unmounting filesystems"
    mount | grep -v zfs | tac | awk '$3 ~ /^\/mnt\// {print $3}' \
        | xargs -I{} umount -lf {} 2>/dev/null || true

    # ZFS operations are best-effort: the chroot's devtmpfs mount (new installs)
    # or a corrupted /dev/zfs (old partial runs) may leave the module unusable.
    # ZFSBootMenu will import the pool cleanly at first boot regardless.
    modprobe zfs 2>/dev/null || true

    if [[ -e /dev/zfs ]]; then
        if ! zpool list "$POOL_NAME" &>/dev/null; then
            log "  Pool not imported; reimporting under /mnt"
            zpool import -N -R /mnt "$POOL_NAME" 2>/dev/null || true
        fi

        log "  Creating install snapshot"
        zfs snapshot "${POOL_NAME}/ROOT/${BE_NAME}@install" 2>/dev/null || \
            log "  (snapshot already exists, skipping)"
        zfs unmount -a 2>/dev/null || true

        log "  Exporting ZFS pool"
        zpool export -a 2>/dev/null || \
            log "  (pool export failed - ZFSBootMenu will handle import at boot)"
    else
        log "  WARNING: /dev/zfs unavailable; skipping snapshot and pool export"
        log "  ZFSBootMenu will import the pool at first boot"
    fi

    rm -f "$STATE_FILE"

    echo
    echo "================================================================"
    echo "  Installation complete!"
    echo ""
    echo "  Next steps:"
    echo "  1. Remove the USB/ISO"
    echo "  2. Reboot: reboot"
    echo "  3. ZFSBootMenu will appear -- select '$BE_NAME' to boot"
    echo "  4. Proxmox web UI: https://${TARGET_HOSTNAME}:8006"
    echo "================================================================"

    log "Phase 7 complete"
}

# --- Main --------------------------------------------------------------------
main() {
    local phases=(1 2 3 4 5 7)
    # Phase 5 actually runs phases 5+6 in one chroot invocation; phase 6 is internal.

    for phase in "${phases[@]}"; do
        if should_run_phase "$phase"; then
            case "$phase" in
                1) phase1_preflight ;;
                2) phase2_partition ;;
                3) phase3_zfs ;;
                4) phase4_debootstrap ;;
                5) phase5_phase6_chroot ;;
                7) phase7_finalize ;;
            esac
        else
            log "Phase $phase: already completed, skipping"
        fi
    done
}

main "$@"
