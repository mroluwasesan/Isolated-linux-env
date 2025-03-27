#!/bin/bash

# Configuration
if [ -z "$1" ]; then
    read -p "Please enter a container name (default: mycontainer): " input_name
    CONTAINER_NAME=${input_name:-mycontainer}
else
    CONTAINER_NAME=$1
fi

CONTAINER_ROOT=/var/containers/$CONTAINER_NAME
CONTAINER_FS=$CONTAINER_ROOT/fs
HOST_IP="10.0.0.1"
CONTAINER_IP="10.0.0.2"

# Check root
[ "$(id -u)" -ne 0 ] && { echo "Must be root"; exit 1; }

# Cleanup function
cleanup() {
    echo "Cleaning up $CONTAINER_NAME..."
    # Unmount filesystems
    umount -lf $CONTAINER_FS/proc 2>/dev/null
    umount -lf $CONTAINER_FS/sys 2>/dev/null
    umount -lf $CONTAINER_FS/dev 2>/dev/null
    
    # Network cleanup
    ip netns del $CONTAINER_NAME 2>/dev/null
    ip link del veth0 2>/dev/null
    
    # Remove cgroups
    [ -d "/sys/fs/cgroup/memory/$CONTAINER_NAME" ] && rmdir "/sys/fs/cgroup/memory/$CONTAINER_NAME"
    [ -d "/sys/fs/cgroup/cpu/$CONTAINER_NAME" ] && rmdir "/sys/fs/cgroup/cpu/$CONTAINER_NAME"
    
    echo "Cleanup complete."
}

# Clean command
[ "$2" = "clean" ] && { cleanup; exit 0; }

# Clean before create if starting
[ "$2" = "start" ] && cleanup

# Create filesystem structure
mkdir -p $CONTAINER_FS/{bin,dev,etc,lib,lib64,proc,root,sbin,sys,tmp,usr/{bin,lib/x86_64-linux-gnu,sbin},var}
chmod 1777 $CONTAINER_FS/tmp

# Function to copy binary with all dependencies
copy_binary() {
    local binary=$1
    local target_dir=$CONTAINER_FS$(dirname $binary)
    
    mkdir -p $target_dir
    cp $binary $target_dir/
    
    # Copy dependencies
    ldd $binary | grep "=>" | awk '{print $3}' | while read lib; do
        if [ -f "$lib" ]; then
            lib_target=$CONTAINER_FS$(dirname $lib)
            mkdir -p $lib_target
            cp $lib $lib_target/
        fi
    done
}

# Essential binaries to copy
ESSENTIAL_BINARIES=(
    /bin/bash
    /bin/ls
    /bin/cat
    /bin/echo
    /bin/mkdir
    /bin/mount
    /bin/umount
    /bin/ip
    /usr/bin/hostname
    /bin/sh
)

# Copy all essential binaries
for binary in "${ESSENTIAL_BINARIES[@]}"; do
    if [ -f "$binary" ]; then
        copy_binary "$binary"
    else
        echo "Warning: Binary $binary not found"
    fi
done

# Additional required libraries that might be missed
EXTRA_LIBS=(
    /lib64/ld-linux-x86-64.so.2
    /lib/x86_64-linux-gnu/libnss_files.so.2
    /lib/x86_64-linux-gnu/libnss_dns.so.2
    /lib/x86_64-linux-gnu/libresolv.so.2
)

for lib in "${EXTRA_LIBS[@]}"; do
    if [ -f "$lib" ]; then
        lib_target=$CONTAINER_FS$(dirname $lib)
        mkdir -p $lib_target
        cp $lib $lib_target/
    fi
done

# Create device files (skip if exist)
[ ! -e $CONTAINER_FS/dev/null ] && mknod -m 666 $CONTAINER_FS/dev/null c 1 3
[ ! -e $CONTAINER_FS/dev/zero ] && mknod -m 666 $CONTAINER_FS/dev/zero c 1 5
[ ! -e $CONTAINER_FS/dev/random ] && mknod -m 666 $CONTAINER_FS/dev/random c 1 8
[ ! -e $CONTAINER_FS/dev/urandom ] && mknod -m 666 $CONTAINER_FS/dev/urandom c 1 9

# Basic etc files
cat > $CONTAINER_FS/etc/passwd <<EOF
root:x:0:0:root:/root:/bin/bash
EOF

cat > $CONTAINER_FS/etc/group <<EOF
root:x:0:
EOF

cat > $CONTAINER_FS/etc/resolv.conf <<EOF
nameserver 8.8.8.8
EOF

# Network setup
ip netns add $CONTAINER_NAME 2>/dev/null || true
ip link add veth0 type veth peer name veth1 2>/dev/null || true
ip link set veth1 netns $CONTAINER_NAME 2>/dev/null || true
ip addr add $HOST_IP/24 dev veth0 2>/dev/null || true
ip link set veth0 up 2>/dev/null || true

ip netns exec $CONTAINER_NAME ip addr add $CONTAINER_IP/24 dev veth1 2>/dev/null || true
ip netns exec $CONTAINER_NAME ip link set veth1 up 2>/dev/null || true
ip netns exec $CONTAINER_NAME ip link set lo up 2>/dev/null || true
ip netns exec $CONTAINER_NAME ip route add default via $HOST_IP 2>/dev/null || true

# NAT
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -t nat -A POSTROUTING -s $CONTAINER_IP/24 -o eth0 -j MASQUERADE 2>/dev/null || true
iptables -A FORWARD -i veth0 -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -o veth0 -j ACCEPT 2>/dev/null || true

# Cgroups setup
echo "Configuring cgroups..."
# Memory cgroup
cgcreate -g memory:$CONTAINER_NAME
echo $(( $(echo $MEMORY_LIMIT | sed 's/[^0-9]*//g') * 1024 * 1024 )) > /sys/fs/cgroup/memory/$CONTAINER_NAME/memory.limit_in_bytes
echo $(( $(echo $MEMORY_LIMIT | sed 's/[^0-9]*//g') * 1024 * 1024 )) > /sys/fs/cgroup/memory/$CONTAINER_NAME/memory.memsw.limit_in_bytes

# CPU cgroup
cgcreate -g cpu:$CONTAINER_NAME
echo $CPU_QUOTA > /sys/fs/cgroup/cpu/$CONTAINER_NAME/cpu.cfs_quota_us
echo $CPU_PERIOD > /sys/fs/cgroup/cpu/$CONTAINER_NAME/cpu.cfs_period_us

# Start container function
start_container() {
    # Mount filesystems
    mount -t proc proc $CONTAINER_FS/proc
    mount -t sysfs sysfs $CONTAINER_FS/sys
    mount --bind /dev $CONTAINER_FS/dev
    
    # Enter container
    unshare --pid --mount-proc --fork --mount --uts --ipc --net=/var/run/netns/$CONTAINER_NAME \
        chroot $CONTAINER_FS /bin/bash -c "
        export PATH=/bin:/sbin:/usr/bin:/usr/sbin
        export PS1='[$CONTAINER_NAME] \w \$ '
        hostname $CONTAINER_NAME
        exec /bin/bash
    "
}

# Start if requested
[ "$2" = "start" ] && { start_container; exit; }

echo "Container $CONTAINER_NAME ready at $CONTAINER_FS"
echo "Start with: sudo ./isolate.sh $CONTAINER_NAME start"
echo "Clean with: sudo ./isolate.sh $CONTAINER_NAME clean"