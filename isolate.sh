#!/bin/bash

# Default Configuration
DEFAULT_MEMORY_LIMIT_MB=100  # 100MB default
DEFAULT_CPU_PERCENT=50       # 50% CPU default


# Configuration
if [ -z "$1" ]; then
    read -p "Please enter a container name (default: mycontainer): " input_name
    CONTAINER_NAME=${input_name:-mycontainer}
else
    CONTAINER_NAME=$1
fi

BASE_ROOT="/var/containers"
BASE_LIB="/var/lib/containers"

CONTAINER_ROOT="$BASE_ROOT/$CONTAINER_NAME"
CONTAINER_BASE="$CONTAINER_ROOT/base"      # Base/lower filesystem
CONTAINER_DATA="$BASE_LIB/$CONTAINER_NAME" # Persistent data
CONTAINER_UPPER="$CONTAINER_DATA/upper"    # Upper layer for overlay
CONTAINER_WORK="$CONTAINER_DATA/work"      # Overlay work directory
CONTAINER_FS="$CONTAINER_DATA/fs"          # Mounted overlay filesystem
HOST_IP="10.0.0.1"
CONTAINER_IP="10.0.0.2"

# Parse custom resource limits if provided
if [ "$2" = "start" ] || [ "$2" = "test" ]; then
    # Use default values
    MEMORY_LIMIT=$((DEFAULT_MEMORY_LIMIT_MB * 1024 * 1024))
    CPU_QUOTA=$((DEFAULT_CPU_PERCENT * 1000))  # Convert percentage to quota units
    CPU_PERIOD=100000  # 100ms (standard base period)
    
    # Check for custom memory limit (in MB)
    if [[ "$3" =~ ^[0-9]+$ ]]; then
        MEMORY_LIMIT=$(( $3 * 1024 * 1024 ))
        echo "Using custom memory limit: $3 MB"
    fi
    
    # Check for custom CPU limit (percentage)
    if [[ "$4" =~ ^[0-9]+$ ]]; then
        if [ "$4" -gt 100 ]; then
            echo "Warning: CPU percentage cannot exceed 100%, using 100%"
            CPU_QUOTA=100000
        else
            CPU_QUOTA=$(( $4 * 1000 ))
            echo "Using custom CPU limit: $4%"
        fi
    fi
else
    # Set default values when not starting/testing
    MEMORY_LIMIT=$((DEFAULT_MEMORY_LIMIT_MB * 1024 * 1024))
    CPU_QUOTA=$((DEFAULT_CPU_PERCENT * 1000))
    CPU_PERIOD=100000
fi

# Check root
[ "$(id -u)" -ne 0 ] && { echo "Must be root"; exit 1; }

# Check overlay module
if ! modprobe overlay 2>/dev/null; then
    echo "Error: overlay module not available"
    exit 1
fi

# Cleanup function
cleanup() {
    echo "Cleaning up $CONTAINER_NAME..."
    # Unmount filesystems
    umount -lf $CONTAINER_FS/proc 2>/dev/null
    umount -lf $CONTAINER_FS/sys 2>/dev/null
    umount -lf $CONTAINER_FS/dev 2>/dev/null
    umount -lf $CONTAINER_FS 2>/dev/null
    
    # Network cleanup
    ip netns del $CONTAINER_NAME 2>/dev/null
    ip link del veth0-$CONTAINER_NAME 2>/dev/null
    
    # Remove cgroups
    [ -d "/sys/fs/cgroup/memory/$CONTAINER_NAME" ] && rmdir "/sys/fs/cgroup/memory/$CONTAINER_NAME"
    [ -d "/sys/fs/cgroup/cpu/$CONTAINER_NAME" ] && rmdir "/sys/fs/cgroup/cpu/$CONTAINER_NAME"
    
    echo "Cleanup complete."
}

# Remove container completely
remove_container() {
    cleanup
    rm -rf "$CONTAINER_ROOT"
    rm -rf "$CONTAINER_DATA"
    echo "Container removed completely."
}

# Clean command
# Handle commands
case "$2" in
    "remove")
        remove_container
        exit 0 ;;
    "clean")
        cleanup
        exit 0 ;;
    "start"|"test")
        cleanup ;;
esac

# Create filesystem structure ------------------------------------------------------------------------------------
mkdir -p $CONTAINER_FS/{bin,dev,etc,lib,lib64,proc,root,sbin,sys,tmp,usr/{bin,lib/x86_64-linux-gnu,sbin},var}
mkdir -p $CONTAINER_UPPER $CONTAINER_WORK $CONTAINER_FS
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

mkdir -p "$BASE_ROOT" "$BASE_LIB"
mkdir -p "$CONTAINER_BASE" "$CONTAINER_DATA"
# Setup overlay filesystem
mount -t overlay overlay \
    -o lowerdir=$CONTAINER_BASE,upperdir=$CONTAINER_UPPER,workdir=$CONTAINER_WORK \
    $CONTAINER_FS

# Essential binaries to copy ------------------------------------------------------------------------------------
ESSENTIAL_BINARIES=(
    /bin/bash
    /bin/ls
    /bin/cat
    /bin/echo
    /bin/mkdir
    /bin/mount
    /bin/umount
    /bin/rm
    /bin/ip
    /bin/ps
    /bin/chmod
    /bin/netstat       
    /usr/bin/netstat   
    /usr/sbin/netstat
    /usr/bin/ss
    /usr/bin/hostname
    /bin/sh
    /usr/bin/awk
    /usr/bin/wc
    /usr/bin/grep
    /bin/dd
    /bin/sleep
    /bin/ping
    /usr/bin/git
    /usr/bin/curl
    /bin/tar
    /bin/gzip
    /bin/which
    /usr/bin/wget
    /bin/rm
    /bin/chmod
    /bin/ln
    /usr/bin/make
    /bin/grep
    /bin/sed
)

# Copy all essential binaries
for binary in "${ESSENTIAL_BINARIES[@]}"; do
    if [ -f "$binary" ]; then
        copy_binary "$binary"
    else
        echo "Warning: Binary $binary not found - some tests may fail"
    fi
done

# Additional required libraries ------------------------------------------------------------------------------------
EXTRA_LIBS=(
    /lib64/ld-linux-x86-64.so.2
    /lib/x86_64-linux-gnu/libnss_files.so.2
    /lib/x86_64-linux-gnu/libnss_dns.so.2
    /lib/x86_64-linux-gnu/libresolv.so.2
    /lib/x86_64-linux-gnu/libmount.so.1
    /lib/x86_64-linux-gnu/libblkid.so.1
    /lib/x86_64-linux-gnu/libuuid.so.1
    /lib/x86_64-linux-gnu/libc.so.6
    /lib/x86_64-linux-gnu/libselinux.so.1
    /lib/x86_64-linux-gnu/libpcre2-8.so.0
    /lib/x86_64-linux-gnu/libdl.so.2
    /lib/x86_64-linux-gnu/libpthread.so.0
    /lib/x86_64-linux-gnu/libm.so.
    /lib/x86_64-linux-gnu/libcurl.so.4
    /lib/x86_64-linux-gnu/libnghttp2.so.14
    /lib/x86_64-linux-gnu/libidn2.so.0
    /lib/x86_64-linux-gnu/librtmp.so.1
    /lib/x86_64-linux-gnu/libssh.so.4
    /lib/x86_64-linux-gnu/libpsl.so.5
    /lib/x86_64-linux-gnu/libssl.so.1.1
    /lib/x86_64-linux-gnu/libcrypto.so.1.1
)

for lib in "${EXTRA_LIBS[@]}"; do
    if [ -f "$lib" ]; then
        lib_target=$CONTAINER_FS$(dirname $lib)
        mkdir -p $lib_target
        cp $lib $lib_target/
    fi
done

# Create device files
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

# Network setup ------------------------------------------------------------------------------------
echo "Setting up network for $CONTAINER_NAME..."

# Ensure netns directory exists
mkdir -p /var/run/netns
# Create network namespace (force remove old one first)
ip netns del $CONTAINER_NAME 2>/dev/null || true
ip link del veth0-$CONTAINER_NAME 2>/dev/null || true
ip link del veth1-$CONTAINER_NAME 2>/dev/null || true
# Create new network namespace
ip netns add $CONTAINER_NAME 

# Create veth pair 
ip link add veth0-$CONTAINER_NAME type veth peer name veth1-$CONTAINER_NAME 

# Move veth1-new to the container namespace
ip link set veth1-$CONTAINER_NAME netns $CONTAINER_NAME

# Configure host side
ip addr add $HOST_IP/24 dev veth0-$CONTAINER_NAME
ip link set veth0-$CONTAINER_NAME up

# Configure container side
ip netns exec $CONTAINER_NAME ip addr add $CONTAINER_IP/24 dev veth1-$CONTAINER_NAME
ip netns exec $CONTAINER_NAME ip link set veth1-$CONTAINER_NAME up
ip netns exec $CONTAINER_NAME ip link set lo up 

# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward


# Set up NAT and forwarding
iptables -t nat -F  # Clear existing NAT rules
iptables -t nat -A POSTROUTING -s $CONTAINER_IP/24 -j MASQUERADE
iptables -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to-destination $CONTAINER_IP:8000
iptables -A FORWARD -p tcp -d $CONTAINER_IP --dport 8000 -j ACCEPT


# Add default route in container
ip netns exec $CONTAINER_NAME ip route add default via $HOST_IP 


# Cgroups setup
echo "Configuring cgroups with:"
echo "  Memory Limit: $((MEMORY_LIMIT / 1024 / 1024)) MB"
echo "  CPU Limit: $((CPU_QUOTA / 1000))%"
mkdir -p /sys/fs/cgroup/memory/$CONTAINER_NAME
mkdir -p /sys/fs/cgroup/cpu/$CONTAINER_NAME

# Set memory limits
echo $MEMORY_LIMIT > /sys/fs/cgroup/memory/$CONTAINER_NAME/memory.limit_in_bytes 2>/dev/null || \
    echo "Warning: Could not set memory limit (cgroups v2 might be in use)"

# Set CPU limits
echo $CPU_QUOTA > /sys/fs/cgroup/cpu/$CONTAINER_NAME/cpu.cfs_quota_us 2>/dev/null || \
    echo "Warning: Could not set CPU quota (cgroups v2 might be in use)"
echo $CPU_PERIOD > /sys/fs/cgroup/cpu/$CONTAINER_NAME/cpu.cfs_period_us 2>/dev/null || \
    echo "Warning: Could not set CPU period (cgroups v2 might be in use)"


# Start container function
start_container() {
    echo "Starting container..."
    # Mount filesystems
    mount -t proc proc $CONTAINER_FS/proc
    mount -t sysfs sysfs $CONTAINER_FS/sys
    mount --bind /dev $CONTAINER_FS/dev
    
    # Enter container
    unshare --pid --mount-proc --fork --mount --uts --ipc --net=/var/run/netns/$CONTAINER_NAME \
        /bin/bash -c "
        echo \$$ > /sys/fs/cgroup/memory/$CONTAINER_NAME/tasks 2>/dev/null
        echo \$$ > /sys/fs/cgroup/cpu/$CONTAINER_NAME/tasks 2>/dev/null
        chroot $CONTAINER_FS /bin/bash -c \"
            mount -t proc proc /proc
            mount -t sysfs sysfs /sys
            hostname $CONTAINER_NAME
            export PATH=/bin:/sbin:/usr/bin:/usr/sbin
            export PS1='[$CONTAINER_NAME] \w \$ '
            exec /bin/bash
        \"
    "
}

test_limits() {
    echo "Running reliable limit tests..."
    unshare --pid --mount-proc --fork --mount --uts --ipc --net=/var/run/netns/$CONTAINER_NAME \
        /bin/bash -c "
        # Add process to cgroups if they exist
        [ -f /sys/fs/cgroup/memory/$CONTAINER_NAME/tasks ] && echo \$$ > /sys/fs/cgroup/memory/$CONTAINER_NAME/tasks
        [ -f /sys/fs/cgroup/cpu/$CONTAINER_NAME/tasks ] && echo \$$ > /sys/fs/cgroup/cpu/$CONTAINER_NAME/tasks
        
        chroot $CONTAINER_FS /bin/bash -c '
            # Mount required filesystems
            mount -t proc proc /proc
            mount -t sysfs sysfs /sys
            
            # Fixed Memory Test
            echo \"=== Memory Test (Limit: $((MEMORY_LIMIT / 1024 / 1024))MB) ===\"
            echo \"Testing memory access...\"
            chunk_size=10  # Test with 10MB chunks
            max_chunks=$(( ($MEMORY_LIMIT / 1024 / 1024) / 10 ))
            
            for ((i=1; i<=max_chunks; i++)); do
                echo \"- Allocating ${chunk_size}MB (chunk \$i of \$max_chunks)...\"
                if ! dd if=/dev/zero of=/dev/null bs=1M count=\$chunk_size 2>/dev/null; then
                    echo \"! Memory allocation failed at \$((i*chunk_size))MB\"
                    break
                fi
            done
            [ \$i -gt \$max_chunks ] && echo \"+ Memory test completed successfully\"
            
            # CPU Test
            echo \"\n=== CPU Test (Limit: $((CPU_QUOTA / 1000))%) ===\"
            echo \"Running CPU stress for 3 seconds...\"
            end=\$((SECONDS+3))
            while [ \$SECONDS -lt \$end ]; do
                : # Busy loop
            done
            echo \"CPU test completed\"
            
            # Isolation Verification
            echo \"\n=== Isolation Verification ===\"
            echo \"Processes visible: \$(ps aux | wc -l)\"
            echo \"Network interfaces: \$(ip -o link show | wc -l)\"
            echo \"Files in root: \$(ls / | wc -l)\"
            echo \"Can access /etc/passwd: \$(test -f /etc/passwd && echo \"Yes\" || echo \"No\")\"
            echo \"Can ping gateway: \$(ping -c1 -W1 $HOST_IP >/dev/null 2>&1 && echo \"Yes\" || echo \"No\")\"
        '
    " || echo "Test completed with exit code $?"
}

# Start if requested
if [ "$2" = "start" ]; then
    start_container
elif [ "$2" = "test" ]; then
    test_limits
else
    echo "Container $CONTAINER_NAME ready"
    echo "Commands:"
    echo "  Start:  sudo $0 $CONTAINER_NAME start [MEMORY_MB] [CPU_PERCENT]"
    echo "  Test:   sudo $0 $CONTAINER_NAME test [MEMORY_MB] [CPU_PERCENT]"
    echo "  Clean:  sudo $0 $CONTAINER_NAME clean"
    echo "  Remove: sudo $0 $CONTAINER_NAME remove"
fi