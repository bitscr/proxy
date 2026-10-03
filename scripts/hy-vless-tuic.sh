#!/bin/sh
# ============================================================================
# 极端环境保护：Alpine / minimal 系统默认没有 bash。
# 用 sh 直接跑（sh <脚本名>）时先自举安装 bash，再切回 bash 重新执行自己。
# ============================================================================
if [ -z "$BASH_VERSION" ]; then
    if ! command -v bash > /dev/null 2>&1; then
        echo "当前 shell 不是 bash，正在尝试安装 bash..."
        if command -v apk > /dev/null 2>&1; then
            apk add --no-cache bash > /dev/null 2>&1
        elif command -v apt-get > /dev/null 2>&1; then
            apt-get update -y > /dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y bash > /dev/null 2>&1
        elif command -v yum > /dev/null 2>&1; then
            yum install -y bash > /dev/null 2>&1
        elif command -v dnf > /dev/null 2>&1; then
            dnf install -y bash > /dev/null 2>&1
        fi
    fi
    if command -v bash > /dev/null 2>&1 && [ -f "$0" ]; then
        exec bash "$0" "$@"
    fi
    echo "错误: 本脚本需要 bash。请先安装后重试（Alpine: apk add bash / Debian: apt-get install -y bash）"
    echo "或者用: curl -fsSL <脚本地址> | bash"
    exit 1
fi
# ============================================================================

# 当前脚本文件名（提示文案用，改名后也不会对不上）
SELF="${0##*/}"
[ -z "$SELF" ] && SELF="hy-vless-tuic.sh"

# --- 颜色定义 ---
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
purple='\033[0;35m'
skyblue='\033[0;36m'
white='\033[1;91m' # 亮红色
re='\033[0m' # 重置颜色

# --- 辅助函数 ---

# 检查并安装软件包（apk 用 --no-cache，装完清缓存，省小机器的磁盘）
install_soft() {
    if ! command -v $1 &> /dev/null; then
        echo -e "${yellow}正在安装 $1...${re}"
        if command -v apt-get &> /dev/null; then
            # apt 列表很占磁盘：同一次运行只 update 一次，装完立刻清缓存
            if [ -z "$APT_UPDATED" ]; then
                apt-get update -y > /dev/null 2>&1
                APT_UPDATED=1
            fi
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $1
            apt-get clean > /dev/null 2>&1
        elif command -v apk &> /dev/null; then
            apk add --no-cache $1
        elif command -v yum &> /dev/null; then
            yum install -y $1
        elif command -v dnf &> /dev/null; then
            dnf install -y $1
        else
            echo -e "${yellow}警告: 没有可用的包管理器，跳过 $1 的安装（若后面报命令找不到，请手动安装）${re}"
            return 1
        fi
    fi
}

# 命令是否存在
has() { command -v "$1" > /dev/null 2>&1; }

# 结束进程：优先 pkill，缺了就直接扫 /proc（容器/minimal 系统常常没有 procps）
kill_by_cmdline() { # $1=命令行子串
    if has pkill; then
        pkill -f "$1" > /dev/null 2>&1
        return 0
    fi
    local d pid cl
    for d in /proc/[0-9]*; do
        [ -r "$d/cmdline" ] || continue
        cl=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)
        case "$cl" in
            *"$1"*)
                pid=${d#/proc/}
                [ "$pid" != "$$" ] && kill "$pid" > /dev/null 2>&1
                ;;
        esac
    done
    return 0
}

# 进程是否在跑：pgrep -> /proc 扫描
proc_running() { # $1=命令行子串
    if has pgrep; then
        pgrep -f "$1" > /dev/null 2>&1 && return 0
        return 1
    fi
    local d cl
    for d in /proc/[0-9]*; do
        [ -r "$d/cmdline" ] || continue
        cl=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)
        case "$cl" in
            *"$1"*) return 0 ;;
        esac
    done
    return 1
}

# --- 环境探测：兼容性 / 最小环境的基础 ---
PROXY_LOW_MEM="${PROXY_LOW_MEM:-auto}"     # auto|1|0  低内存档开关
PROXY_MIN_FREE_MB="${PROXY_MIN_FREE_MB:-}" # 手动指定可用磁盘阈值（MB），用于磁盘不足时强制安装

ENV_OS=""; ENV_INIT=""; ENV_ARCH=""; ENV_MUSL=0; ENV_RAM_MB=0; ENV_DISK_FREE_MB=0; ENV_LOWMEM=0

# ============================================================================
# 内核网络调优：BBR + fq（Reality/TCP 用）+ UDP 缓冲（Hysteria2/Tuic 用）
# 全部逐项探测可用性，缺了就跳过——不允许因为调优把安装搞挂
# ============================================================================

# 写 sysctl：/etc/sysctl.d 优先，不行就 /etc/sysctl.conf，再不行直接 /proc（重启失效但本次有效）
# 注意：/etc 写成功了但 /proc 写不进去时（受限容器），配置只对下次重启生效——返回值如实反映
sysctl_apply() { # $1=key $2=value；返回 0=本次运行已生效，1=仅持久化或完全失败
    local key=$1 val=$2 live=0 saved=0 conf=""
    # 1) 直接写 /proc 立即生效。
    # 不能用 [ -w ] 判断：root 对只读挂载的 /proc/sys 也显示"可写"，只有真写一次才知道
    if printf '%s\n' "$val" > "/proc/sys/$key" 2>/dev/null; then
        live=1
    fi
    # 2) 持久化：能写 /etc/sysctl.d 就写配置文件
    if [ -d /etc/sysctl.d ] && [ -w /etc/sysctl.d ]; then
        conf="/etc/sysctl.d/99-proxy-tuning.conf"
    elif [ -f /etc/sysctl.conf ] && [ -w /etc/sysctl.conf ]; then
        conf="/etc/sysctl.conf"
    fi
    if [ -n "$conf" ]; then
        # 同键已配置过就不重复追加（幂等）
        if ! grep -qE "^[[:space:]]*net\.[/.]${key#net/}[[:space:]]*=" "$conf" 2>/dev/null; then
            printf '\n# added by proxy script\n%s = %s\n' "$(echo "$key" | tr '/' '.')" "$val" >> "$conf" 2>/dev/null && saved=1
        else
            saved=1
        fi
    fi
    [ "$live" = 1 ] && return 0
    return 1
}

# 当前内核是否已启用 BBR（读可用算法列表 + 当前值）
bbr_available() {
    if ! [ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]; then
        return 1
    fi
    local avail cur
    avail=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)
    cur=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)
    case " $avail " in
        *" bbr "*) return 0 ;;
    esac
    # 当前已经是 bbr 也算可用
    [ "$cur" = "bbr" ] && return 0
    return 1
}

# 可选加载 tcp_bbr 模块（很多发行版默认没编进去但可以 modprobe）
bbr_try_load() {
    if bbr_available; then return 0; fi
    if has modprobe; then
        modprobe tcp_bbr > /dev/null 2>&1
    fi
    bbr_available
}

kernel_tune() {
    local notes=""
    # --- BBR + fq（对 Reality/TCP 有效；Hysteria2 是 Brutal、Tuic 自带 BBR，不受此项影响） ---
    if [ -r /proc/sys/net/ipv4/tcp_congestion_control ]; then
        if bbr_try_load; then
            local cur_cc
            cur_cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)
            if [ "$cur_cc" = "bbr" ]; then
                notes="${notes}BBR已是默认 "
            elif sysctl_apply net/ipv4/tcp_congestion_control bbr; then
                notes="${notes}BBR已开启 "
            else
                notes="${notes}BBR开启失败(可能没权限) "
            fi
            # fq：内核没有会写失败，自动跳过
            if [ "$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)" = "fq" ]; then
                notes="${notes}fq队列已是默认 "
            elif sysctl_apply net/core/default_qdisc fq; then
                notes="${notes}fq队列已开启 "
            fi
        else
            notes="${notes}内核不支持BBR(跳过) "
        fi
    else
        notes="${notes}无TCP调优接口(跳过) "
    fi

    # --- UDP 缓冲（对 Hysteria2/Tuic 有效）；低内存档用小值，128MB 机器不吃满 16MB ---
    local buf=16777216
    [ "$ENV_LOWMEM" = 1 ] && buf=4194304
    local cur_rm cur_wm
    cur_rm=$(cat /proc/sys/net/core/rmem_max 2>/dev/null)
    cur_wm=$(cat /proc/sys/net/core/wmem_max 2>/dev/null)
    if [ -n "$cur_rm" ] && [ "$cur_rm" -ge "$buf" ] && [ -n "$cur_wm" ] && [ "$cur_wm" -ge "$buf" ]; then
        notes="${notes}UDP缓冲已达标 "
    elif sysctl_apply net/core/rmem_max "$buf" && sysctl_apply net/core/wmem_max "$buf"; then
        if [ "$buf" -ge 1048576 ]; then
            notes="${notes}UDP缓冲=$((buf/1048576))MB "
        else
            notes="${notes}UDP缓冲=$((buf/1024))KB "
        fi
    else
        # LXC/Docker 里 net.* sysctl 常被宿主锁成只读；如果已持久化到 /etc，重启后生效
        if grep -qs "net.core.rmem_max" /etc/sysctl.d/99-proxy-tuning.conf /etc/sysctl.conf 2>/dev/null; then
            notes="${notes}UDP缓冲已写入配置,重启后生效 "
        else
            notes="${notes}UDP缓冲设不了(宿主限制,LXC常见) "
        fi
    fi
    [ -n "$notes" ] && echo -e "${skyblue}内核调优: ${notes}${re}"
    return 0
}

# 安装目录所在分区可用空间（MB）：/ 与 /usr/local 里较小的那个
disk_free_mb() {
    local a b
    a=$(df -Pk / 2>/dev/null | awk 'NR==2{print int($4/1024)}')
    b=$(df -Pk /usr/local 2>/dev/null | awk 'NR==2{print int($4/1024)}')
    [ -z "$a" ] && a=0
    if [ -z "$b" ]; then echo "$a"; return; fi
    [ "$b" -lt "$a" ] && echo "$b" || echo "$a"
}

# 真实可用内存（MB）：/proc/meminfo 在容器里常常报宿主机内存，要和 cgroup 限值取小的那个
mem_total_mb() {
    local m=0 c=""
    m=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
    [ -z "$m" ] && m=0
    if [ -r /sys/fs/cgroup/memory.max ]; then
        c=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        c=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
    fi
    case "$c" in
        ""|"max"|*[!0-9]*) : ;;
        *)
            c=$((c / 1024 / 1024))
            # 上限超过 1TB 视为没设限
            if [ "$c" -gt 1048576 ]; then : ; elif [ "$m" -eq 0 ] || [ "$c" -lt "$m" ]; then
                m=$c
            fi
            ;;
    esac
    echo "$m"
}

env_detect() {
    ENV_ARCH=$(uname -m)
    if [ -f /etc/alpine-release ]; then ENV_OS="alpine"; ENV_MUSL=1
    elif [ -f /etc/debian_version ]; then ENV_OS="debian"
    elif [ -f /etc/redhat-release ]; then ENV_OS="rhel"
    elif [ -f /etc/arch-release ]; then ENV_OS="arch"
    else ENV_OS="unknown"
    fi

    # 服务管理器：systemd / openrc / 都没有（容器里很常见）
    if [ -d /run/systemd/system ] && has systemctl; then ENV_INIT="systemd"
    elif [ -f /run/openrc/softlevel ] && has rc-service; then ENV_INIT="openrc"
    else ENV_INIT="none"
    fi

    ENV_RAM_MB=$(mem_total_mb)
    [ -z "$ENV_RAM_MB" ] && ENV_RAM_MB=0
    ENV_DISK_FREE_MB=$(disk_free_mb)
    [ -z "$ENV_DISK_FREE_MB" ] && ENV_DISK_FREE_MB=0

    ENV_LOWMEM=0
    case "$PROXY_LOW_MEM" in
        1|yes|on)  ENV_LOWMEM=1 ;;
        0|no|off)  ENV_LOWMEM=0 ;;
        *) if [ "$ENV_RAM_MB" -gt 0 ] && [ "$ENV_RAM_MB" -lt 320 ]; then ENV_LOWMEM=1; fi ;;
    esac
}

# 一行环境摘要
env_line() {
    local libc="glibc" mode="标准"
    [ "$ENV_MUSL" = 1 ] && libc="musl"
    [ "$ENV_LOWMEM" = 1 ] && mode="低内存"
    echo -e "${skyblue}本机: ${ENV_OS}/${ENV_ARCH} (${libc}) | 服务管理: ${ENV_INIT} | 内存: ${ENV_RAM_MB}MB | 可用磁盘: ${ENV_DISK_FREE_MB}MB | 模式: ${mode}${re}"
}

# 安装前预检：磁盘 / 内存。$1=需要MB $2=协议名
env_precheck() {
    local need=$1 name=$2 free=${PROXY_MIN_FREE_MB:-$ENV_DISK_FREE_MB}
    if [ "$free" -lt "$need" ]; then
        echo -e "${red}磁盘空间不足: 安装 $name 大约需要 ${need}MB，本机可用 ${ENV_DISK_FREE_MB}MB${re}"
        echo -e "${yellow}可以这样处理:${re}"
        echo -e "  1) 先清包缓存: apk cache clean / apt-get clean"
        echo -e "  2) 三个协议别全装：装好后常驻约 62MB（Xray 37 + Hysteria 23 + Tuic 2）"
        echo -e "     下载时还要 1.5~2 倍临时空间（Xray 约 60MB / Hysteria 约 50MB / Tuic 约 15MB）"
        echo -e "  3) 确认够用就强制跳过检查: PROXY_MIN_FREE_MB=1 ./$SELF"
        return 1
    fi
    if [ "$ENV_RAM_MB" -gt 0 ] && [ "$ENV_RAM_MB" -lt 192 ]; then
        echo -e "${yellow}提示: 本机内存 ${ENV_RAM_MB}MB，按低内存档安装${re}"
    fi
    return 0
}

# --- 下载：curl -> wget 回退；直链失败 -> 用 GitHub API 解析官方资产地址 ---
http_fetch() { # $1=url $2=输出文件
    if has curl; then
        curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 -o "$2" "$1"
    elif has wget; then
        wget -q -T 30 -t 3 -O "$2" "$1"
    else
        return 127
    fi
}

http_get() { # $1=url [$2=超时秒]
    local t="${2:-6}"
    if has curl; then curl -s --max-time "$t" "$1"
    elif has wget; then wget -q -T "$t" -O - "$1" 2>/dev/null
    else return 127
    fi
}

# 从官方 API 取 release 资产地址（不引入任何第三方镜像）；$2 = 资产名（精确匹配）
gh_asset_url() { # $1=owner/repo $2=资产名
    local json pat
    json=$(http_get "https://api.github.com/repos/$1/releases/latest" 20) || return 1
    [ -z "$json" ] && return 1
    pat=$(printf '%s' "$2" | sed 's/\./\\./g')
    printf '%s' "$json" | tr ',' '\n' \
        | sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | grep -E "/$pat\$" | head -1
}

download_official() { # $1=直链 $2=owner/repo $3=资产名 $4=输出文件
    if http_fetch "$1" "$4"; then return 0; fi
    echo -e "${yellow}直链下载失败，改用 GitHub API 解析同一官方仓库的地址重试...${re}"
    local alt
    alt=$(gh_asset_url "$2" "$3") || return 1
    [ -z "$alt" ] && return 1
    http_fetch "$alt" "$4"
}

# --- 随机值：不依赖 openssl / shuf ---
rand_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
        return
    fi
    local h
    h=$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')
    printf '%s-%s-%s-%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
}

rand_token() { # 12 位随机串
    od -An -tx1 -N8 /dev/urandom 2>/dev/null | tr -d ' \n' | cut -c1-12
}

rand_port() { # 10000-65000
    if has shuf; then
        shuf -i 2000-65000 -n 1
    else
        awk 'BEGIN{srand(); printf "%d\n", 2000+int(rand()*63001)}'
    fi
}

# 端口工具：netstat / ss 都没有时才装 net-tools（能少装一个包就少装）
ensure_netstat() {
    if has netstat || has ss; then
        return 0
    fi
    install_soft net-tools
}

# 自签证书：openssl -> hysteria cert（官方工具）两级回退
make_selfsigned_cert() { # $1=crt $2=key
    local crt=$1 key=$2
    rm -f "$crt" "$key"
    if has openssl; then
        openssl ecparam -genkey -name prime256v1 -out "$key" 2>/dev/null
        openssl req -x509 -new -key "$key" -out "$crt" -subj "/CN=www.bing.com" -days 36500 2>/dev/null
        [ -s "$crt" ] && [ -s "$key" ] && return 0
    fi
    if [ -x "$HY_BIN" ]; then
        "$HY_BIN" cert --host www.bing.com --cert "$crt" --key "$key" --valid-for 87600h --overwrite >/dev/null 2>&1
        [ -s "$crt" ] && [ -s "$key" ] && return 0
    fi
    return 1
}

# --- 端口占用检测：netstat -> ss -> 内核表(/proc/net)，任何 Linux 都有 ---
check_port() { # 返回 0 = 被占用
    local port=$1 hex
    if has netstat; then
        netstat -tuln 2>/dev/null | grep -qE "[:.]$port\b" && return 0
        return 1
    fi
    if has ss; then
        ss -tuln 2>/dev/null | grep -qE "[:.]$port\b" && return 0
        return 1
    fi
    hex=$(printf '%04X' "$port")
    awk -v h="$hex" 'NR>1 { n=split($2,a,":"); if (a[n]==h) { f=1; exit } } END { exit !f }' \
        /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6 2>/dev/null
}

# 端口是否处于监听（TCP 要 0A 状态，UDP 无连接状态即视为监听）
port_listening() {
    local port=$1 hex
    hex=$(printf '%04X' "$port")
    if has netstat; then
        netstat -tuln 2>/dev/null | grep -qE "[:.]$port\b" && return 0
    elif has ss; then
        ss -tuln 2>/dev/null | grep -qE "[:.]$port\b" && return 0
    fi
    awk -v h="$hex" 'NR>1 { n=split($2,a,":"); if (a[n]==h && ($4=="0A" || $4=="07")) { f=1; exit } } END { exit !f }' \
        /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6 2>/dev/null
}

# 按任意键继续
press_any_key_to_continue() {
    echo -e "${skyblue}---------------------------------------------------------${re}"
    read -n 1 -s -r -p "按任意键返回上一级菜单..."
    echo ""
}

# ============================================================================
# 服务管理抽象层：systemd -> openrc -> 都没有（nohup + ctl 脚本）三档回退
# ============================================================================
# 生成统一启动脚本（openrc / nohup 共用），systemd 直接写 ExecStart
svc_wrapper() { # $1=服务名 $2=完整命令行
    cat > "/usr/local/bin/$1-run" <<EOF
#!/bin/sh
exec $2
EOF
    chmod 755 "/usr/local/bin/$1-run"
}

# 低内存档给 Go 程序加峰值内存上限（systemd 用；这是峰值约束，不改变空载常驻）
svc_env_lines() {
    if [ "$ENV_LOWMEM" = 1 ]; then
        printf 'Environment=GOGC=30\nEnvironment=GOMEMLIMIT=64MiB\n'
    fi
}

svc_install() { # $1=systemd单元名 $2=openrc服务名 $3=描述 $4=完整命令行 $5=日志目录 $6=文档URL
    local unit=$1 oname=$2 desc=$3 cmd=$4 logdir=$5 doc=${6:-} envsh=""
    mkdir -p "$logdir"
    svc_wrapper "$oname" "$cmd"
    [ "$ENV_LOWMEM" = 1 ] && envsh=$(printf 'export GOGC=30\nexport GOMEMLIMIT=64MiB')

    case "$ENV_INIT" in
    systemd)
        if [ -n "$doc" ]; then
            cat > "/etc/systemd/system/$unit.service" <<EOF
[Unit]
Description=$desc
Documentation=$doc
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=$cmd
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity
$(svc_env_lines)
[Install]
WantedBy=multi-user.target
EOF
        else
            cat > "/etc/systemd/system/$unit.service" <<EOF
[Unit]
Description=$desc
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=$cmd
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity
$(svc_env_lines)
[Install]
WantedBy=multi-user.target
EOF
        fi
        systemctl daemon-reload
        systemctl enable "$unit" >/dev/null 2>&1
        systemctl restart "$unit"
        ;;
    openrc)
        if has supervise-daemon; then
            cat > "/etc/init.d/$oname" <<EOF
#!/sbin/openrc-run
name="$oname"
description="$desc"
command="/usr/local/bin/$oname-run"
$envsh
supervisor="supervise-daemon"
supervise_daemon_args="--respawn-delay 5 --respawn-max 0"
output_log="$logdir/access.log"
error_log="$logdir/error.log"
depend() {
    need net
    after net
}
EOF
        else
            # 老版 openrc 没有 supervise-daemon：退化成后台启动 + pidfile（进程挂了不会自动拉起）
            cat > "/etc/init.d/$oname" <<EOF
#!/sbin/openrc-run
name="$oname"
description="$desc"
command="/usr/local/bin/$oname-run"
$envsh
command_background=true
pidfile="/run/$oname.pid"
output_log="$logdir/access.log"
error_log="$logdir/error.log"
depend() {
    need net
    after net
}
EOF
        fi
        chmod 755 "/etc/init.d/$oname"
        rc-update add "$oname" default >/dev/null 2>&1
        rc-service "$oname" restart >/dev/null 2>&1
        ;;
    none)
        svc_none_install "$oname" "$logdir"
        ;;
    esac
    return 0
}

# 没有 systemd 也没有 openrc（常见于容器）：保底用 nohup + 一个 ctl 脚本
svc_none_install() { # $1=服务名 $2=日志目录
    local name=$1 logdir=$2 envsh=""
    [ "$ENV_LOWMEM" = 1 ] && envsh=$(printf 'export GOGC=30\nexport GOMEMLIMIT=64MiB\n')
    cat > "/usr/local/bin/$name-ctl" <<EOF
#!/bin/sh
case "\$1" in
start)
    if [ -f /run/$name.pid ] && kill -0 "\$(cat /run/$name.pid)" 2>/dev/null; then echo "$name 已在运行"; exit 0; fi
    $envsh
    nohup /usr/local/bin/$name-run >> "$logdir/access.log" 2>> "$logdir/error.log" &
    echo \$! > /run/$name.pid
    echo "$name 已启动 (pid \$(cat /run/$name.pid))"
    ;;
stop)
    if [ -f /run/$name.pid ]; then
        __pid=\$(cat /run/$name.pid)
        kill "\$__pid" 2>/dev/null
        __i=0
        while [ \$__i -lt 10 ] && kill -0 "\$__pid" 2>/dev/null; do sleep 0.5; __i=\$((__i+1)); done
        kill -0 "\$__pid" 2>/dev/null && kill -9 "\$__pid" 2>/dev/null
        rm -f /run/$name.pid
    fi
    echo "$name 已停止"
    ;;
restart)
    "\$0" stop; sleep 1; "\$0" start
    ;;
status)
    if [ -f /run/$name.pid ] && kill -0 "\$(cat /run/$name.pid)" 2>/dev/null; then
        echo "$name running (pid \$(cat /run/$name.pid))"
    else
        echo "$name stopped"
    fi
    ;;
*)
    echo "用法: \$0 {start|stop|restart|status}"
    ;;
esac
EOF
    chmod 755 "/usr/local/bin/$name-ctl"
    # 重装也要生效：用 restart 而不是 start（否则旧进程还活着会直接跳过，新配置不生效）
    "/usr/local/bin/$name-ctl" restart
}

svc_restart() { # $1=systemd单元名 $2=openrc服务名
    case "$ENV_INIT" in
    systemd) systemctl restart "$1" >/dev/null 2>&1 ;;
    openrc)  rc-service "$2" restart >/dev/null 2>&1 ;;
    none)    "/usr/local/bin/$2-ctl" restart >/dev/null 2>&1 ;;
    esac
    return 0
}

svc_state() { # $1=systemd单元名 $2=openrc服务名
    local out
    case "$ENV_INIT" in
    systemd)
        out=$(systemctl is-active "$1" 2>/dev/null)
        echo "${out:-unknown}"
        ;;
    openrc)
        if rc-service "$2" status >/dev/null 2>&1; then echo "running (openrc)"; else echo "not running (openrc)"; fi
        ;;
    none)
        if [ -f "/run/$2.pid" ] && kill -0 "$(cat /run/$2.pid)" 2>/dev/null; then echo "running (nohup)"; else echo "not running (nohup)"; fi
        ;;
    *)
        echo "unknown"
        ;;
    esac
}

# 卸载：三种管理器都清一遍，避免换过 init 的系统残留
svc_remove() { # $1=systemd单元名 $2=openrc服务名
    if has systemctl; then
        systemctl stop "$1" >/dev/null 2>&1
        systemctl disable "$1" >/dev/null 2>&1
    fi
    rm -f "/etc/systemd/system/$1.service"
    has systemctl && systemctl daemon-reload >/dev/null 2>&1
    has rc-service && rc-service "$2" stop >/dev/null 2>&1
    has rc-update && rc-update del "$2" default >/dev/null 2>&1
    rm -f "/etc/init.d/$2"
    [ -x "/usr/local/bin/$2-ctl" ] && "/usr/local/bin/$2-ctl" stop >/dev/null 2>&1
    rm -f "/usr/local/bin/$2-ctl" "/usr/local/bin/$2-run" "/run/$2.pid"
    return 0
}

# ============================================================================
# 隧道自测：多目标 + 分级（把"代理坏了"和"本机连不上测试目标"分开）
# ============================================================================
proxy_probe() { # $1=socks5端口；输出出口IP（?=只证明隧道通了），返回 0=通
    local p=$1 out
    [ -z "$p" ] && return 1
    has curl || return 2
    out=$(curl -s --max-time 12 --socks5-hostname "127.0.0.1:$p" https://api.ipify.org 2>/dev/null | tr -d '[:space:]')
    case "$out" in
        ""|*[!0-9a-fA-F:.]*) ;;
        *) printf '%s' "$out"; return 0 ;;
    esac
    out=$(curl -s --max-time 12 --socks5-hostname "127.0.0.1:$p" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' | head -1)
    if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
    if curl -s --max-time 12 --socks5-hostname "127.0.0.1:$p" -o /dev/null https://www.gstatic.com/generate_204 2>/dev/null; then
        printf '?'
        return 0
    fi
    return 1
}

selftest_skip_no_curl() {
    echo -e "${yellow}跳过隧道自测：本机没有 curl，服务已启动，请用客户端连接验证${re}"
}

# --- Reality 公共组件（Alpine / systemd 用同一套：官方 Xray + 统一配置 + 服务单元） ---
XRAY_BIN="/usr/local/bin/xray"
XRAY_CFG_DIR="/usr/local/etc/xray"
XRAY_CFG="$XRAY_CFG_DIR/config.json"
XRAY_LINK="$XRAY_CFG_DIR/link.txt"

# 架构 -> 官方 release 资产名
xray_asset() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "Xray-linux-64.zip" ;;
        aarch64|arm64)  echo "Xray-linux-arm64-v8a.zip" ;;
        armv7l)         echo "Xray-linux-arm32-v7a.zip" ;;
        i686|i386)      echo "Xray-linux-32.zip" ;;
        *)              return 1 ;;
    esac
}

# 公网 IP：IPv4 -> IPv6(自动加方括号) -> 网卡。busybox 兼容，不用 grep -oP
get_public_ip() {
    local ip=""
    ip=$(curl -s --max-time 5 https://ipv4.ip.sb 2>/dev/null | tr -d '[:space:]')
    printf '%s' "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || ip=""
    if [ -z "$ip" ]; then
        ip=$(curl -s --max-time 5 https://ipv6.ip.sb 2>/dev/null | tr -d '[:space:]')
        case "$ip" in
            *:*) ip="[$ip]" ;;
            *)   ip="" ;;
        esac
    fi
    if [ -z "$ip" ]; then
        ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1);exit}}')
    fi
    if [ -z "$ip" ]; then
        ip=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1);exit}}')
        case "$ip" in *:*) ip="[$ip]" ;; *) ip="" ;; esac
    fi
    if [ -z "$ip" ]; then
        ip=$(ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127\.' | head -1)
    fi
    printf '%s' "$ip"
}

# 节点显示名（取不到就给个占位，绝不输出空标签）
get_isp_name() {
    local meta txt=""
    meta=$(curl -s --max-time 6 https://speed.cloudflare.com/meta 2>/dev/null)
    if [ -n "$meta" ] && command -v jq >/dev/null 2>&1; then
        txt=$(printf '%s' "$meta" | jq -r '((.country // "") + "-" + (.asOrganization // ""))' 2>/dev/null)
    fi
    case "$txt" in ""|"-"|"null-null") txt="" ;; esac
    if [ -z "$txt" ]; then
        txt=$(printf '%s' "$meta" | tr ',' '\n' | awk -F'"' '/country/{c=$4} /asOrganization/{i=$4} END{if(c!=""||i!="")print c"-"i}')
    fi
    [ -z "$txt" ] && txt="node"
    printf '%s' "$txt" | tr ' ' '_' | tr -d '"'
}

# 安装官方静态 Xray（Go 静态构建，musl 上可直接运行）
install_xray_core() {
    install_soft curl
    install_soft unzip
    if [ -x "$XRAY_BIN" ]; then
        echo -e "${green}已存在 Xray：$("$XRAY_BIN" version 2>/dev/null | head -1)${re}"
        return 0
    fi
    local asset tmp
    if ! asset=$(xray_asset); then
        echo -e "${red}错误: 当前架构 $(uname -m) 没有官方 Xray 构建${re}"
        return 1
    fi
    tmp=$(mktemp -d) || return 1
    echo -e "${yellow}正在下载官方 Xray ($asset)...${re}"
    if ! download_official "https://github.com/XTLS/Xray-core/releases/latest/download/$asset" "XTLS/Xray-core" "$asset" "$tmp/xray.zip"; then
        echo -e "${red}错误: 下载 Xray 失败，请检查网络${re}"
        rm -rf "$tmp"; return 1
    fi
    if ! unzip -oq "$tmp/xray.zip" -d "$tmp"; then
        echo -e "${red}错误: 解压失败（需要 unzip，可手动安装后重试）${re}"
        rm -rf "$tmp"; return 1
    fi
    mkdir -p "$XRAY_CFG_DIR"
    install -m 755 "$tmp/xray" "$XRAY_BIN" || { rm -rf "$tmp"; return 1; }
    # 不装 geoip.dat / geosite.dat：本脚本的配置不用 geo* 路由规则，省 ~30MB 磁盘（小机器很关键）
    rm -rf "$tmp"
    if ! "$XRAY_BIN" version >/dev/null 2>&1; then
        echo -e "${red}错误: Xray 二进制无法在本机运行${re}"
        return 1
    fi
    echo -e "${green}已安装 $("$XRAY_BIN" version | head -1)${re}"
    return 0
}

# 取 x25519 密钥：按标签取值，绝不按行号（新版本第三行是 Hash32）
reality_keys() {
    local out
    out=$("$XRAY_BIN" x25519 2>/dev/null)
    RE_PRIV=$(printf '%s\n' "$out" | grep -i 'private' | head -1 | awk '{print $NF}')
    RE_PUB=$(printf '%s\n' "$out" | grep -i 'public'  | head -1 | awk '{print $NF}')
    if [ ${#RE_PRIV} -lt 40 ] || [ ${#RE_PUB} -lt 40 ]; then
        echo -e "${red}错误: 解析 x25519 密钥失败${re}"
        echo -e "${yellow}原始输出: $out${re}"
        return 1
    fi
    return 0
}

# 写配置：dest 必须写 SNI 主机名本身（写死 IP 会让连不上该 IP 的机器整台失效）
reality_write_config() {
    local port=$1 sni=$2 uuid=$3 priv=$4 sid=$5
    mkdir -p "$XRAY_CFG_DIR"
    cat > "$XRAY_CFG" <<EOF
{
    "inbounds": [
        {
            "port": $port,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$uuid",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "$sni:443",
                    "xver": 0,
                    "serverNames": [
                        "$sni"
                    ],
                    "privateKey": "$priv",
                    "minClientVer": "",
                    "maxClientVer": "",
                    "maxTimeDiff": 0,
                    "shortIds": [
                        "$sid"
                    ]
                }
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "blocked"
        }
    ]
}
EOF
    if ! "$XRAY_BIN" -test -c "$XRAY_CFG" >/tmp/xray-test.log 2>&1; then
        echo -e "${red}错误: 配置校验失败：$(tail -1 /tmp/xray-test.log)${re}"
        return 1
    fi
    return 0
}

# 由现有配置反推客户端链接（私钥 -> 公钥用官方 x25519 -i）
reality_build_link() {
    local port sni priv sid uuid host isp pub
    [ -f "$XRAY_CFG" ] || return 1
    command -v jq >/dev/null 2>&1 || install_soft jq
    port=$(jq -r '.inbounds[0].port' "$XRAY_CFG" 2>/dev/null)
    sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CFG" 2>/dev/null)
    priv=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$XRAY_CFG" 2>/dev/null)
    sid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CFG" 2>/dev/null)
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CFG" 2>/dev/null)
    pub=$("$XRAY_BIN" x25519 -i "$priv" 2>/dev/null | grep -i 'public' | head -1 | awk '{print $NF}')
    host=$(get_public_ip)
    isp=$(get_isp_name)
    case "$port" in ""|"null"|*[!0-9]*) return 1 ;; esac
    [ -z "$host" ] && return 1
    [ -z "$pub" ] && return 1
    [ -z "$sid" ] || [ "$sid" = "null" ] && sid=""
    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s' \
        "$uuid" "$host" "$port" "$sni" "$pub" "$sid" "$isp"
    return 0
}

# 装机自测：本机起一个客户端，从隧道里出去，验证 dest/SNI 真的可用
reality_selftest() {
    local port=$1 sni=$2 uuid=$3 pub=$4 sid=$5 tport=1081 out rc
    while check_port "$tport" && [ "$tport" -lt 1090 ]; do tport=$((tport+1)); done
    cat > /tmp/reality-selftest.json <<EOF
{
    "inbounds": [
        {
            "port": $tport,
            "listen": "127.0.0.1",
            "protocol": "socks",
            "settings": { "udp": false }
        }
    ],
    "outbounds": [
        {
            "protocol": "vless",
            "settings": {
                "vnext": [
                    {
                        "address": "127.0.0.1",
                        "port": $port,
                        "users": [
                            { "id": "$uuid", "encryption": "none", "flow": "xtls-rprx-vision" }
                        ]
                    }
                ]
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "serverName": "$sni",
                    "fingerprint": "chrome",
                    "publicKey": "$pub",
                    "shortId": "$sid",
                    "spiderX": "/",
                    "show": false
                }
            }
        }
    ]
}
EOF
    local before after
    before=$(wc -l < /var/log/xray/access.log 2>/dev/null | tr -d ' ')
    [ -z "$before" ] && before=0
    nohup "$XRAY_BIN" -c /tmp/reality-selftest.json >/tmp/reality-selftest.log 2>&1 &
    local tpid=$!
    sleep 3
    out=$(proxy_probe "$tport")
    rc=$?
    kill "$tpid" >/dev/null 2>&1
    rm -f /tmp/reality-selftest.json
    if [ $rc -eq 0 ]; then
        case "$out" in
            "?") echo -e "${green}自测通过：隧道能出网（测试目标返回 204）${re}" ;;
            *)   echo -e "${green}自测通过：隧道出口 IP $out${re}" ;;
        esac
        return 0
    fi
    if [ $rc -eq 2 ]; then selftest_skip_no_curl; return 0; fi
    after=$(wc -l < /var/log/xray/access.log 2>/dev/null | tr -d ' ')
    [ -z "$after" ] && after=0
    if [ "$after" -gt "$before" ]; then
        echo -e "${yellow}自测结果不确定：隧道握手是成功的（服务端已记录连接），但外网测试目标都没连上${re}"
        echo -e "${yellow}这通常是本机出网受限，不是节点的问题。请用客户端实际连一次确认。${re}"
        return 0
    fi
    echo -e "${red}自测失败：本机连不通自己的 Reality 节点${re}"
    echo -e "${yellow}最常见原因：伪装域名 $sni 或它的 443 端口在这台机器上不可达，或者它不支持 REALITY 需要的 TLS1.3+X25519。${re}"
    echo -e "${yellow}已知可用的备选：www.cloudflare.com / www.apple.com / www.yahoo.com${re}"
    echo -e "${yellow}换一个重装即可（菜单 2 -> 1），不用卸载。${re}"
    [ -s /var/log/xray/error.log ] && { echo -e "${yellow}服务端日志:${re}"; tail -3 /var/log/xray/error.log; }
    [ -s /tmp/reality-selftest.log ] && { echo -e "${yellow}客户端日志:${re}"; tail -3 /tmp/reality-selftest.log; }
    return 1
}

# 安装/覆盖服务单元并启动：systemd / openrc / 无 init 三档（见 svc_install）
install_reality_service() {
    svc_install "xray" "xray" "Xray (VLESS Reality)" \
        "$XRAY_BIN run -config $XRAY_CFG" "/var/log/xray" "https://github.com/XTLS"
}

restart_reality() {
    svc_restart "xray" "xray"
}

# 一键安装 Reality（Alpine 与非 Alpine 走同一条路）
install_reality() {
    local port=$1 sni=$2 uuid sid host isp link need
    install_soft curl
    install_soft jq
    ensure_netstat

    env_detect
    echo -e "$(env_line)"
    if [ -x "$XRAY_BIN" ]; then need=15; else need=60; fi
    if ! env_precheck "$need" "Reality"; then
        press_any_key_to_continue
        return 1
    fi
    kernel_tune

    echo -e "${green}Reality 正在安装中，请稍候...${re}"

    install_xray_core || return 1
    reality_keys  || return 1

    uuid=$("$XRAY_BIN" uuid 2>/dev/null)
    [ -z "$uuid" ] && uuid=$(rand_uuid)
    sid=$(rand_token)

    reality_write_config "$port" "$sni" "$uuid" "$RE_PRIV" "$sid" || return 1
    install_reality_service
    sleep 2

    host=$(get_public_ip)
    isp=$(get_isp_name)
    link="vless://$uuid@$host:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=chrome&pbk=$RE_PUB&sid=$sid&type=tcp&headerType=none#$isp"
    printf '%s\n' "$link" > "$XRAY_LINK"

    echo ""
    echo -e "${green}Reality 安装成功！${re}"
    echo -e "${green}服务状态: $(reality_service_state)${re}"
    if [ -z "$host" ]; then
        echo -e "${red}警告: 探测不到公网 IP（本机可能是内网/NAT 环境）${re}"
        echo -e "${yellow}请把下面链接里的主机名手动改成你的公网地址再导入客户端。${re}"
    fi
    echo -e "${white}V2rayN、NekoBox 客户端配置链接: ${re}"
    echo -e "${skyblue}$link${re}"
    echo ""
    reality_selftest "$port" "$sni" "$uuid" "$RE_PUB" "$sid"
    echo ""
    press_any_key_to_continue
}

reality_service_state() {
    svc_state "xray" "xray"
}

# --- 新增功能：配置 Alpine 开机自启 ---
setup_alpine_autorun() {
    if [ -f "/etc/alpine-release" ]; then
        echo -e "${yellow}正在配置 Alpine 开机自启 (OpenRC)...${re}"
        
        # 确保 local 服务被添加到启动项
        if command -v rc-update &> /dev/null; then
            rc-update add local default >/dev/null 2>&1
        fi

        # 创建或覆盖自启脚本
        cat > /etc/local.d/proxy_autorun.start <<EOF
#!/bin/sh

# Hysteria2 自启检测（仅兼容旧版 eooce 容器脚本安装；新版由 /etc/init.d/hysteria 服务单元负责）
if [ -f "/root/web" ] && [ -f "/root/config.yaml" ] && [ ! -x /usr/local/bin/hysteria ]; then
    cd /root
    nohup ./web server config.yaml >/dev/null 2>&1 &
fi

# Reality 自启检测（仅兼容旧版 eooce/test.sh 安装；新版由 /etc/init.d/xray 服务单元负责）
if [ -f "/root/app/web" ] && [ -f "/root/app/config.json" ] && [ ! -x /usr/local/bin/xray ]; then
    cd /root
    nohup ./app/web -c ./app/config.json >/dev/null 2>&1 &
fi

# Tuic-V5 自启检测（仅兼容旧版 /root/tuic 安装；新版由 /etc/init.d/tuic 服务单元负责）
if [ -f "/root/tuic/tuic-server" ] && [ -f "/root/tuic/config.json" ] && [ ! -x /usr/local/bin/tuic-server ]; then
    cd /root/tuic
    nohup ./tuic-server -c config.json >/dev/null 2>&1 &
fi
EOF
        
        # 赋予执行权限
        chmod +x /etc/local.d/proxy_autorun.start
        echo -e "${green}Alpine 开机自启配置完成！${re}"
    fi
}

# --- Hysteria2 公共组件（官方 apernet/hysteria + 统一配置 + 服务单元） ---
HY_BIN="/usr/local/bin/hysteria"
HY_DIR="/etc/hysteria"
HY_CFG="$HY_DIR/config.yaml"
HY_SHARE="$HY_DIR/client.yaml"
HY_LINK="$HY_DIR/link.txt"

hy_asset() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "hysteria-linux-amd64" ;;
        aarch64|arm64)  echo "hysteria-linux-arm64" ;;
        armv7l|armv6l)  echo "hysteria-linux-arm" ;;
        i686|i386)      echo "hysteria-linux-386" ;;
        *)              return 1 ;;
    esac
}

hy_version() {
    "$HY_BIN" version 2>/dev/null | sed -n 's/^Version:[[:space:]]*//p' | head -1
}

install_hysteria_core() {
    install_soft curl
    if [ -x "$HY_BIN" ]; then
        echo -e "${green}已存在 Hysteria $(hy_version)${re}"
        return 0
    fi
    local asset tmp
    if ! asset=$(hy_asset); then
        echo -e "${red}错误: 当前架构 $(uname -m) 没有官方 Hysteria 构建${re}"
        return 1
    fi
    tmp=$(mktemp -d) || return 1
    echo -e "${yellow}正在下载官方 Hysteria ($asset)...${re}"
    if ! download_official "https://github.com/apernet/hysteria/releases/latest/download/$asset" "apernet/hysteria" "$asset" "$tmp/hysteria"; then
        echo -e "${red}错误: 下载 Hysteria 失败，请检查网络${re}"
        rm -rf "$tmp"; return 1
    fi
    install -m 755 "$tmp/hysteria" "$HY_BIN" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    if ! "$HY_BIN" version >/dev/null 2>&1; then
        echo -e "${red}错误: Hysteria 二进制无法在本机运行${re}"
        return 1
    fi
    echo -e "${green}已安装 Hysteria $(hy_version)${re}"
    return 0
}

hy_write_config() {
    local port=$1 pass=$2
    mkdir -p "$HY_DIR"
    cat > "$HY_CFG" <<EOF
listen: :$port

tls:
  cert: $HY_DIR/server.crt
  key: $HY_DIR/server.key

auth:
  type: password
  password: "$pass"

fastOpen: true

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true

transport:
  udp:
    hopInterval: 30s
EOF
    if [ "$ENV_LOWMEM" = 1 ]; then
        # 低内存档：收紧 QUIC 窗口，限制最坏情况下每连接的缓冲上限
        cat >> "$HY_CFG" <<'EOF'

quic:
  initStreamReceiveWindow: 1048576
  maxStreamReceiveWindow: 2097152
  initConnReceiveWindow: 2097152
  maxConnReceiveWindow: 4194304
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s
  maxIncomingStreams: 128
EOF
    fi
    [ -s "$HY_CFG" ] || return 1
    return 0
}

# 链接优先用官方 `hysteria share` 生成，失败才回退成等价手写格式
hy_build_link() {
    local port=$1 pass=$2 host isp link
    host=$(get_public_ip)
    [ -z "$host" ] && return 1
    isp=$(get_isp_name)
    mkdir -p "$HY_DIR"
    cat > "$HY_SHARE" <<EOF
server: ${host}:$port
auth: "$pass"
tls:
  sni: www.bing.com
  insecure: true
socks5:
  listen: 127.0.0.1:1081
EOF
    link=$("$HY_BIN" share -c "$HY_SHARE" 2>/dev/null | grep -m1 '^hysteria2://')
    if [ -z "$link" ]; then
        link="hysteria2://$pass@$host:$port/?sni=www.bing.com&alpn=h3&insecure=1"
    fi
    printf '%s#%s' "$link" "$isp"
    return 0
}

hy_selftest() {
    local port=$1 pass=$2 cport=1081 out rc pid
    if ! has curl; then selftest_skip_no_curl; return 0; fi
    while check_port "$cport" && [ "$cport" -lt 1090 ]; do cport=$((cport+1)); done
    cat > /tmp/hysteria-selftest.yaml <<EOF
server: 127.0.0.1:$port
auth: "$pass"
tls:
  sni: www.bing.com
  insecure: true
socks5:
  listen: 127.0.0.1:$cport
EOF
    nohup "$HY_BIN" client -c /tmp/hysteria-selftest.yaml >/tmp/hysteria-selftest.log 2>&1 &
    pid=$!
    sleep 3
    out=$(proxy_probe "$cport")
    rc=$?
    kill "$pid" >/dev/null 2>&1
    rm -f /tmp/hysteria-selftest.yaml
    if [ $rc -eq 0 ]; then
        case "$out" in
            "?") echo -e "${green}自测通过：隧道能出网（测试目标返回 204）${re}" ;;
            *)   echo -e "${green}自测通过：隧道出口 IP $out${re}" ;;
        esac
        return 0
    fi
    # 客户端已经和服务器握手成功，只是测试目标连不上 -> 不算节点故障
    if grep -qi "connected to server" /tmp/hysteria-selftest.log 2>/dev/null; then
        echo -e "${yellow}自测结果不确定：客户端已成功连上服务端（connected to server），但外网测试目标都没连上${re}"
        echo -e "${yellow}这通常是本机出网受限，不是节点的问题。请用客户端实际连一次确认。${re}"
        return 0
    fi
    echo -e "${red}自测失败：本机连不通自己的 Hysteria2 服务${re}"
    if grep -qiE "authentication failed|invalid auth" /tmp/hysteria-selftest.log 2>/dev/null; then
        echo -e "${yellow}原因: 认证被拒（密码不一致？）${re}"
    fi
    echo -e "${yellow}常见原因：端口没放行 / UDP 不通 / 服务没起来（当前状态: $(hy_service_state)）${re}"
    [ -s /var/log/hysteria/error.log ] && { echo -e "${yellow}服务端日志:${re}"; tail -3 /var/log/hysteria/error.log; }
    [ -s /tmp/hysteria-selftest.log ] && { echo -e "${yellow}客户端日志:${re}"; tail -3 /tmp/hysteria-selftest.log; }
    return 1
}

install_hysteria_service() {
    svc_install "hysteria-server" "hysteria" "Hysteria2 Server Service" \
        "$HY_BIN server -c $HY_CFG" "/var/log/hysteria" "https://v2.hysteria.network"
}

restart_hysteria() {
    svc_restart "hysteria-server" "hysteria"
}

hy_service_state() {
    svc_state "hysteria-server" "hysteria"
}

install_hysteria() {
    local port=$1 pass host isp link cert_out need
    install_soft curl
    ensure_netstat

    env_detect
    echo -e "$(env_line)"
    if [ -x "$HY_BIN" ]; then need=25; else need=50; fi
    if ! env_precheck "$need" "Hysteria2"; then
        press_any_key_to_continue
        return 1
    fi
    kernel_tune

    echo -e "${green}Hysteria2 正在安装中，请稍候...${re}"

    install_hysteria_core || return 1

    pass=$(rand_uuid)

    mkdir -p "$HY_DIR"
    echo -e "${yellow}正在生成自签证书...${re}"
    cert_out=$("$HY_BIN" cert --host www.bing.com --cert "$HY_DIR/server.crt" --key "$HY_DIR/server.key" --valid-for 87600h --overwrite 2>&1)
    if [ ! -s "$HY_DIR/server.crt" ] || [ ! -s "$HY_DIR/server.key" ]; then
        echo -e "${red}错误: 证书生成失败${re}"
        echo -e "${yellow}$cert_out${re}"
        return 1
    fi
    chmod 600 "$HY_DIR/server.key"

    hy_write_config "$port" "$pass" || return 1
    install_hysteria_service
    sleep 2

    host=$(get_public_ip)
    isp=$(get_isp_name)
    link=$(hy_build_link "$port" "$pass")
    if [ -z "$link" ]; then
        link="hysteria2://$pass@$host:$port/?sni=www.bing.com&alpn=h3&insecure=1#$isp"
    fi
    printf '%s\n' "$link" > "$HY_LINK"

    echo ""
    echo -e "${green}Hysteria2 安装成功！${re}"
    echo -e "${green}服务状态: $(hy_service_state)${re}"
    if [ -z "$host" ]; then
        echo -e "${red}警告: 探测不到公网 IP（本机可能是内网/NAT 环境）${re}"
        echo -e "${yellow}请把下面链接里的主机名手动改成你的公网地址再导入客户端。${re}"
    fi
    echo -e "${white}V2rayN、NekoBox 客户端配置链接: ${re}"
    echo -e "${skyblue}$link${re}"
    echo ""
    hy_selftest "$port" "$pass"
    echo ""
    press_any_key_to_continue
}

# --- Tuic-V5 公共组件（官方 EAimTY/tuic + 统一配置 + 服务单元） ---
TU_BIN="/usr/local/bin/tuic-server"
TU_DIR="/etc/tuic"
TU_CFG="$TU_DIR/config.json"
TU_LINK="$TU_DIR/link.txt"

tuic_arch_candidates() {
    local musl=0
    [ -f "/etc/alpine-release" ] && musl=1
    case "$(uname -m)" in
        x86_64|amd64)
            if [ $musl -eq 1 ]; then echo "x86_64-unknown-linux-musl"; echo "x86_64-unknown-linux-gnu"; else echo "x86_64-unknown-linux-gnu"; fi ;;
        aarch64|arm64)
            if [ $musl -eq 1 ]; then echo "aarch64-unknown-linux-musl"; echo "aarch64-unknown-linux-gnu"; else echo "aarch64-unknown-linux-gnu"; fi ;;
        armv7l)
            if [ $musl -eq 1 ]; then echo "armv7-unknown-linux-musleabihf"; echo "armv7-unknown-linux-musleabi"; else echo "armv7-unknown-linux-gnueabihf"; echo "armv7-unknown-linux-gnueabi"; fi ;;
        i686|i386)
            if [ $musl -eq 1 ]; then echo "i686-unknown-linux-musl"; echo "i686-unknown-linux-gnu"; else echo "i686-unknown-linux-gnu"; fi ;;
        *)  return 1 ;;
    esac
}

install_tuic_core() {
    install_soft curl
    if [ -x "$TU_BIN" ]; then
        echo -e "${green}已存在 Tuic ($("$TU_BIN" -v 2>/dev/null | head -1))${re}"
        return 0
    fi
    local ver tmp arch ok=0
    ver=$(http_get "https://api.github.com/repos/EAimTY/tuic/releases/latest" 20 2>/dev/null | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    [ -z "$ver" ] && ver="tuic-server-1.0.0"
    tmp=$(mktemp -d) || return 1
    for arch in $(tuic_arch_candidates); do
        echo -e "${yellow}正在下载官方 Tuic ($ver-$arch)...${re}"
        if download_official "https://github.com/EAimTY/tuic/releases/download/$ver/$ver-$arch" "EAimTY/tuic" "$ver-$arch" "$tmp/tuic-server"; then
            chmod 755 "$tmp/tuic-server"
            if "$tmp/tuic-server" -v >/dev/null 2>&1; then
                ok=1
                break
            fi
            echo -e "${yellow}这个架构的构建在本机跑不起来，试下一个候选${re}"
        fi
    done
    if [ $ok -ne 1 ]; then
        echo -e "${red}错误: 没有适合本机的官方 Tuic 构建${re}"
        rm -rf "$tmp"
        return 1
    fi
    install -m 755 "$tmp/tuic-server" "$TU_BIN" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    echo -e "${green}已安装 Tuic ($("$TU_BIN" -v 2>/dev/null | head -1))${re}"
    return 0
}

tuic_write_config() {
    local port=$1 uuid=$2 pass=$3
    mkdir -p "$TU_DIR"
    cat > "$TU_CFG" <<EOL
{
  "server": "[::]:$port",
  "users": {
    "$uuid": "$pass"
  },
  "certificate": "$TU_DIR/server.crt",
  "private_key": "$TU_DIR/server.key",
  "congestion_control": "bbr",
  "alpn": ["h3", "spdy/3.1"],
  "udp_relay_ipv6": true,
  "zero_rtt_handshake": false,
  "dual_stack": true,
  "auth_timeout": "3s",
  "task_negotiation_timeout": "3s",
  "max_idle_time": "10s",
  "max_external_packet_size": 1500,
  "gc_interval": "3s",
  "gc_lifetime": "15s",
  "log_level": "warn"
}
EOL
    install_soft jq
    if command -v jq >/dev/null 2>&1; then
        jq empty "$TU_CFG" >/dev/null 2>&1 || { echo -e "${red}错误: Tuic 配置不是合法 JSON${re}"; return 1; }
    fi
    return 0
}

tuic_build_link() {
    local uuid=$1 pass=$2 host isp link
    host=$(get_public_ip)
    [ -z "$host" ] && return 1
    isp=$(get_isp_name)
    printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&alpn=h3&sni=www.bing.com&udp_relay_mode=native&allow_insecure=1#%s' \
        "$uuid" "$pass" "$host" "$3" "$isp"
    return 0
}

tuic_health_check() {
    local port=$1 state
    state=$(tuic_service_state)
    # 判据用"端口在监听"（netstat/ss/内核表三级回退），不看 ps——容器里可能根本没有 procps
    if port_listening "$port"; then
        echo -e "${green}自测通过：UDP 端口 $port 已在监听（服务状态: $state）${re}"
        return 0
    fi
    echo -e "${red}自测失败：UDP 端口 $port 没有在监听（服务状态: $state）${re}"
    [ -s /var/log/tuic/error.log ] && { echo -e "${yellow}服务日志:${re}"; tail -3 /var/log/tuic/error.log; }
    [ -s "$TU_DIR/tuic.log" ] && { echo -e "${yellow}服务日志(旧):${re}"; tail -3 "$TU_DIR/tuic.log"; }
    return 1
}

install_tuic_service() {
    svc_install "tuic" "tuic" "Tuic v5 server" \
        "$TU_BIN -c $TU_CFG" "/var/log/tuic" "https://github.com/EAimTY/tuic"
}

restart_tuic() {
    svc_restart "tuic" "tuic"
}

tuic_service_state() {
    svc_state "tuic" "tuic"
}

# --- Tuic-V5 功能实现 ---

install_tuic() {
    cd ~ || exit 1

    install_soft jq
    install_soft curl
    install_soft openssl
    ensure_netstat

    env_detect
    echo -e "$(env_line)"
    if [ -x "$TU_BIN" ]; then need=10; else need=15; fi
    env_precheck "$need" "Tuic" || { press_any_key_to_continue; return; }
    kernel_tune

    echo -e "${green}Tuic V5 正在安装中，请稍候...${re}"

    install_tuic_core || { press_any_key_to_continue; return; }

    mkdir -p "$TU_DIR"
    echo -e "${yellow}正在生成自签证书...${re}"
    if ! make_selfsigned_cert "$TU_DIR/server.crt" "$TU_DIR/server.key"; then
        echo -e "${red}错误: 证书生成失败${re}"
        echo -e "${yellow}需要 openssl；如果本机装过 Hysteria2，它会优先用官方 hysteria cert 命令${re}"
        press_any_key_to_continue
        return
    fi
    chmod 600 "$TU_DIR/server.key"

    echo ""
    local port
    read -p $'\033[1;35m请输入 Tuic 端口 (10000-65000, 回车使用随机端口): \033[0m' port
    [ -z "$port" ] && port=$(rand_port)

    while check_port "$port"; do
        echo -e "${red}端口 ${port} 已被占用，请更换端口重试！${re}"
        read -p $'\033[1;35m请输入 Tuic 端口 (10000-65000, 回车使用随机端口): \033[0m' port
        [ -z "$port" ] && port=$(rand_port)
    done
    echo -e "${green}Tuic 端口: ${port}${re}"

    local password
    read -p $'\033[1;35m请输入您想设定的密码 (回车使用随机密码): \033[0m' password
    [ -z "$password" ] && password=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 8 | head -n 1)
    echo -e "${green}Tuic 密码: ${password}${re}"

    UUID=$(openssl rand -hex 16 | awk '{print substr($0,1,8)"-"substr($0,9,4)"-"substr($0,13,4)"-"substr($0,17,4)"-"substr($0,21,12)}')
    echo -e "${green}Tuic UUID: ${UUID}${re}"
    if [ -z "$UUID" ]; then
        echo -e "${red}错误: 生成 UUID 失败！${re}"
        cd ~
        press_any_key_to_continue
        return
    fi

    tuic_write_config "$port" "$UUID" "$password" || { press_any_key_to_continue; return; }
    install_tuic_service
    sleep 2

    local link
    link=$(tuic_build_link "$UUID" "$password" "$port")
    if [ -n "$link" ]; then
        printf '%s\n' "$link" > "$TU_LINK"
    else
        echo -e "${red}警告: 探测不到公网 IP，请手工把链接里的主机名换成你的公网地址${re}"
    fi

    echo ""
    echo -e "${green}Tuic V5 安装成功！${re}"
    echo -e "${green}服务状态: $(tuic_service_state)${re}"
    echo -e "${white}V2rayN、NekoBox 客户端配置链接: ${re}"
    echo -e "${skyblue}$link${re}"
    echo ""
    tuic_health_check "$port"
    echo ""
    cd ~
    press_any_key_to_continue
}

change_tuic_config() {
    cd ~ || exit 1
    install_soft jq
    ensure_netstat

    echo -e "${yellow}正在更改 Tuic 配置...${re}"

    local config_file="$TU_CFG"
    if [ ! -f "$config_file" ]; then
        echo -e "${red}错误: Tuic 配置文件 $config_file 不存在，请先安装 Tuic.${re}"
        press_any_key_to_continue
        return
    fi

    # 获取当前UUID和密码
    local current_uuid=$(jq -r '.users | to_entries[0].key' "$config_file" 2>/dev/null)
    local current_password=$(jq -r ".users[\"$current_uuid\"]" "$config_file" 2>/dev/null)
    local current_port=$(jq -r '.server' "$config_file" | awk -F":" '{print $NF}' | tr -d '"')

    # 更改 UUID
    local new_uuid
    read -p $'\033[1;35m请输入新的 UUID (或回车使用随机 UUID，当前: '$current_uuid'): \033[0m' new_uuid
    [ -z "$new_uuid" ] && new_uuid=$(openssl rand -hex 16 | awk '{print substr($0,1,8)"-"substr($0,9,4)"-"substr($0,13,4)"-"substr($0,17,4)"-"substr($0,21,12)}')

    jq --arg old_uuid "$current_uuid" --arg new_uuid "$new_uuid" --arg password "$current_password" \
        '.users = { ($new_uuid): $password }' "$config_file" > /tmp/tuic-tmp.json && mv /tmp/tuic-tmp.json "$config_file"
    echo -e "${green}新的 UUID: $new_uuid${re}"

    # 更改端口
    local new_port
    read -p $'\033[1;35m请输入新的端口 (或回车使用随机端口，当前: '$current_port'): \033[0m' new_port
    [ -z "$new_port" ] && new_port=$(rand_port)

    while check_port "$new_port"; do
        echo -e "${red}端口 ${new_port} 已被占用，请更换端口重试！${re}"
        read -p $'\033[1;35m请输入新的端口 (或回车使用随机端口): \033[0m' new_port
        [ -z "$new_port" ] && new_port=$(rand_port)
    done

    jq --argjson new_port "$new_port" '.server = ("[::]:" + ($new_port|tostring))' "$config_file" > /tmp/tuic-tmp.json && mv /tmp/tuic-tmp.json "$config_file"
    echo -e "${green}新的 PORT: $new_port${re}"

    restart_tuic
    sleep 2

    local link
    link=$(tuic_build_link "$new_uuid" "$current_password" "$new_port")
    if [ -n "$link" ]; then
        printf '%s\n' "$link" > "$TU_LINK"
        echo -e "${white}更新后的客户端链接: ${re}"
        echo -e "${skyblue}$link${re}"
    else
        echo -e "${yellow}链接重新生成失败（多半是探测不到公网 IP），请把客户端里的端口手动改成 $new_port${re}"
    fi
    tuic_health_check "$new_port"
    echo ""
    press_any_key_to_continue
}

uninstall_tuic() {
    cd ~ || exit 1
    echo -e "${yellow}正在卸载 Tuic V5...${re}"

    env_detect
    svc_remove "tuic" "tuic"

    # 新路径 + 旧版 /root/tuic 安装
    kill_by_cmdline "tuic-server"
    rm -f "$TU_BIN"
    rm -rf "$TU_DIR"
    rm -rf /var/log/tuic
    rm -rf /root/tuic
    rm -f /tmp/tuic-tmp.json

    echo -e "${green}Tuic V5 已卸载成功！${re}"
    press_any_key_to_continue
}

# --- Alpine 系统环境预处理 ---
if [ -f "/etc/alpine-release" ]; then
    if ! command -v bash &> /dev/null || ! command -v curl &> /dev/null || ! command -v unzip &> /dev/null; then
        echo -e "${yellow}检测到 Alpine 系统，正在安装基础依赖 (bash, curl, openssl, unzip, ca-certificates, openrc)...${re}"
        if command -v apk &> /dev/null; then
            apk add --no-cache bash curl openssl unzip ca-certificates openrc > /dev/null 2>&1
            echo -e "${green}基础依赖安装完成。${re}"
        else
            echo -e "${yellow}警告: 未找到 apk 包管理器，跳过依赖安装；缺什么请手动装（wget 也能下载，但隧道自测需要 curl）${re}"
        fi
    fi
fi

# --- 主菜单 ---
env_detect
while true; do
    cd ~ || exit 1
    clear
    echo -e "${purple}▶ 节点搭建脚本合集${re}"
    echo -e "${green}---------------------------------------------------------${re}"
    echo -e "${white} 1. Hysteria2一键脚本        2. Reality一键脚本${re}"
    echo -e "${white} 3. Tuic-V5一键脚本${re}"
    echo -e "${yellow}---------------------------------------------------------${re}"
    echo -e "$(env_line)"
    echo -e "${skyblue} 0. 退出脚本${re}"
    echo "---------------"
    read -p $'\033[1;91m请输入你的选择: \033[0m' main_choice
    case $main_choice in
        1) # Hysteria2 子菜单
            while true; do
                clear
                echo "--------------"
                echo -e "${green}1.安装Hysteria2${re}"
                echo -e "${red}2.卸载Hysteria2${re}"
                echo -e "${yellow}3.更换Hysteria2端口${re}"
                echo "--------------"
                echo -e "${skyblue}0. 返回上一级菜单${re}"
                echo "--------------"
                read -p $'\033[1;91m请输入你的选择: \033[0m' sub_choice
                case $sub_choice in
                    1) # 安装Hysteria2
                        clear
                        cd ~
                        ensure_netstat
                        read -p $'\033[1;35m请输入Hysteria2节点端口(nat小鸡请输入可用端口范围内的端口),回车跳过则使用随机端口：\033[0m' port
                        if [[ -z "$port" ]]; then
                            port=$(rand_port)
                            echo -e "${yellow}未输入端口，已为您分配随机端口: $port${re}"
                        fi

                        while check_port "$port"; do
                            echo -e "${red}${port}端口已经被其他程序占用，请更换端口重试${re}"
                            read -p $'\033[1;35m设置Hysteria2端口[1-65535]（回车将使用随机端口）：\033[0m' port
                            if [[ -z "$port" ]]; then
                                port=$(rand_port)
                                echo -e "${yellow}未输入端口，已为您分配随机端口: $port${re}"
                            fi
                        done

                        install_hysteria "$port"
                        break
                        ;;
                    2) # 卸载Hysteria2
                        cd ~
                        env_detect
                        svc_remove "hysteria-server" "hysteria"
                        rm -f "$HY_BIN"
                        rm -rf "$HY_DIR" /var/log/hysteria
                        rm -f /tmp/hysteria-selftest.yaml
                        # 清理旧版（eooce 容器脚本）在 /root 下留的文件，含那个来源不明的 npm
                        kill_by_cmdline "server config.yaml"
                        kill_by_cmdline "npm"
                        rm -rf /root/web /root/npm /root/server.crt /root/server.key /root/config.yaml
                        echo -e "${green}Hysteria2 已卸载${re}"
                        press_any_key_to_continue
                        break
                        ;;
                    3) # 更换Hysteria2端口
                        clear
                        cd ~
                        ensure_netstat
                        read -p $'\033[1;35m设置Hysteria2端口[1-65535]（回车跳过将使用随机端口）：\033[0m' new_port
                        [[ -z "$new_port" ]] && new_port=$(rand_port)

                        while check_port "$new_port"; do
                            echo -e "${red}${new_port}端口已经被其他程序占用，请更换端口重试${re}"
                            read -p $'\033[1;35m设置Hysteria2端口[1-65535]（回车跳过将使用随机端口）：\033[0m' new_port
                            [[ -z "$new_port" ]] && new_port=$(rand_port)
                        done

                        hy_pass=""
                        if [ -f "$HY_CFG" ]; then
                            hy_pass=$(sed -n 's/^[[:space:]]*password:[[:space:]]*"\(.*\)".*/\1/p' "$HY_CFG" | head -1)
                            sed -i "s/^listen: :[0-9]*/listen: :$new_port/" "$HY_CFG"
                            restart_hysteria
                            sleep 2
                            hy_link=$(hy_build_link "$new_port" "$hy_pass")
                            if [ -n "$hy_link" ]; then
                                printf '%s\n' "$hy_link" > "$HY_LINK"
                                echo -e "${white}更新后的客户端链接: ${re}"
                                echo -e "${skyblue}$hy_link${re}"
                            else
                                echo -e "${yellow}链接重新生成失败（多半是探测不到公网 IP），请把客户端里的端口手动改成 $new_port${re}"
                            fi
                            hy_selftest "$new_port" "$hy_pass"
                        elif [ -f "/root/config.yaml" ]; then
                            # 兼容旧版（eooce 容器脚本）安装
                            sed -i "s/^listen: :[0-9]*/listen: :$new_port/" /root/config.yaml
                            kill_by_cmdline "server config.yaml"
                            cd /root
                            nohup ./web server config.yaml >/dev/null 2>&1 &
                            setup_alpine_autorun # 更新自启
                            echo -e "${green}Hysteria2(旧版) 端口已更换成 $new_port，请手动更改客户端配置!${re}"
                        else
                            echo -e "${red}错误: 找不到 Hysteria2 配置文件，请先安装 Hysteria2。${re}"
                        fi
                        press_any_key_to_continue
                        break
                        ;;
                    0)
                        break
                        ;;
                    *)
                        echo -e "${red}无效的输入!${re}"
                        sleep 1
                        ;;
                esac
            done
            ;;
        2) # Reality 子菜单
            while true; do
                clear
                echo "--------------"
                echo -e "${green}1.安装Reality${re}"
                echo -e "${red}2.卸载Reality${re}"
                echo -e "${yellow}3.更换Reality端口${re}"
                echo "--------------"
                echo -e "${skyblue}0. 返回上一级菜单${re}"
                echo "--------------"
                read -p $'\033[1;91m请输入你的选择: \033[0m' sub_choice
                case $sub_choice in
                    1) # 安装Reality
                        clear
                        cd ~
                        ensure_netstat
                        read -p $'\033[1;35m请输入reality节点端口(nat小鸡请输入可用端口范围内的端口),回车跳过则使用随机端口：\033[0m' port
                        if [[ -z "$port" ]]; then
                            port=$(rand_port)
                            echo -e "${yellow}未输入端口，已为您分配随机端口: $port${re}"
                        fi

                        while check_port "$port"; do
                            echo -e "${red}${port}端口已经被其他程序占用，请更换端口重试${re}"
                            read -p $'\033[1;35m设置 reality 端口[1-65535]（回车跳过将使用随机端口）：\033[0m' port
                            if [[ -z "$port" ]]; then
                                port=$(rand_port)
                                echo -e "${yellow}未输入端口，已为您分配随机端口: $port${re}"
                            fi
                        done

                        echo ""
                        sni=""
                        sni_tries=0
                        while [ -z "$sni" ]; do
                            read -p $'\033[1;35m请输入伪装域名 SNI (回车默认 www.cloudflare.com): \033[0m' sni_input
                            [ -z "$sni_input" ] && sni_input="www.cloudflare.com"
                            if timeout 6 bash -c "exec 3<>/dev/tcp/$sni_input/443" 2>/dev/null; then
                                sni="$sni_input"
                            else
                                sni_tries=$((sni_tries + 1))
                                echo -e "${red}$sni_input:443 这台机器连不上！Reality 必须能连上伪装域名，否则整台节点都是死的${re}"
                                if [ "$sni_tries" -ge 3 ]; then
                                    sni="$sni_input"
                                    echo -e "${yellow}已重试 $sni_tries 次，按你的输入继续（装机自测会再兜一次底）${re}"
                                fi
                            fi
                        done
                        install_reality "$port" "$sni"
                        break
                        ;;
                    2) # 卸载Reality
                        cd ~
                        env_detect
                        svc_remove "xray" "xray"
                        # 兼容旧版 eooce/test.sh 安装（二进制伪装成 /root/app/web）
                        kill_by_cmdline "app/web"
                        rm -rf /root/app
                        # 两个平台都清掉官方 Xray 本体与配置
                        rm -f /usr/local/bin/xray
                        rm -rf /usr/local/etc/xray /usr/local/share/xray
                        rm -rf /var/log/xray /var/lib/xray
                        rm -f /tmp/reality-selftest.json /tmp/xray-test.log
                        echo -e "${green}Reality 已卸载${re}"
                        press_any_key_to_continue
                        break
                        ;;
                    3) # 更换Reality端口
                        clear
                        cd ~
                        install_soft jq
                        ensure_netstat
                        read -p $'\033[1;35m设置 reality 端口[1-65535]（回车跳过将使用随机端口）：\033[0m' new_port
                        [[ -z "$new_port" ]] && new_port=$(rand_port)

                        while check_port "$new_port"; do
                            echo -e "${red}${new_port}端口已经被其他程序占用，请更换端口重试${re}"
                            read -p $'\033[1;35m设置reality端口[1-65535]（回车跳过将使用随机端口）：\033[0m' new_port
                            [[ -z "$new_port" ]] && new_port=$(rand_port)
                        done

                        if [ -f "$XRAY_CFG" ]; then
                            # 新版：官方 Xray + 统一配置路径
                            jq --argjson new_port "$new_port" '.inbounds[0].port = $new_port' "$XRAY_CFG" > /tmp/xray-cfg.new && mv /tmp/xray-cfg.new "$XRAY_CFG"
                            if ! "$XRAY_BIN" -test -c "$XRAY_CFG" >/tmp/xray-test.log 2>&1; then
                                echo -e "${red}错误: 改端口后配置校验失败：$(tail -1 /tmp/xray-test.log)${re}"
                            fi
                            restart_reality
                            sleep 1
                            echo -e "${green}Reality 端口已更换成 $new_port${re}"
                            updated_link=$(reality_build_link)
                            if [ -n "$updated_link" ]; then
                                printf '%s\n' "$updated_link" > "$XRAY_LINK"
                                echo -e "${white}更新后的客户端链接: ${re}"
                                echo -e "${skyblue}$updated_link${re}"
                            else
                                echo -e "${yellow}链接重新生成失败（多半是探测不到公网 IP），请把客户端里的端口手动改成 $new_port${re}"
                            fi
                        elif [ -f "/root/app/config.json" ]; then
                            # 兼容旧版 eooce/test.sh 安装
                            jq --argjson new_port "$new_port" '.inbounds[0].port = $new_port' /root/app/config.json > /tmp/legacy-cfg.new && mv /tmp/legacy-cfg.new /root/app/config.json
                            kill_by_cmdline "app/web"
                            cd /root
                            nohup ./app/web -c ./app/config.json >/dev/null 2>&1 &
                            setup_alpine_autorun # 更新自启
                            echo -e "${green}Reality(旧版) 端口已更换成 $new_port，请手动更改客户端配置!${re}"
                        else
                            echo -e "${red}错误: 找不到 Reality 配置文件，请先安装 Reality。${re}"
                        fi
                        press_any_key_to_continue
                        break
                        ;;
                    0)
                        break
                        ;;
                    *)
                        echo -e "${red}无效的输入!${re}"
                        sleep 1
                        ;;
                esac
            done
            ;;
        3) # Tuic-V5 子菜单
            while true; do
                clear
                echo "--------------"
                echo -e "${green}1. 安装或重新安装 Tuic-V5${re}"
                echo -e "${yellow}2. 更改 Tuic-V5 配置 (UUID/端口)${re}"
                echo -e "${red}3. 卸载 Tuic-V5${re}"
                echo "--------------"
                echo -e "${skyblue}0. 返回上一级菜单${re}"
                echo "--------------"
                read -p $'\033[1;91m请输入你的选择: \033[0m' tuic_sub_choice
                case $tuic_sub_choice in
                    1)
                        if [ -d "/root/tuic" ]; then
                            echo -e "${yellow}检测到 Tuic 已安装.${re}"
                            read -p $'\033[1;35m您想重新安装吗? (y/N): \033[0m' reinstall_confirm
                            if [[ "$reinstall_confirm" =~ ^[Yy]$ ]]; then
                                uninstall_tuic
                                install_tuic
                            else
                                echo -e "${yellow}取消重新安装.${re}"
                            fi
                        else
                            install_tuic
                        fi
                        break
                        ;;
                    2)
                        change_tuic_config
                        break
                        ;;
                    3)
                        uninstall_tuic
                        break
                        ;;
                    0)
                        break
                        ;;
                    *)
                        echo -e "${red}无效的输入!${re}"
                        sleep 1
                        ;;
                esac
            done
            ;;
        0)
            echo "退出脚本。"
            exit 0
            ;;
        *)
            echo -e "${red}无效的输入!${re}"
            sleep 1
            ;;
    esac
done
