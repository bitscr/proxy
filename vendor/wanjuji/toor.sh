#!/bin/sh

# =====================
# 启动 proot 函数
# =====================
start_proot() {
    ROOTFS="$1"

    if [ ! -x "$ROOTFS/usr/local/bin/toor" ]; then
        echo "ERROR: proot not found in $ROOTFS/usr/local/bin/toor"
        exit 1
    fi

    # 避免 ptrace/SECCOMP 问题
    export PROOT_NO_SECCOMP=1

    BIND_OPTS="-b /dev -b /proc -b /sys -b /etc/resolv.conf -b $ROOTFS/lib"
    [ -d "$ROOTFS/lib64" ] && BIND_OPTS="$BIND_OPTS -b $ROOTFS/lib64"

    exec "$ROOTFS/usr/local/bin/toor" \
        --rootfs="$ROOTFS" \
        -0 \
        -w "/root" \
        $BIND_OPTS \
        --kill-on-exit
}

# =====================
# 基础变量
# =====================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOTFS_DIR="$SCRIPT_DIR"

# 如果存在 MyWorlds 子目录就使用它
[ -d "$ROOTFS_DIR/MyWorlds/etc" ] && [ -d "$ROOTFS_DIR/MyWorlds/usr" ] && ROOTFS_DIR="$ROOTFS_DIR/MyWorlds"

export PATH="$PATH:$HOME/.local/usr/bin"
ARCH=$(uname -m)

# 架构判断
if [ "$ARCH" = "x86_64" ]; then
    ARCH_ALT="amd64"
    UBUNTU_URL="http://cdimage.ubuntu.com/ubuntu-base/releases/20.04/release/ubuntu-base-20.04.4-base-${ARCH_ALT}.tar.gz"
    ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/alpine-minirootfs-3.22.0-x86_64.tar.gz"
elif [ "$ARCH" = "aarch64" ]; then
    ARCH_ALT="arm64"
    UBUNTU_URL="http://cdimage.ubuntu.com/ubuntu-base/releases/20.04/release/ubuntu-base-20.04.4-base-${ARCH_ALT}.tar.gz"
    ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/aarch64/alpine-minirootfs-3.22.0-aarch64.tar.gz"
else
    echo "Unsupported CPU architecture: $ARCH"
    exit 1
fi

# =====================
# 安装函数
# =====================
install_ubuntu() {
    echo "Downloading Ubuntu 20.04 rootfs..."
    mkdir -p "$ROOTFS_DIR"
    curl -L -o /tmp/rootfs.tar.gz "$UBUNTU_URL"
    tar -xf /tmp/rootfs.tar.gz -C "$ROOTFS_DIR"
    fix_ubuntu_ld
}

install_alpine() {
    echo "Downloading Alpine 3.22 rootfs..."
    mkdir -p "$ROOTFS_DIR"
    curl -L -o /tmp/rootfs.tar.gz "$ALPINE_URL"
    tar -xf /tmp/rootfs.tar.gz -C "$ROOTFS_DIR"
}

# 修复 Ubuntu 20.04 的动态链接器符号链接
fix_ubuntu_ld() {
    if [ -f "$ROOTFS_DIR/lib/x86_64-linux-gnu/ld-2.31.so" ] && [ ! -f "$ROOTFS_DIR/lib64/ld-linux-x86-64.so.2" ]; then
        mkdir -p "$ROOTFS_DIR/lib64"
        rm -f "$ROOTFS_DIR/lib64/ld-linux-x86-64.so.2"
        ln -s ../lib/x86_64-linux-gnu/ld-2.31.so "$ROOTFS_DIR/lib64/ld-linux-x86-64.so.2"
        echo "Fixed Ubuntu ld-linux-x86-64.so.2 link"
    fi
}

install_proot() {
    mkdir -p "$ROOTFS_DIR/usr/local/bin"
    curl -L -o "$ROOTFS_DIR/usr/local/bin/toor" \
        "https://raw.githubusercontent.com/kof96zip/MyWorlds/main/proot-${ARCH}"

    while [ ! -s "$ROOTFS_DIR/usr/local/bin/toor" ]; do
        rm -f "$ROOTFS_DIR/usr/local/bin/toor"
        curl -L -o "$ROOTFS_DIR/usr/local/bin/toor" \
            "https://raw.githubusercontent.com/kof96zip/MyWorlds/main/proot-${ARCH}"
        sleep 1
    done

    chmod 755 "$ROOTFS_DIR/usr/local/bin/toor"
}

configure_dns() {
    mkdir -p "$ROOTFS_DIR/etc"
    printf "nameserver 1.1.1.1\nnameserver 1.0.0.1\n" > "$ROOTFS_DIR/etc/resolv.conf"
}

# =====================
# 自动化安装逻辑
# =====================
if [ ! -e "$ROOTFS_DIR/.installed" ]; then
    echo "Select which environment to install:"
    echo "[1] Ubuntu 20.04"
    echo "[2] Alpine 3.22"
    read -p "Enter choice [1/2]: " choice

    case "$choice" in
        1) install_ubuntu ;;
        2) install_alpine ;;
        *) echo "Invalid choice, exiting."; exit 1 ;;
    esac

    install_proot
    configure_dns
    touch "$ROOTFS_DIR/.installed"
fi

# =====================
# 启动 proot
# =====================
start_proot "$ROOTFS_DIR"
