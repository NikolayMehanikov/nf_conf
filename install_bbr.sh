#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail
export LC_ALL=C

installed=/usr/local/sbin/nocta-node-bbr
unit=nocta-node-bbr.service
flow_limit=1000
drift=0
skipped_queue=0

die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
warn() { printf 'Внимание: %s\n' "$*" >&2; }

ensure_tools() {
    local -a packages=()
    command -v ip >/dev/null && command -v tc >/dev/null || packages+=(iproute2)
    command -v sysctl >/dev/null || packages+=(procps)
    command -v modprobe >/dev/null || packages+=(kmod)
    command -v nsenter >/dev/null && command -v flock >/dev/null || packages+=(util-linux)
    if (( ${#packages[@]} )); then
        command -v apt-get >/dev/null || die "Установите пакеты: ${packages[*]}"
        apt-get update -qq
        apt-get install -y --no-install-recommends "${packages[@]}"
    fi
}

bbr_available() {
    local available
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control) || return 1
    [[ " $available " == *' bbr '* ]]
}

load_module() {
    local module=$1 mode=$2 extra
    if modprobe "$module"; then return; fi
    if [[ $mode != install || ! -e /etc/debian_version ]] || modinfo "$module" >/dev/null 2>&1; then
        die "Не удалось загрузить $module для ядра $(uname -r)."
    fi
    extra="linux-modules-extra-$(uname -r)"
    apt-get update -qq
    apt-cache show "$extra" >/dev/null 2>&1 ||
        die "Для модуля $module нет пакета $extra. Проверьте поддержку в ядре хоста."
    apt-get install -y --no-install-recommends "$extra"
    modprobe "$module" || die "Модуль $module для работающего ядра недоступен."
}

prepare_kernel() {
    local mode=$1 current_qdisc
    if ! bbr_available; then load_module tcp_bbr "$mode"; fi
    bbr_available || die "Ядро не зарегистрировало алгоритм bbr."
    current_qdisc=$(sysctl -n net.core.default_qdisc)
    if [[ $current_qdisc != fq ]]; then load_module sch_fq "$mode"; fi
}

setting() {
    local mode=$1 label=$2 key=$3 wanted=$4 value
    shift 4
    value=$("$@" sysctl -n "$key")
    if [[ $value != "$wanted" && $mode == apply ]]; then
        "$@" sysctl -qw "$key=$wanted"
        value=$("$@" sysctl -n "$key")
    fi
    printf '%s: %s = %s\n' "$label" "$key" "$value"
    if [[ $value != "$wanted" ]]; then
        warn "$label: ожидается $wanted"
        drift=1
    fi
}

tune_leaf() {
    local dev=$1 mode=$2 line=$3 kind handle current
    shift 3
    read -r _ kind handle _ <<< "$line"
    case $kind in
        fq)
            if [[ $line =~ [[:space:]]flow_limit[[:space:]]([0-9]+)p?([[:space:]]|$) ]]; then
                current=${BASH_REMATCH[1]}
            else
                die "$dev $*: tc не показал flow_limit."
            fi
            if (( current >= flow_limit )); then
                printf '%s %s: fq flow_limit %sp\n' "$dev" "$*" "$current"
                return
            fi ;;
        fq_codel|pfifo_fast|pfifo)
            if [[ $handle != 0: ]]; then
                warn "$dev $*: сохраняю явно настроенную очередь $kind $handle."
                skipped_queue=1
                return
            fi ;;
        *)
            warn "$dev $*: сохраняю очередь $kind."
            skipped_queue=1
            return ;;
    esac
    printf '%s %s: %s → fq flow_limit %sp\n' "$dev" "$*" "$kind" "$flow_limit"
    if [[ $mode == check ]]; then drift=1; return; fi
    if [[ $kind == fq && $handle != 0: ]]; then
        tc qdisc change dev "$dev" "$@" handle "$handle" fq flow_limit "$flow_limit"
    else
        tc qdisc replace dev "$dev" "$@" fq flow_limit "$flow_limit"
    fi
}

queue_profile() {
    local dev=$1 mode=$2 listing root kind handle line children parent count=0
    listing=$(tc qdisc show dev "$dev")
    root=$(awk '$1 == "qdisc" && $4 == "root" { print; exit }' <<< "$listing")
    [[ -n $root ]] || die "$dev: tc не показал корневую очередь."
    read -r _ kind handle _ <<< "$root"
    if [[ $kind != mq ]]; then
        tune_leaf "$dev" "$mode" "$root" root
        return
    fi

    # An automatic mq with handle 0: cannot address its children through rtnetlink.
    children=$(awk '$1 == "qdisc" && $4 == "parent" && $5 !~ /^ffff:/ {print}' <<< "$listing")
    [[ -n $children ]] || die "$dev: у mq не найдены очереди передачи."
    if [[ $handle == 0: ]]; then
        if ! awk '$3 != "0:" || $2 !~ /^(fq|fq_codel|pfifo_fast|pfifo)$/ {exit 1}' <<< "$children"; then
            warn "$dev: у mq 0: есть нестандартные дочерние очереди; сохраняю дерево."
            skipped_queue=1
            return
        fi
        if [[ $mode == apply ]]; then
            printf '%s: назначаю handle штатному mq, сохраняя многоканальную схему.\n' "$dev"
            tc qdisc replace dev "$dev" root mq
            listing=$(tc qdisc show dev "$dev")
            handle=$(awk '$2 == "mq" && $4 == "root" {print $3}' <<< "$listing")
            [[ -n $handle && $handle != 0: ]] || die "$dev: ядро не назначило mq ненулевой handle."
            children=$(awk '$1 == "qdisc" && $4 == "parent" && $5 !~ /^ffff:/ {print}' <<< "$listing")
            [[ -n $children ]] || die "$dev: очереди mq исчезли после замены."
        fi
    fi
    while IFS= read -r line; do
        read -r _ _ _ _ parent _ <<< "$line"
        if [[ $parent == "$handle"* || ( $handle == 0: && $parent == :* ) ]]; then
            count=$((count + 1))
            tune_leaf "$dev" "$mode" "$line" parent "$parent"
        fi
    done <<< "$children"
    (( count > 0 )) || die "$dev: tc не показал ни одной дочерней очереди mq $handle."
}

host_profile() {
    local mode=$1 wait_seconds=${2:-0} routes devices dev
    while :; do
        routes=$(ip -o -4 route show default && ip -o -6 route show default) || die "Не удалось прочитать маршруты."
        devices=$(awk '{for (i=1; i<NF; i++) if ($i=="dev") print $(i+1)}' <<< "$routes" | sort -u)
        if [[ -n $devices ]] || (( wait_seconds == 0 )); then break; fi
        sleep 1
        wait_seconds=$((wait_seconds - 1))
    done
    [[ -n $devices ]] || die "Нет интерфейса с маршрутом по умолчанию в основной таблице."
    setting "$mode" host net.ipv4.tcp_congestion_control bbr
    setting "$mode" host net.core.default_qdisc fq
    while IFS= read -r dev; do queue_profile "$dev" "$mode"; done <<< "$devices"
}

container_profile() {
    local mode=$1 names name pid
    local -a docker_cmd=(docker --host unix:///var/run/docker.sock)
    if [[ ! -S /var/run/docker.sock ]]; then
        printf 'Локальный Docker ещё не запущен. При создании сетевых пространств ядро берёт TCP-алгоритм хоста.\n'
        return
    fi
    names=$("${docker_cmd[@]}" ps --format '{{.Names}}')
    while IFS= read -r name; do
        case $name in
            edge-caddy|edge-nginx|edge-agent|node-agent-caddy|node-agent-nginx-vod|node-agent) ;;
            *) continue ;;
        esac
        pid=$("${docker_cmd[@]}" inspect -f '{{.State.Pid}}' "$name")
        [[ $pid =~ ^[1-9][0-9]*$ ]] || die "Контейнер $name сменил состояние; повторите запуск."
        setting "$mode" "$name" net.ipv4.tcp_congestion_control bbr nsenter -t "$pid" -n
    done <<< "$names"
}

install_service() (
    local source_file=$1 stage
    install -d /usr/local/sbin /etc/systemd/system
    stage=$(mktemp -d)
    trap 'rm -f -- "$stage/script" "$stage/unit"; rmdir -- "$stage"' EXIT
    install -m 0755 "$source_file" "$stage/script"
    cat > "$stage/unit" <<EOF
[Unit]
Description=NoctaFilm TCP BBR and egress fq for edge and storage
Wants=network-online.target
After=systemd-sysctl.service network-online.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=$installed --boot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    install -m 0755 "$stage/script" "$installed.new"
    mv -fT "$installed.new" "$installed"
    install -m 0644 "$stage/unit" "/etc/systemd/system/$unit.new"
    mv -fT "/etc/systemd/system/$unit.new" "/etc/systemd/system/$unit"
    systemctl daemon-reload
    systemctl enable "$unit"
)

main() {
    local mode=${1:---install}
    if (( $# > 1 )); then die "Допустим один аргумент. См. --help."; fi
    case $mode in
        -h|--help)
            printf '%s\n' 'sudo bash install-bbr.sh          Установить и включить при загрузке' \
                'sudo bash install-bbr.sh --check  Проверить ноду без изменений'
            return ;;
        --install|--check|--boot) ;;
        *) die "Неизвестный аргумент $mode. См. --help." ;;
    esac
    [[ $(uname -s) == Linux && $EUID -eq 0 ]] || die "Запустите на Linux-хосте от root."
    [[ -d /run/systemd/system ]] || die "Для автозапуска требуется systemd на хосте."
    if systemd-detect-virt --quiet --container; then die "Запустите на самом сервере, вне контейнера."; fi

    case $mode in
        --boot)
            prepare_kernel boot
            host_profile apply 30
            host_profile check ;;
        --check)
            host_profile check
            container_profile check
            if ! systemctl is-enabled --quiet "$unit"; then
                warn "Автозапуск $unit не включён."; drift=1
            fi ;;
        --install)
            [[ -f ${BASH_SOURCE[0]} ]] || die "Сохраните скрипт в файл и запустите его через bash."
            ensure_tools
            exec 9>/run/nocta-node-bbr.lock
            flock -x 9
            prepare_kernel install
            install_service "${BASH_SOURCE[0]}"
            if ! systemctl restart "$unit"; then
                journalctl -u "$unit" -n 20 --no-pager >&2
                die "Служба не смогла применить профиль. После исправления повторите запуск."
            fi
            host_profile check
            container_profile apply ;;
    esac
    (( drift == 0 )) || die "Проверка профиля выявила расхождения."
    if (( skipped_queue )); then
        printf 'BBR проверен. Часть очередей пропущена; причины указаны выше.\n'
    else
        printf 'OK: BBR и fq проверены.\n'
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
