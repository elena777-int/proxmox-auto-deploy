#!/bin/bash
SPETSNAZ_VERSION="0.7.12 (2026-11-04)"
NODE=$(hostname -s)

# Параметры экспертного доступа и APT-кэша (переопределяются в spetsnaz.conf)
EXPERT_SUBNET="${EXPERT_SUBNET:-10.100.100}"          # первые три октета технической подсети (/24)
EXPERT_GW="${EXPERT_GW:-${EXPERT_SUBNET}.1}"          # шлюз
EXPERT_DNS="${EXPERT_DNS:-77.88.8.8}"                 # DNS-сервер
EXPERT_IFACE="${EXPERT_IFACE:-ens18}"                 # имя интерфейса внутри гостевой ОС (etcnet, Альт)
APT_MIRROR_HOST="${APT_MIRROR_HOST:-mirror.yandex.ru}" # зеркало, которое заменяется адресом кэшера
APT_MODE="${APT_MODE:-mirror}"                        # mirror — подмена адреса репозитория в sources; proxy — HTTP-прокси через apt.conf.d
case "$APT_MODE" in mirror|proxy) ;; *) APT_MODE="mirror" ;; esac
APT_CACHE_PORT="${APT_CACHE_PORT:-$([ "$APT_MODE" = proxy ] && echo 3128 || echo 3142)}"   # порт кэшера/зеркала/прокси

# Папка образов-заместитель: модуль без своей папки берёт образы другого модуля.
# По КИМ Задания 2 и 3 выполняются на одном преднастроенном стенде (в меню — модуль DEMO_2); DEMO_3, если его
# разворачивают из командной строки, по умолчанию берёт образы DEMO_2.
# Пустое значение в spetsnaz.conf (IMG_FROM_DEMO_3="") отключает замену.
IMG_FROM_DEMO_3="${IMG_FROM_DEMO_3-DEMO_2}"
# Дополнительные диски HQ-SRV для DEMO_2/DEMO_3 (RAID по КИМ): "ЧИСЛО:РАЗМЕР_ГБ"; пусто — не добавлять
HQSRV_EXTRA_DISKS="${HQSRV_EXTRA_DISKS-2:1}"

ADDR_CHECK="${ADDR_CHECK:-1}"                        # после запуска стендов проверять, получили ли внешние адаптеры адрес (1/0)
ADDR_WAIT="${ADDR_WAIT:-150}"                         # сколько секунд ждать адреса после запуска
[[ "$ADDR_WAIT" =~ ^[0-9]+$ ]] || ADDR_WAIT=150

# IPv4-адрес интерфейса гостя с данным MAC (через гостевой агент). Пусто — адреса нет или агент не отвечает.
guest_ipv4_by_mac() {
    local vid=$1 mac=${2,,}
    qm guest cmd "$vid" network-get-interfaces 2>/dev/null | jq -r --arg m "$mac" '
        .[] | select(((.["hardware-address"] // "") | ascii_downcase) == $m)
        | .["ip-addresses"][]? | select(.["ip-address-type"] == "ipv4") | .["ip-address"]' 2>/dev/null \
        | grep -v '^169\.254\.' | head -n 1
}

# Запоминает ВМ, у которой есть включённый внешний адаптер на WAN-мосту (отключённые link_down не нужны)
collect_wan_vm() {
    local s=$1 vid=$2 cfg name line mac
    cfg=$(qm config "$vid" 2>/dev/null) || return 0
    name=$(echo "$cfg" | awk '/^name:/ {print $2}')
    line=$(echo "$cfg" | grep -E '^net[0-9]+:' | grep -E "bridge=${WAN_BR}(,|$)" | grep -v 'link_down=1' | head -n 1)
    [ -z "$line" ] && return 0
    mac=$(echo "$line" | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -n 1)
    [ -z "$mac" ] && return 0
    ADDR_PENDING+=("$s|$vid|$name|$mac")
}

# Ждёт, пока внешние адаптеры запомненных ВМ получат адрес; при repair=1 один раз перезапускает сеть на тех, у кого адреса нет.
check_wan_addresses() {
    local repair=${1:-0} deadline item s vid name mac ip total ok=0 round
    local -a pending=("${ADDR_PENDING[@]}") still=()
    total=${#pending[@]}
    if [ "$total" -eq 0 ]; then
        echo -e "\n${C_YELLOW}Проверка адресов: не найдено запущенных ВМ с включённым адаптером на '$WAN_BR'.${C_NC}"
        return 0
    fi
    echo -e "\n${C_GREEN}Проверка адресов внешних интерфейсов ($WAN_BR): ВМ для проверки — $total, жду до ${ADDR_WAIT} сек...${C_NC}"
    deadline=$(( $(date +%s) + ADDR_WAIT ))
    for round in 1 2; do
        while true; do
            still=()
            for item in "${pending[@]}"; do
                IFS='|' read -r s vid name mac <<< "$item"
                ip=$(guest_ipv4_by_mac "$vid" "$mac")
                if [ -n "$ip" ]; then
                    echo -e "    ${C_GREEN}✔ Стенд $s, ВМ $vid ($name): адрес $ip${C_NC}"
                    ok=$((ok + 1))
                else
                    still+=("$item")
                fi
            done
            pending=("${still[@]}")
            [ ${#pending[@]} -eq 0 ] && break 2
            [ "$(date +%s)" -ge "$deadline" ] && break
            sleep 10
        done
        # второй проход — только после попытки «лечения»
        if [ "$round" -eq 1 ] && [ "$repair" -eq 1 ] && [ ${#pending[@]} -gt 0 ]; then
            echo -e "    ${C_YELLOW}Адрес не получили: ${#pending[@]}. Перезапускаю сеть на этих машинах (systemctl restart network)...${C_NC}"
            for item in "${pending[@]}"; do
                IFS='|' read -r s vid name mac <<< "$item"
                qm agent "$vid" ping >/dev/null 2>&1 && qm guest exec "$vid" -- systemctl restart network >/dev/null 2>&1
            done
            deadline=$(( $(date +%s) + 40 ))
            sleep 15
        else
            break
        fi
    done

    for item in "${pending[@]}"; do
        IFS='|' read -r s vid name mac <<< "$item"
        if qm agent "$vid" ping >/dev/null 2>&1; then
            echo -e "    ${C_YELLOW}⚠ Стенд $s, ВМ $vid ($name): внешний адаптер НЕ получил адрес.${C_NC}"
            echo -e "      Проверьте запись для MAC $mac в IPAM (Datacenter → SDN → IPAM); на машине: systemctl restart network (или перезагрузите ВМ); пункт меню «Авто-регистрация в IPAM».${C_NC}"
        else
            echo -e "    ${C_YELLOW}⚠ Стенд $s, ВМ $vid ($name): гостевой агент не отвечает — проверить адрес нельзя (машина ещё загружается или в образе нет qemu-guest-agent). Проверьте вручную.${C_NC}"
        fi
    done
    if [ ${#pending[@]} -eq 0 ]; then
        echo -e "${C_GREEN}✔ Адрес получили все внешние интерфейсы: $ok из $total.${C_NC}"
    else
        echo -e "${C_YELLOW}Итог проверки: адрес получили $ok из $total, без адреса — ${#pending[@]}.${C_NC}"
    fi
}

gen_password() {
    local len="${1:-8}"
    tr -dc 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz123456789' </dev/urandom | head -c "$len"
}

setup_pve_roles() {
    if ! pveum role list | grep -q "Participant_RC"; then
        pveum role add Participant_RC -privs "VM.Audit VM.Console VM.PowerMgmt" >/dev/null 2>&1
    fi
}

setup_net_roles() {
    if ! pveum role list | grep -q "Participant_NET"; then
        pveum role add Participant_NET -privs "VM.Config.Network" >/dev/null 2>&1
    fi
    if ! pveum role list | grep -q "Participant_SDN"; then
        pveum role add Participant_SDN -privs "SDN.Use" >/dev/null 2>&1
    fi
}

setup_rb_role() {
    if ! pveum role list 2>/dev/null | grep -q "Participant_RB"; then
        pveum role add Participant_RB -privs "VM.Snapshot.Rollback" >/dev/null 2>&1
    fi
    pveum role list 2>/dev/null | grep -q "Participant_RB"
}

# Право отката: ТОЛЬКО VM.Snapshot.Rollback. Права создавать/удалять снапшоты (VM.Snapshot) участники не получают.
grant_rb_access() {
    local pool_name=$1 user=$2
    setup_rb_role || return 1
    pveum acl modify /pool/$pool_name -users "$user" -roles Participant_RB >/dev/null 2>&1
}

revoke_rb_access() {
    local pool_name=$1 user=$2
    pveum acl delete /pool/$pool_name -users "$user" -roles Participant_RB >/dev/null 2>&1
}

stand_base_id() {
    local pool_name=$1
    local first_vmid=$(pvesh get /pools/$pool_name --output-format json 2>/dev/null | grep -Po '"vmid":\K\d+' | head -n 1)
    [ -z "$first_vmid" ] && return 1
    echo $(( (first_vmid / 100) * 100 ))
}

# ID машин пула и «сотни», в которых они лежат (у нормального стенда сотня одна;
# несколько — стенд развёрнут повторно поверх существующего)
pool_vmids() {
    pvesh get "/pools/$1" --output-format json 2>/dev/null | grep -Po '"vmid":\K\d+' | sort -un
}
pool_bases() {
    pool_vmids "$1" | awk '{print int($1 / 100) * 100}' | sort -un
}
# Предупреждение о повторном комплекте; код 1 — комплектов больше одного
pool_check_single() {
    local bases
    bases=$(pool_bases "$1")
    [ "$(echo "$bases" | grep -c .)" -le 1 ] && return 0
    echo -e "${C_RED}✖ В пуле $1 несколько комплектов машин (ID: $(echo "$bases" | sed 's/00$/xx/' | tr '\n' ' ')): стенд разворачивался повторно.${C_NC}"
    echo -e "${C_YELLOW}  Удалите лишний комплект (qm destroy <ID> --purge 1 для каждой его машины), затем повторите операцию.${C_NC}"
    return 1
}

grant_net_access() {
    local pool_name=$1 user=$2 base_id i
    base_id=$(stand_base_id "$pool_name") || return 1
    setup_net_roles
    pveum acl modify /pool/$pool_name -users "$user" -roles Participant_NET >/dev/null 2>&1
    for i in {1..10}; do
        pveum acl modify /sdn/zones/localnetwork/vmbr$((base_id + i)) -users "$user" -roles Participant_SDN >/dev/null 2>&1
    done
}

revoke_net_access() {
    local pool_name=$1 user=$2 base_id i
    pveum acl delete /pool/$pool_name -users "$user" -roles Participant_NET >/dev/null 2>&1
    base_id=$(stand_base_id "$pool_name") || return 0
    for i in {1..10}; do
        pveum acl delete /sdn/zones/localnetwork/vmbr$((base_id + i)) -users "$user" -roles Participant_SDN >/dev/null 2>&1
    done
}

ensure_ovs_flows() {
    local base_id=$1 i tries br failed=0
    for i in 9 10; do
        br="vmbr$((base_id + i))"
        tries=0
        until ovs-vsctl br-exists "$br" 2>/dev/null || [ $tries -ge 30 ]; do
            sleep 1; tries=$((tries + 1))
        done
        ovs-ofctl add-flow "$br" "table=0, dl_dst=01:80:c2:00:00:02, actions=flood" >/dev/null 2>&1
        if ! ovs-ofctl dump-flows "$br" 2>/dev/null | grep -q "01:80:c2:00:00:02"; then
            echo -e "    ${C_YELLOW}⚠ ВНИМАНИЕ: не удалось добавить правило LACP на $br.${C_NC}"
            failed=1
        fi
    done
    return "$failed"
}

# Диск с дополнительными материалами для модуля: «имя_ISO|роли через пробел»; пусто — модулю не нужен
iso_spec() {
    case "$MOD_TYPE" in
        DEMO_2|DEMO_3|DEMO_T2|DEMO_T3|DEMO_GOLD) echo "Additional_de.iso|HQ-SRV BR-SRV" ;;
        REG_*|MOD_*|GOLD_*)                     echo "Additional_rc.iso|COD-ADMIN" ;;
    esac
}

# find_iso <имя>: ищет ISO во всех хранилищах узла с образами ISO (сначала local); печатает volid (local:iso/имя.iso)
# Для Additional_de.iso принимается и имя из КИМ — Additional.iso
find_iso() {
    local want=$1 st name vol
    for name in "$want" $([ "$want" = "Additional_de.iso" ] && echo "Additional.iso"); do
        for st in local $(pvesm status --content iso 2>/dev/null | awk 'NR>1 && $1 != "local" {print $1}'); do
            vol=$(pvesm list "$st" --content iso 2>/dev/null | awk -v n="$name" 'NR>1 { v=$1; sub(/.*\//, "", v); if (v == n) { print $1; exit } }')
            [ -n "$vol" ] && { echo "$vol"; return 0; }
        done
    done
    return 1
}

# attach_iso <vmid> <iso>: подключает диск как CD/DVD (ide2). Код: 0 — подключён; 1 — ISO не найден; 2 — ошибка/занято
# ISO_MISSING считает машины, оставшиеся без диска (итог печатается в конце деплоя)
attach_iso() {
    local v_id=$1 iso=$2 vol out cur
    if ! vol=$(find_iso "$iso"); then
        echo -e "    ${C_YELLOW}⚠ ВНИМАНИЕ: диск $iso$([ "$iso" = "Additional_de.iso" ] && echo " (или Additional.iso)") не найден ни в одном хранилище ISO — ВМ $v_id без диска с дополнительными материалами.${C_NC}"
        ISO_MISSING=$(( ${ISO_MISSING:-0} + 1 ))
        return 1
    fi
    cur=$(qm config "$v_id" 2>/dev/null | grep '^ide2:')
    if [ -n "$cur" ] && ! echo "$cur" | grep -q 'media=cdrom'; then
        echo -e "    ${C_YELLOW}⚠ ВМ $v_id: ide2 занят диском, а не CD/DVD — ISO не подключён.${C_NC}"
        return 2
    fi
    if ! out=$(qm set "$v_id" --ide2 "$vol,media=cdrom" 2>&1); then
        echo -e "    ${C_YELLOW}⚠ ВМ $v_id: ISO не подключён: $(echo "$out" | tail -n 1)${C_NC}"
        return 2
    fi
    ISO_ATTACHED_VOL=$vol
    return 0
}

# Определяет каталог с образами для текущего модуля.
# 1) $IMG_DIR/$MOD_TYPE; 2) подпапка с «похожим» именем (регистр, «_» и «-» не важны);
# 3) иначе — сам $IMG_DIR, но только файлы верхнего уровня (чтобы не подхватить образы другого модуля из его подпапки).
# Печатает "<каталог>|<глубина поиска>|<exact|similar|root>".
dir_has_images() {
    [ -d "$1" ] && [ -n "$(find "$1" -maxdepth 1 -type f -name "*${FILE_MASK}" 2>/dev/null | head -n 1)" ]
}

resolve_img_dir() {
    local want have d av alias
    if dir_has_images "$IMG_DIR/$MOD_TYPE"; then
        echo "$IMG_DIR/$MOD_TYPE|2|exact"; return 0
    fi
    av="IMG_FROM_${MOD_TYPE}"; alias="${!av}"
    if [ -n "$alias" ] && dir_has_images "$IMG_DIR/$alias"; then
        echo "$IMG_DIR/$alias|2|alias"; return 0
    fi
    if [ -d "$IMG_DIR/$MOD_TYPE" ]; then
        echo "$IMG_DIR/$MOD_TYPE|2|exact"; return 0
    fi
    want=$(echo "$MOD_TYPE" | tr 'A-Z' 'a-z' | tr -d '_-')
    for d in "$IMG_DIR"/*/; do
        [ -d "$d" ] || continue
        have=$(basename "$d" | tr 'A-Z' 'a-z' | tr -d '_-')
        if [ "$have" = "$want" ]; then
            echo "${d%/}|2|similar"; return 0
        fi
    done
    echo "$IMG_DIR|1|root"
}

find_image() {
    local dir depth found n pat cnt
    IFS='|' read -r dir depth _ <<< "$(resolve_img_dir)"
    for n in "$@"; do
        for pat in "${n}${FILE_MASK}" "${n}-*${FILE_MASK}" "${n}_*${FILE_MASK}" "${n}.*${FILE_MASK}" "${n}*${FILE_MASK}"; do
            found=$(find "$dir" -maxdepth "$depth" -type f -name "$pat" | sort)
            if [ -n "$found" ]; then
                # если кандидатов несколько — предпочитаем файл с меткой модуля в имени (ISP-DEMO2.vma.zst для DEMO_2)
                local want pref f
                want=$(echo "$MOD_TYPE" | tr 'A-Z' 'a-z' | tr -d '_.-')
                pref=""
                if [ "$(echo "$found" | wc -l)" -gt 1 ]; then
                    while IFS= read -r f; do
                        [[ "$(basename "$f" | tr 'A-Z' 'a-z' | tr -d '_.-')" == *"$want"* ]] && pref+="$f"$'\n'
                    done <<< "$found"
                    [ -n "$pref" ] && found=$(echo -n "$pref" | sed '/^$/d')
                fi
                cnt=$(echo "$found" | wc -l)
                if [ "$cnt" -gt 1 ]; then
                    echo -e "${C_YELLOW}⚠ Для ${n} подходит несколько образов, беру первый:${C_NC}" >&2
                    echo "$found" | sed 's/^/      /' >&2
                fi
                echo "$found" | head -n 1
                return 0
            fi
        done
    done
    return 1
}

expand_ranges() {
    local result=()
    local cleaned_input=$(echo "$@" | tr ',' ' ')

    for item in $cleaned_input; do
        if [[ $item =~ ^([0-9]+)-([0-9]+)$ ]]; then
            for ((i=${BASH_REMATCH[1]}; i<=${BASH_REMATCH[2]}; i++)); do
                result+=("$i")
            done
        elif [[ $item =~ ^[0-9]+$ ]]; then
            result+=("$item")
        fi
    done
    echo "${result[@]}"
}

# Снимок состояния кластера. Ошибки чтения не означают, что ID свободны.
cluster_vms() {
    pvesh get /cluster/resources --type vm --output-format json | jq -ce 'if type == "array" then . else error("VM inventory") end'
}

network_inventory() {
    pvesh get "/nodes/$NODE/network" --output-format json | jq -ce 'if type == "array" then . else error("network inventory") end'
}

pool_inventory() {
    pvesh get /pools --output-format json | jq -ce 'if type == "array" then . else error("pool inventory") end'
}

get_next_free_hundred() {
    local base=10000 ids nets pools occupied net_bases pool_bases
    ids=$(cluster_vms) && nets=$(network_inventory) && pools=$(pool_inventory) || return 1
    occupied=$(jq -r '.[].vmid | tonumber | (. / 100 | floor) * 100' <<< "$ids") || return 1
    net_bases=$(jq -r '.[].iface | select(test("^vmbr[0-9]+$")) | ltrimstr("vmbr") | tonumber | (. / 100 | floor) * 100' <<< "$nets") || return 1
    pool_bases=$(jq -r '.[].comment // "" | capture("^spetsnaz-v1:[^:]+:(?<base>[0-9]+):") | .base' <<< "$pools") || return 1
    occupied+=$'\n'$net_bases$'\n'$pool_bases
    while grep -Fxq "$base" <<< "$occupied"; do base=$((base + 100)); done
    [ "$base" -le 999999900 ] || return 1
    printf '%s\n' "$base"
}

# Метка хранится в пуле и каждом созданном мосту. Старые мосты не помечаются задним числом.
read_stand_owner() {
    local comment=$1
    [[ "$comment" =~ ^spetsnaz-v1:([a-zA-Z0-9.-]+):([0-9]{5,9}):([a-f0-9]{32})$ ]] || return 1
    STAND_NODE=${BASH_REMATCH[1]} STAND_BASE=${BASH_REMATCH[2]} STAND_TOKEN=${BASH_REMATCH[3]}
}

bridge_type_for() {
    case "$MOD_TYPE" in
        DEMO*) [ "$1" -eq 3 ] && { echo OVSBridge; return; } ;;
        REG_*|MOD_*|GOLD_*) [ "$1" -ge 9 ] && { echo OVSBridge; return; } ;;
    esac
    echo bridge
}

bridge_is_owned() {
    jq -e --arg iface "$2" --arg owner "$3" --arg type "$4" '
        any(.[]; .iface == $iface and .type == $type and
            ((.comments // "") | sub("\n$"; "")) == $owner and
            ([.bridge_ports, .ovs_ports, .address, .address6, .cidr, .cidr6] | all(. == null or . == "")))
    ' >/dev/null <<< "$1"
}

apply_stand_network() {
    local upid status tries
    upid=$(pvesh set "/nodes/$NODE/network" --output-format json | jq -er 'strings | select(startswith("UPID:"))') || return 1
    for ((tries=0; tries<90; tries++)); do
        status=$(pvesh get "/nodes/$NODE/tasks/$upid/status" --output-format json) || return 1
        if jq -e '.status == "stopped"' >/dev/null <<< "$status"; then
            if jq -e '.exitstatus == "OK"' >/dev/null <<< "$status"; then return 0; fi
            echo "✖ Применение сети завершилось ошибкой: $(jq -r '.exitstatus // "нет статуса"' <<< "$status")" >&2
            return 1
        fi
        sleep 1
    done
    echo "Истекло время ожидания применения сетевой конфигурации." >&2
    return 1
}

stand_network() {
    local mode=$1 base=$2 owner=$3 nets bridge type i
    local -a changes=()
    nets=$(network_inventory) || return 1
    for i in {1..10}; do
        bridge="vmbr$((base+i))"
        type=$(bridge_type_for "$i")
        if [[ "$mode" == create || "$mode" == verify ]] && [ "$bridge" = "$WAN_BR" ]; then
            echo "✖ $bridge зарезервирован для внутренней сети и не может быть WAN стенда." >&2
            return 1
        fi
        if jq -e --arg iface "$bridge" 'any(.[]; .iface == $iface)' >/dev/null <<< "$nets"; then
            if ! bridge_is_owned "$nets" "$bridge" "$owner" "$type"; then
                echo "✖ Мост $bridge уже занят или изменён. Мост оставлен без изменений." >&2
                return 1
            fi
            if [ "$mode" = delete ]; then
                changes+=("$i")
            elif [[ "$mode" == verify || "$mode" == create ]] && ! ip link show dev "$bridge" >/dev/null 2>&1; then
                echo "✖ Мост стенда $bridge не активирован на узле." >&2
                return 1
            fi
        elif ip link show dev "$bridge" >/dev/null 2>&1; then
            echo "✖ Интерфейс $bridge уже существует вне списка сети Proxmox." >&2
            return 1
        elif [ "$mode" = verify ]; then
            echo "✖ Мост стенда $bridge не найден." >&2
            return 1
        elif [ "$mode" = create ]; then
            changes+=("$i")
        fi
    done
    if [ -e /etc/network/interfaces.new ]; then
        echo "✖ На узле есть неприменённые сетевые изменения. Проверьте их в Proxmox и повторите операцию." >&2
        return 1
    fi
    [ "${#changes[@]}" -gt 0 ] || return 0
    for i in "${changes[@]}"; do
        bridge="vmbr$((base+i))"
        if [ "$mode" = delete ]; then
            nets=$(network_inventory) && bridge_is_owned "$nets" "$bridge" "$owner" "$(bridge_type_for "$i")" || return 1
            local cfg
            for cfg in /etc/pve/nodes/"$NODE"/{qemu-server,lxc}/*.conf; do
                [ -f "$cfg" ] || continue
                if grep -Eq "(^|,)bridge=$bridge(,|$)" "$cfg"; then
                    echo "✖ $bridge ещё используется: ${cfg##*/}. Мост оставлен на месте." >&2
                    return 1
                fi
            done
            pvesh delete "/nodes/$NODE/network/$bridge" || return 1
        else
            pvesh create "/nodes/$NODE/network" --iface "$bridge" --type "$(bridge_type_for "$i")" \
                --autostart 1 --comments "$owner" || return 1
        fi
    done
    apply_stand_network || return 1
    if [ "$mode" = create ]; then stand_network verify "$base" "$owner"; fi
}

# Имя ВМ для роли (имя образа может совпадать с любым из двух)
role_label() {
    case "$1" in
        PROV-GW) echo "PROVIDER-GW" ;;
        PROV-SW) echo "PROVIDER-SW" ;;
        *)       echo "$1" ;;
    esac
}

# Раскладка ВМ стенда: строки "смещение#роль#адаптеры". Используется деплоем и оценкой места.
stand_vm_list() {
    local br=$1 s=$2

    local vms=()
    if [[ "$MOD_TYPE" == DEMO* ]]; then
        vms=(
            "1#ISP#net0:$WAN_BR net1:vmbr$((br+1)) net2:vmbr$((br+2))"
            "2#HQ-RTR#net0:$WAN_BR,link_down=1 net1:vmbr$((br+1)) net2:vmbr$((br+3))"
            "3#BR-RTR#net0:$WAN_BR,link_down=1 net1:vmbr$((br+2)) net2:vmbr$((br+4))"
            "4#BR-FW#net0:vmbr$((br+4)) net1:vmbr$((br+5))"
            "5#HQ-SRV#net0:vmbr$((br+3)),tag=$VLAN_1"
            "6#HQ-CLI#net0:vmbr$((br+3)),tag=$VLAN_2"
            "7#BR-SRV#net0:vmbr$((br+5))"
        )
    else
        vms=(
            "1#PROV-GW#net0:vmbr$((br+9)) net1:vmbr$((br+10))"
            "2#PROV-SW#net0:vmbr$((br+8)) net1:vmbr$((br+9)) net2:vmbr$((br+10))"
            "3#COD-GW#net0:$WAN_BR,link_down=1 net1:vmbr$((br+4)) net2:vmbr$((br+5))"
            "4#GW-1#net0:$WAN_BR,link_down=1 net1:vmbr$((br+1)) net2:vmbr$((br+4))"
            "5#GW-2#net0:$WAN_BR,link_down=1 net1:vmbr$((br+2)) net2:vmbr$((br+6))"
            "6#GW-3#net0:$WAN_BR,link_down=1 net1:vmbr$((br+3)) net2:vmbr$((br+8))"
            "7#ZSPD-FW#net0:vmbr$((br+7))"
            "8#GW-CORE#net0:$WAN_BR net1:vmbr$((br+1)) net2:vmbr$((br+2)) net3:vmbr$((br+3))"
            "9#ZSPD-SW#net0:vmbr$((br+6)) net1:vmbr$((br+7))"
            "10#COD-SRV-1#net0:vmbr$((br+5)) net1:vmbr$((br+5))"
            "11#COD-SRV-2#net0:vmbr$((br+5))"
            "12#PUB#net0:vmbr$((br+5))"
            "13#COD-ADMIN#net0:vmbr$((br+5)) net1:vmbr$((br+5))"
            "14#DATA#net0:vmbr$((br+5))"
        )
    fi
    printf '%s\n' "${vms[@]}"
}

# Локальный unicast MAC. VMID уникален в кластере; номер стенда может повторяться.
wan_mac() {
    local vid=$1
    printf '02:53:%02X:%02X:%02X:%02X' "$((vid>>24 & 255))" "$((vid>>16 & 255))" "$((vid>>8 & 255))" "$((vid & 255))"
}

net_value() {
    local vid=$1 current=$2 target=$3 bridge opt item head vlan down=0
    local -a spec old
    IFS=, read -ra spec <<< "$target"
    IFS=, read -ra old <<< "$current"
    bridge=${spec[0]}
    head=${old[0]}
    [[ "$bridge" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,14}$ && "$head" =~ ^[a-zA-Z0-9_]+(=([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2})?$ ]] || return 1
    if [ "$bridge" = "$WAN_BR" ]; then head="${head%%=*}=$(wan_mac "$vid")"; fi
    for item in "${old[@]:1}"; do
        case "$item" in bridge=*|tag=*|trunks=*|link_down=*) ;; *) head+=",$item" ;; esac
    done
    for opt in "${spec[@]:1}"; do
        case "$opt" in
            link_down=1) down=1 ;;
            tag=*) vlan=${opt#tag=}; [[ "$vlan" =~ ^[0-9]{1,4}$ ]] && ((10#$vlan >= 1 && 10#$vlan <= 4094)) || return 1; head+=",tag=$((10#$vlan))" ;;
            *) return 1 ;;
        esac
    done
    # Для отключённого WAN одного link_down недостаточно: не привязываем адаптер к внешнему мосту.
    if [ "$bridge" != "$WAN_BR" ] || [ "$down" -eq 0 ]; then head+=",bridge=$bridge"; fi
    printf '%s,link_down=%s\n' "$head" "$down"
}

configure_stand_net() {
    local vid=$1 rules=$2 cfg rule iface current patched extra remove="" status
    local -a args=()
    status=$(qm status "$vid") && [ "$status" = "status: stopped" ] || return 1
    cfg=$(qm config "$vid") || return 1
    for rule in $rules; do
        iface=${rule%%:*}
        current=$(awk -v key="$iface:" '$1 == key {print $2; exit}' <<< "$cfg")
        if ! patched=$(net_value "$vid" "$current" "${rule#*:}"); then
            echo "✖ ВМ $vid: нет корректного адаптера $iface для ${rule#*:}." >&2
            return 1
        fi
        args+=("--$iface" "$patched")
    done
    # Лишние адаптеры из бэкапа могут вести на чужие мосты.
    while read -r extra; do
        [[ " $rules " == *" $extra:"* ]] || remove+="${remove:+,}$extra"
    done < <(awk -F: '/^net[0-9]+:/ {print $1}' <<< "$cfg")
    [ -z "$remove" ] || args+=(--delete "$remove")
    qm set "$vid" "${args[@]}"
}

# ===================== Память и ядра ВМ по ролям (необязательно) =====================
# В spetsnaz.conf: RES_<РОЛЬ>="ПАМЯТЬ_МБ:ЯДРА" (дефисы в имени роли заменяются подчёркиваниями: RES_HQ_SRV).
# При деплое и переразвёртывании применяются, только если RES_APPLY=1 (меню спрашивает перед операцией).
label_role() {
    case "$1" in
        PROVIDER-GW) echo "PROV-GW" ;;
        PROVIDER-SW) echo "PROV-SW" ;;
        *)           echo "$1" ;;
    esac
}

res_for_role() {
    local v="RES_$(echo "$1" | tr 'a-z-' 'A-Z_')"
    echo "${!v}"
}

# apply_resources <vmid> <роль>: 0 — применено или не задано; 1 — ошибка
apply_resources() {
    local vid=$1 role=$2 spec mem cores cfg bal out args
    spec=$(res_for_role "$role")
    [ -z "$spec" ] && return 0
    if ! [[ "$spec" =~ ^([0-9]+):([0-9]+)$ ]] || [ "${BASH_REMATCH[1]}" -lt 256 ] || [ "${BASH_REMATCH[2]}" -lt 1 ]; then
        echo -e "      ${C_YELLOW}⚠ $role: значение '$spec' не в формате ПАМЯТЬ_МБ:ЯДРА (например 1024:1) — ресурсы не изменены.${C_NC}"
        return 1
    fi
    mem=${BASH_REMATCH[1]}; cores=${BASH_REMATCH[2]}
    if [ "$role" = "BR-FW" ] && { [ "$mem" -lt 8192 ] || [ "$cores" -lt 2 ]; }; then
        echo -e "      ${C_YELLOW}⚠ BR-FW: $mem МБ, ядер $cores — меньше минимума производителя Ideco NGFW (8 ГБ, 2 ядра). На свой риск: проверьте работу Ideco на одном стенде.${C_NC}"
    fi
    cfg=$(qm config "$vid" 2>/dev/null)
    args=(--memory "$mem" --sockets 1 --cores "$cores")
    bal=$(awk '/^balloon:/{print $2}' <<< "$cfg")
    [ -n "$bal" ] && [ "$bal" -gt "$mem" ] && args+=(--balloon "$mem")
    grep -q '^vcpus:' <<< "$cfg" && args+=(--delete vcpus)
    if out=$(qm set "$vid" "${args[@]}" 2>&1); then
        echo -e "      ресурсы $role: память $mem МБ, ядер $cores"
    else
        echo -e "      ${C_YELLOW}⚠ $role: ресурсы не изменены: $(echo "$out" | tail -n 1)${C_NC}"
        return 1
    fi
}

# Дополнительные диски HQ-SRV (DEMO_2/DEMO_3): добавляются, только если у машины один диск
add_extra_disks() {
    local vid=$1 cnt size cfg first bus have need i k added=0 out
    [[ "$HQSRV_EXTRA_DISKS" =~ ^([0-9]+):([0-9]+)$ ]] || return 0
    cnt=${BASH_REMATCH[1]}; size=${BASH_REMATCH[2]}
    [ "$cnt" -gt 0 ] || return 0
    cfg=$(qm config "$vid" 2>/dev/null)
    first=$(echo "$cfg" | grep -E '^(scsi|virtio|sata|ide)[0-9]+: ' | grep -v 'media=cdrom' | head -n 1)
    [ -n "$first" ] || { echo "✖ HQ-SRV: не найден основной диск." >&2; return 1; }
    have=$(echo "$cfg" | grep -E '^(scsi|virtio|sata|ide)[0-9]+: ' | grep -vc 'media=cdrom')
    [ "$have" -ge $((cnt+1)) ] && return 0
    bus=$(echo "$first" | sed -E 's/^([a-z]+)[0-9]+:.*/\1/')
    need=$((cnt+1-have))
    for i in $(seq 0 30); do
        [ "$need" -eq 0 ] && break
        [ "$bus" = "ide" ] && [ "$i" -gt 3 ] && break
        echo "$cfg" | grep -q "^${bus}${i}: " && continue
        if out=$(qm set "$vid" --${bus}${i} "${TARGET_STORAGE}:${size}" 2>&1); then
            cfg+=$'\n'"${bus}${i}: added"; need=$((need - 1)); added=$((added + 1))
        else
            echo -e "      ${C_YELLOW}⚠ HQ-SRV: диск ${bus}${i} не добавлен: $(echo "$out" | tail -n 1)${C_NC}"; break
        fi
    done
    [ "$added" -gt 0 ] && echo -e "      HQ-SRV: добавлено дисков для RAID — $added по $size ГБ (параметр HQSRV_EXTRA_DISKS)"
    [ "$need" -eq 0 ]
}

pool_info() {
    pvesh get "/pools/$1" --output-format json | jq -ce 'select(type == "object" and (.members | type == "array"))'
}

pool_owns_vm() {
    jq -e --argjson id "$2" --arg node "$NODE" '
        any(.members[]; .type == "qemu" and .vmid == $id and .node == $node)
    ' >/dev/null <<< "$1"
}

vm_id_in_use() {
    jq -e --argjson id "$2" 'any(.[]; .vmid == $id)' >/dev/null <<< "$1"
}

vm_ready() {
    local cfg
    cfg=$(qm config "$1") || return 1
    awk '/^tags:/ {print $2}' <<< "$cfg" | tr ';,' '\n' | grep -Fxq "spz-ready-$2" &&
        snap_exists "$1" Day0
}

restore_new_vm() {
    local vid=$1 archive=$2 pool=$3 out cfg status
    # --pool добавляет ВМ к пулу при успешном восстановлении. Никогда не перезаписываем занятый ID.
    if ! out=$( (set -o pipefail; zstdcat "$archive" | qmrestore - "$vid" --storage "$TARGET_STORAGE" --pool "$pool") 2>&1 ); then
        echo "✖ ВМ $vid: восстановление не удалось. $(tail -n 3 <<< "$out" | tr '\n' ' ')" >&2
        # Эта диагностика идёт от уже запущенного воркера qmrestore. При
        # коллизии ID CLI отказывает до его запуска. Стираем только пустую
        # заглушку нашего неудачного восстановления, без обхода блокировок.
        if [[ "$out" == *"some or all disks were not completely restored. VM $vid state is NOT cleaned up."* ]]; then
            if cfg=$(qm config "$vid") && [[ -z "$cfg" || "$cfg" == "memory: 128" ]] &&
                status=$(qm status "$vid") && [ "$status" = "status: stopped" ] && qm destroy "$vid"; then
                echo "  Пустая запись ВМ $vid после сбоя удалена; роль можно повторить." >&2
            else
                echo "  ВМ $vid не удалена автоматически. Проверьте её конфигурацию перед повтором." >&2
            fi
        fi
        return 1
    fi
}

finish_vm() {
    local vid=$1 role=$2 rules=$3 tag=$4 token=$5 label spec rc
    label=$(role_label "$role")
    qm set "$vid" --onboot 0 || return 1
    configure_stand_net "$vid" "$rules" || return 1
    qm set "$vid" --name "$label" --tablet 1 --vga qxl || return 1
    spec=$(iso_spec)
    if [ -n "$spec" ] && [[ " ${spec#*|} " == *" $role "* ]]; then
        attach_iso "$vid" "${spec%%|*}"; rc=$?
        # Отсутствующий ISO уже показывается отдельным предупреждением.
        [ "$rc" -le 1 ] || return 1
    fi
    case "$MOD_TYPE:$role" in
        DEMO_2:HQ-SRV|DEMO_3:HQ-SRV|DEMO_T2:HQ-SRV|DEMO_T3:HQ-SRV|DEMO_GOLD:HQ-SRV)
            add_extra_disks "$vid" || return 1 ;;
    esac
    if [ "${RES_APPLY:-0}" = 1 ]; then apply_resources "$vid" "$role" || return 1; fi
    qm set "$vid" --tags "$tag,spz-ready-$token" || return 1
    if ! snap_exists "$vid" Day0; then
        qm snapshot "$vid" Day0 --description "Чистый старт стенда" || return 1
    fi
}

stand_account() {
    local s=$1 pool=$2 owner=$3 account users comment pass
    setup_pve_roles || return 1
    account="${MOD_TYPE,,}"; account="${account//_/-}-s${s}@pve"
    users=$(pvesh get /access/users --output-format json) || return 1
    comment=$(jq -r --arg user "$account" '.[] | select(.userid == $user) | .comment // ""' <<< "$users") || return 1
    if jq -e --arg user "$account" 'any(.[]; .userid == $user)' >/dev/null <<< "$users"; then
        if [ "$comment" != "$owner" ]; then
            echo "✖ Учётная запись $account существует и не принадлежит стенду." >&2
            return 1
        fi
        if awk -F, -v user="$account" '$2 == user {found=1} END {exit !found}' "$CSV_FILE"; then return 0; fi
        pass=$(gen_password 8)
        pvesh set /access/password --userid "$account" --password "$pass" >/dev/null || return 1
    else
        pass=$(gen_password 8)
        pveum user add "$account" --comment "$owner" --password "$pass" || return 1
    fi
    pveum acl modify "/pool/$pool" -users "$account" -roles Participant_RC || return 1
    printf 'Стенд %s (%s),%s,%s\n' "$s" "$MOD_TYPE" "$account" "$pass" >> "$CSV_FILE"
}

redeploy_vm() {
    local s=$1 role=$2 pool="${MOD_TYPE}_S$1" info owner line off name nets vid label cur src rule iface target tag new_nets="" st="" ids archive
    info=$(pool_info "$pool") || return 1
    owner=$(jq -r '.comment // ""' <<< "$info") || return 1
    if ! read_stand_owner "$owner" || [ "$STAND_NODE" != "$NODE" ]; then
        echo "✖ $pool: переразвёртывание доступно только для стенда с подтверждённой сетью на этом узле." >&2
        return 1
    fi
    stand_network verify "$STAND_BASE" "$owner" || return 1
    line=$(stand_vm_list "$STAND_BASE" "$s" | awk -F'#' -v r="$role" '$2 == r')
    [ -n "$line" ] || { echo "✖ Неизвестная роль $role." >&2; return 1; }
    IFS='#' read -r off name nets <<< "$line"
    vid=$((STAND_BASE + off)); label=$(role_label "$name")
    archive=$(find_image "$name" "$label")
    if [ ! -s "$archive" ]; then echo "✖ Образ $label не найден или пуст." >&2; return 1; fi

    ids=$(cluster_vms) || return 1
    if vm_id_in_use "$ids" "$vid"; then
        if ! pool_owns_vm "$info" "$vid"; then
            echo "✖ ID $vid занят ВМ вне пула $pool на этом узле." >&2
            return 1
        fi
        cur=$(qm config "$vid") || return 1
        [ "$(awk '/^name:/ {print $2; exit}' <<< "$cur")" = "$label" ] || return 1
        src=$(qm config "$vid" --snapshot Day0 2>/dev/null) || src=$cur
        for rule in $nets; do
            iface=${rule%%:*}; target=${rule#*:}
            tag=$(grep "^$iface:" <<< "$src" | grep -oP 'tag=\K[0-9]+')
            if [[ "$target" == *tag=* ]] && [ -n "$tag" ]; then target=${target%tag=*}tag=$tag; fi
            new_nets+="$iface:$target "
        done
        nets=$new_nets
        st=$(grep -E '^(scsi|sata|virtio|ide)[0-9]+: ' <<< "$cur" | grep -v 'media=cdrom' | head -n 1 | sed -E 's/^[a-z]+[0-9]+: ([^:,]+):.*/\1/')
        # Проверяем архив до необратимой замены.
        zstd -tq -- "$archive" || return 1
        if [ "$(qm status "$vid")" != "status: stopped" ]; then qm stop "$vid" || return 1; fi
        info=$(pool_info "$pool") && pool_owns_vm "$info" "$vid" || return 1
        qm destroy "$vid" || return 1
    fi
    TARGET_STORAGE="${st:-$TARGET_STORAGE}" restore_new_vm "$vid" "$archive" "$pool" || return 1
    info=$(pool_info "$pool") && pool_owns_vm "$info" "$vid" || return 1
    finish_vm "$vid" "$name" "$nets" "${MOD_TYPE,,},stand_$s" "$STAND_TOKEN"
}

deploy_from_images() {
    local s=$1 pool="${MOD_TYPE}_S$1" owner info ids pools token base line off name rules vid archive failed=0 exists=0
    local -a vms=()
    local -A archives=()
    pools=$(pool_inventory) || return 1
    if jq -e --arg pool "$pool" 'any(.[]; .poolid == $pool)' >/dev/null <<< "$pools"; then
        exists=1
        info=$(pool_info "$pool") || return 1
        owner=$(jq -r '.comment // ""' <<< "$info") || return 1
        if ! read_stand_owner "$owner" || [ "$STAND_NODE" != "$NODE" ]; then
            echo "✖ $pool: существующий пул без метки этого узла. Пул оставлен без изменений." >&2
            return 1
        fi
        base=$STAND_BASE token=$STAND_TOKEN
    else
        base=$(get_next_free_hundred) || return 1
        token=$(tr -d '-' </proc/sys/kernel/random/uuid) || return 1
        owner="spetsnaz-v1:$NODE:$base:$token"
    fi
    mapfile -t vms < <(stand_vm_list "$base" "$s")
    ids=$(cluster_vms) || return 1
    # Проверяем все требуемые образы и конфликты до первого изменения.
    for line in "${vms[@]}"; do
        IFS='#' read -r off name rules <<< "$line"
        vid=$((base+off))
        if vm_id_in_use "$ids" "$vid"; then
            if ! pool_owns_vm "$info" "$vid"; then
                echo "✖ $name: ID $vid занят другой ВМ." >&2
                failed=1
            fi
        else
            archive=$(find_image "$name" "$(role_label "$name")")
            if [ ! -s "$archive" ]; then echo "✖ $name: образ отсутствует или пуст." >&2; failed=1
            else archives[$vid]=$archive; fi
        fi
    done
    [ "$failed" -eq 0 ] || return 1
    if [ "$exists" -eq 0 ]; then
        pvesh create /pools --poolid "$pool" --comment "$owner" || return 1
    fi
    stand_network create "$base" "$owner" || return 1
    case "$MOD_TYPE" in REG_*|MOD_*|GOLD_*) ensure_ovs_flows "$base" || return 1 ;; esac

    for line in "${vms[@]}"; do
        IFS='#' read -r off name rules <<< "$line"
        vid=$((base+off))
        if [ -n "${archives[$vid]}" ]; then
            if ! restore_new_vm "$vid" "${archives[$vid]}" "$pool"; then failed=1; continue; fi
        elif vm_ready "$vid" "$token"; then
            echo "  ✔ $name ($vid): уже готова."
            continue
        fi
        if info=$(pool_info "$pool") && pool_owns_vm "$info" "$vid" &&
            finish_vm "$vid" "$name" "$rules" "${MOD_TYPE,,},stand_$s" "$token"; then
            echo "  ✔ $name ($vid): готова."
        else
            echo "  ✖ $name ($vid): настройка не завершена." >&2
            failed=1
        fi
    done
    [ "$failed" -eq 0 ] && stand_account "$s" "$pool" "$owner"
}

# --- Снапшоты: с проверкой существования и видимым результатом (раньше ошибки qm скрывались) ---
SNAP_OK=0; SNAP_SKIP=0; SNAP_FAIL=0

snap_exists() {
    local vid=$1 name=$2
    pvesh get "/nodes/$NODE/qemu/$vid/snapshot" --output-format json 2>/dev/null | jq -r '.[].name' 2>/dev/null | grep -qx "$name"
}

# snap_op <snapshot|rollback|delsnap> <vmid> <имя>
snap_op() {
    local op=$1 vid=$2 name=$3 out rc vmname
    vmname=$(qm config "$vid" 2>/dev/null | grep -m1 '^name:' | awk '{print $2}')
    local label="VM $vid${vmname:+ ($vmname)}"
    case "$op" in
        snapshot)
            if snap_exists "$vid" "$name"; then
                if [ "${SNAP_REPLACE:-0}" = "1" ]; then
                    out=$(qm delsnapshot "$vid" "$name" 2>&1) || { echo -e "    ${C_RED}✖ $label: не удалось удалить старый '$name': $(echo "$out" | tail -n 1)${C_NC}"; SNAP_FAIL=$((SNAP_FAIL+1)); return; }
                else
                    echo -e "    ${C_YELLOW}⏭ $label: снапшот '$name' уже есть — пропущен (чтобы пересоздать, выберите «заменить»).${C_NC}"
                    SNAP_SKIP=$((SNAP_SKIP+1)); return
                fi
            fi
            if qm status "$vid" 2>/dev/null | grep -q running; then
                qm guest exec "$vid" -- sync >/dev/null 2>&1   # сбросить буферы гостя на диск (если агент отвечает), затем остановить
                qm stop "$vid" >/dev/null 2>&1; sleep 1
            fi
            out=$(qm snapshot "$vid" "$name" --description "Создан $(date '+%F %H:%M')" 2>&1); rc=$?
            if [ $rc -ne 0 ] && echo "$out" | grep -qi "locked"; then qm unlock "$vid" >/dev/null 2>&1; out=$(qm snapshot "$vid" "$name" --description "Создан $(date '+%F %H:%M')" 2>&1); rc=$?; fi
            if [ $rc -eq 0 ]; then echo -e "    ${C_GREEN}✔ $label: снапшот '$name' создан.${C_NC}"; SNAP_OK=$((SNAP_OK+1))
            else echo -e "    ${C_RED}✖ $label: $(echo "$out" | tail -n 1)${C_NC}"; SNAP_FAIL=$((SNAP_FAIL+1)); fi
            ;;
        rollback)
            if ! snap_exists "$vid" "$name"; then
                echo -e "    ${C_YELLOW}⚠ $label: снапшота '$name' нет — откатывать не к чему. Есть: $(pvesh get "/nodes/$NODE/qemu/$vid/snapshot" --output-format json 2>/dev/null | jq -r '[.[] | select(.name != "current") | .name] | join(", ")')${C_NC}"
                SNAP_SKIP=$((SNAP_SKIP+1)); return
            fi
            qm status "$vid" 2>/dev/null | grep -q running && { qm stop "$vid" >/dev/null 2>&1; sleep 1; }
            out=$(qm rollback "$vid" "$name" 2>&1); rc=$?
            if [ $rc -ne 0 ] && echo "$out" | grep -qi "locked"; then qm unlock "$vid" >/dev/null 2>&1; out=$(qm rollback "$vid" "$name" 2>&1); rc=$?; fi
            if [ $rc -eq 0 ]; then echo -e "    ${C_GREEN}✔ $label: откат к '$name' выполнен (машина выключена).${C_NC}"; SNAP_OK=$((SNAP_OK+1))
            else echo -e "    ${C_RED}✖ $label: $(echo "$out" | tail -n 2 | tr '\n' ' ')${C_NC}"; SNAP_FAIL=$((SNAP_FAIL+1)); fi
            ;;
        delsnap)
            if ! snap_exists "$vid" "$name"; then
                echo -e "    ${C_YELLOW}⏭ $label: снапшота '$name' нет — удалять нечего.${C_NC}"; SNAP_SKIP=$((SNAP_SKIP+1)); return
            fi
            out=$(qm delsnapshot "$vid" "$name" 2>&1); rc=$?
            if [ $rc -eq 0 ]; then echo -e "    ${C_GREEN}✔ $label: снапшот '$name' удалён.${C_NC}"; SNAP_OK=$((SNAP_OK+1))
            else echo -e "    ${C_RED}✖ $label: $(echo "$out" | tail -n 1)${C_NC}"; SNAP_FAIL=$((SNAP_FAIL+1)); fi
            ;;
    esac
}

stand_vms_ready() {
    local s=$1 info=$2 off vid count=0
    while IFS='#' read -r off _; do
        vid=$((STAND_BASE+off))
        pool_owns_vm "$info" "$vid" && vm_ready "$vid" "$STAND_TOKEN" || return 1
        count=$((count+1))
    done < <(stand_vm_list "$STAND_BASE" "$s")
    jq -e --argjson count "$count" '[.members[] | select(.type == "qemu")] | length == $count' >/dev/null <<< "$info"
}

destroy_stand() {
    local s=$1 pool=$2 info=$3 owner=$4 vid account expected="" off managed=0
    local -a vmids=()
    mapfile -t vmids < <(jq -r '.members[] | select(.type == "qemu") | .vmid' <<< "$info")
    if read_stand_owner "$owner"; then
        managed=1
        [ "$STAND_NODE" = "$NODE" ] || { echo "✖ $pool принадлежит узлу $STAND_NODE." >&2; return 1; }
        stand_network verify-delete "$STAND_BASE" "$owner" || return 1
        while IFS='#' read -r off _; do expected+=" $((STAND_BASE+off)) "; done < <(stand_vm_list "$STAND_BASE" "$s")
    fi
    for vid in "${vmids[@]}"; do
        if ! pool_owns_vm "$info" "$vid" || { [ "$managed" -eq 1 ] && [[ "$expected" != *" $vid "* ]]; }; then
            echo "✖ $pool: не удалось подтвердить принадлежность ВМ $vid на этом узле." >&2
            return 1
        fi
    done
    for vid in "${vmids[@]}"; do
        info=$(pool_info "$pool") && pool_owns_vm "$info" "$vid" || return 1
        if [ "$(qm status "$vid")" != "status: stopped" ]; then qm stop "$vid" || return 1; fi
        qm destroy "$vid" --purge 1 || return 1
    done
    account="${MOD_TYPE,,}"; account="${account//_/-}-s${s}@pve"
    if [ "$managed" -eq 1 ]; then
        stand_network delete "$STAND_BASE" "$owner" || return 1
        local users
        users=$(pvesh get /access/users --output-format json) || return 1
        if jq -e --arg user "$account" --arg owner "$owner" \
            'any(.[]; .userid == $user and .comment == $owner)' >/dev/null <<< "$users"; then
            pveum user delete "$account" || return 1
        fi
        local i
        for i in {1..10}; do
            pveum acl delete "/sdn/zones/localnetwork/vmbr$((STAND_BASE+i))" -users "$account" -roles Participant_SDN >/dev/null 2>&1 || :
        done
    else
        echo "⚠ $pool: старый стенд. Мосты и учётная запись без метки владельца оставлены для ручной проверки."
    fi
    info=$(pool_info "$pool") &&
        jq -e '[.members[] | select(.type == "qemu" or .type == "lxc")] | length == 0' >/dev/null <<< "$info" || return 1
    pvesh delete "/pools/$pool" || return 1
    local f
    for f in "$CSV_FILE" "$ROT_FILE"; do
        [ ! -f "$f" ] || sed -i "/^Стенд $s ($MOD_TYPE),/d" "$f"
    done
    echo "✔ Стенд $s удалён."
}

manage_state() {
    local stands_list=($(expand_ranges "$@"))
    local s pool_name pools vmid info owner failed=0
    local -a pool_arr
    local tau_delay=${TAU_DELAY:-8}
    ADDR_PENDING=()

    pools=$(pool_inventory) || return 1
    for s in "${stands_list[@]}"; do
        mapfile -t pool_arr < <(jq -r --arg pool "${MOD_TYPE}_S$s" '.[] | select(.poolid == $pool) | .poolid' <<< "$pools")
        if [ "${#pool_arr[@]}" -eq 0 ]; then
            echo "✖ Пул ${MOD_TYPE}_S$s не найден." >&2
            failed=1
            continue
        fi
        for pool_name in "${pool_arr[@]}"; do
            if [[ "$ACTION" == "netperm_on" || "$ACTION" == "netperm_off" ]]; then
                local mod_lower=$(echo "$MOD_TYPE" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
                local target_user="${mod_lower}-s${s}@pve"

                if pveum user list 2>/dev/null | grep -q "$target_user"; then
                    if [ "$ACTION" == "netperm_on" ]; then
                        if grant_net_access "$pool_name" "$target_user"; then
                            echo -e "    ${C_YELLOW}🔧 $target_user: разрешено менять сетевые адаптеры (VLAN/мосты) только внутри своего стенда.${C_NC}"
                        else
                            echo -e "    ${C_RED}✖ $target_user: пул $pool_name пуст, права не выданы.${C_NC}"
                        fi
                    else
                        revoke_net_access "$pool_name" "$target_user"
                        echo -e "    ${C_GREEN}🔒 $target_user: право менять сетевые адаптеры отозвано.${C_NC}"
                    fi
                fi
                continue
            fi
            if [[ "$ACTION" == "rbperm_on" || "$ACTION" == "rbperm_off" ]]; then
                local mod_lower=$(echo "$MOD_TYPE" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
                local target_user="${mod_lower}-s${s}@pve"

                if pveum user list 2>/dev/null | grep -q "$target_user"; then
                    if [ "$ACTION" == "rbperm_on" ]; then
                        if grant_rb_access "$pool_name" "$target_user"; then
                            echo -e "    ${C_YELLOW}⏪ $target_user: разрешён откат своих ВМ к снапшотам (создавать и удалять снапшоты нельзя).${C_NC}"
                            local rb_vid rb_extra
                            for rb_vid in $(pvesh get /pools/$pool_name --output-format json 2>/dev/null | grep -Po '"vmid":\K\d+'); do
                                snap_exists "$rb_vid" "Day0" || echo -e "      ${C_RED}✖ у ВМ $rb_vid нет снапшота Day0 — откатываться не к чему.${C_NC}"
                                rb_extra=$(pvesh get "/nodes/$NODE/qemu/$rb_vid/snapshot" --output-format json 2>/dev/null | jq -r '[.[] | select(.name != "current" and .name != "Day0") | .name] | join(", ")' 2>/dev/null)
                                [ -n "$rb_extra" ] && echo -e "      ${C_YELLOW}⚠ у ВМ $rb_vid есть и другие снапшоты ($rb_extra): права привязаны к ВМ, а не к имени снапшота — участник сможет откатиться и к ним.${C_NC}"
                            done
                        else
                            echo -e "    ${C_RED}✖ $target_user: не удалось создать роль или выдать право (см. pveum role list).${C_NC}"
                        fi
                    else
                        revoke_rb_access "$pool_name" "$target_user"
                        echo -e "    ${C_GREEN}🔒 $target_user: право отката отозвано.${C_NC}"
                    fi
                fi
                continue
            fi
            if [[ "$ACTION" == "lock" || "$ACTION" == "unlock" ]]; then
                local mod_lower=$(echo "$MOD_TYPE" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
                local target_user="${mod_lower}-s${s}@pve"

                if pveum user list 2>/dev/null | grep -q "$target_user"; then
                    if [ "$ACTION" == "lock" ]; then
                        pveum user modify "$target_user" --enable 0 >/dev/null 2>&1
                        echo -e "    ${C_RED}🔒 Доступ для $target_user ЗАКРЫТ.${C_NC}"
                    else
                        pveum user modify "$target_user" --enable 1 >/dev/null 2>&1
                        echo -e "    ${C_GREEN}🔓 Доступ для $target_user ОТКРЫТ.${C_NC}"
                    fi
                fi
                continue
            fi
            if [ "$ACTION" == "resources" ]; then
                local rvid rname
                echo -e "  Стенд $s ($pool_name):"
                for rvid in $(pvesh get /pools/$pool_name --output-format json 2>/dev/null | grep -Po '"vmid":\K\d+' | sort -n); do
                    rname=$(qm config "$rvid" 2>/dev/null | awk '/^name:/{print $2; exit}')
                    [ -z "$(res_for_role "$(label_role "$rname")")" ] && continue
                    apply_resources "$rvid" "$(label_role "$rname")"
                done
                continue
            fi
            if [ "$ACTION" == "iso" ]; then
                local ivid iname irole ispec2 irc
                ispec2=$(iso_spec)
                echo -e "  Стенд $s ($pool_name):"
                for ivid in $(pvesh get /pools/$pool_name --output-format json 2>/dev/null | grep -Po '"vmid":\K\d+' | sort -n); do
                    iname=$(qm config "$ivid" 2>/dev/null | awk '/^name:/{print $2; exit}')
                    irole=$(label_role "$iname")
                    [[ " ${ispec2#*|} " == *" $irole "* ]] || continue
                    attach_iso "$ivid" "${ispec2%%|*}"; irc=$?
                    if [ "$irc" -eq 0 ]; then
                        if qm status "$ivid" 2>/dev/null | grep -q running && ! qm config "$ivid" --current 1 2>/dev/null | grep -q "^ide2: ${ISO_ATTACHED_VOL},"; then
                            echo -e "    ✔ $iname ($ivid): $ISO_ATTACHED_VOL — подключится после выключения и включения машины"
                        else
                            echo -e "    ✔ $iname ($ivid): подключён $ISO_ATTACHED_VOL"
                        fi
                        ISO_DONE=$(( ${ISO_DONE:-0} + 1 ))
                    else
                        ISO_FAIL=$(( ${ISO_FAIL:-0} + 1 ))
                    fi
                done
                continue
            fi
            if [ "$ACTION" == "space" ]; then
                local su sd sc
                read -r su sd sc < <(pool_usage "$pool_name")
                printf "    Стенд %-4s %-14s ВМ: %-3s занято %8s ГБ   (объявлено %s ГБ)\n" "$s" "$pool_name" "$sc" "$(gb "$su")" "$(gb "$sd")"
                pool_check_single "$pool_name" | sed 's/^/      /' 
                SPACE_TOTAL=$(( ${SPACE_TOTAL:-0} + su ))
                continue
            fi
            local vmids
            info=$(pool_info "$pool_name") || { failed=1; continue; }
            vmids=$(jq -r '.members[] | select(.type == "qemu") | .vmid' <<< "$info") || { failed=1; continue; }
            owner=$(jq -r '.comment // ""' <<< "$info") || { failed=1; continue; }

            if [ "$ACTION" = destroy ]; then
                destroy_stand "$s" "$pool_name" "$info" "$owner" || failed=1
                continue
            fi
            if [ "$ACTION" = start ]; then
                if read_stand_owner "$owner"; then
                    if [ "$STAND_NODE" != "$NODE" ] ||
                        ! stand_network verify "$STAND_BASE" "$owner" ||
                        ! stand_vms_ready "$s" "$info"; then
                        echo "✖ $pool_name: стенд не готов к запуску на этом узле. Повторите развёртывание." >&2
                        failed=1; continue
                    fi
                    case "$MOD_TYPE" in
                        REG_*|MOD_*|GOLD_*) ensure_ovs_flows "$STAND_BASE" || { failed=1; continue; } ;;
                    esac
                elif [[ "$MOD_TYPE" == REG_* || "$MOD_TYPE" == MOD_* || "$MOD_TYPE" == GOLD_* ]]; then
                    echo "⚠ $pool_name: старый стенд. Проверьте правила LACP вручную."
                fi
                echo -e "${C_GREEN}Каскадный запуск стенда $s (τ = ${tau_delay} сек)...${C_NC}"
            fi

            for vmid in $vmids; do
                qm config $vmid | grep -q "template: 1" && continue
                if [ "$ACTION" == "addrchk" ]; then
                    qm status $vmid 2>/dev/null | grep -q running && collect_wan_vm "$s" "$vmid"
                    continue
                fi
                case $ACTION in
                    start)
                        qm start "$vmid" || { failed=1; continue; }
                        collect_wan_vm "$s" "$vmid"
                        sleep $tau_delay
                        ;;
                    stop)
                        qm stop $vmid >/dev/null 2>&1
                        ;;
                    shutdown)
                        qm shutdown $vmid --timeout 15 --forceStop 1 >/dev/null 2>&1 &
                        ;;
                    reboot)
                        qm reboot $vmid >/dev/null 2>&1 &
                        ;;
                    snapshot|rollback|delsnap)
                        snap_op "$ACTION" "$vmid" "$SNAP_NAME"
                        ;;
                esac
            done

        done
    done

    if [ "$ACTION" == "resources" ]; then
        echo -e "\n${C_YELLOW}Включённые машины получат новые значения после выключения и включения (не перезагрузки изнутри гостя).${C_NC}"
        echo -e "${C_YELLOW}Откат к снапшоту, сделанному раньше, вернёт прежние память и ядра.${C_NC}"
    fi

    if [ "$ACTION" == "iso" ]; then
        echo -e "\nИтог: диск подключён к ${ISO_DONE:-0} ВМ, не подключён — ${ISO_FAIL:-0}."
        echo -e "${C_YELLOW}Снапшоты, сделанные раньше (в том числе Day0), хранят прежнюю настройку: после отката к ним диск придётся подключить снова.${C_NC}"
    fi

    if [ "$ACTION" == "space" ]; then
        echo -e "\n  Всего по выбранным стендам: $(gb "${SPACE_TOTAL:-0}") ГБ"
        echo -e "  (ZFS — вместе со снапшотами; LVM-thin — без снапшотов)\n"
        storage_table
    fi

    case "$ACTION" in snapshot|rollback|delsnap)
        echo -e "\nИтог по '$SNAP_NAME': выполнено $SNAP_OK, пропущено $SNAP_SKIP, ошибок $SNAP_FAIL."
        [ "$SNAP_FAIL" -gt 0 ] && echo -e "${C_YELLOW}Подробности по ошибке одной машины: qm listsnapshot <vmid>  и  qm $ACTION <vmid> $SNAP_NAME${C_NC}"
        ;;
    esac

    if [ "$ACTION" == "start" ] && [ "$ADDR_CHECK" = "1" ]; then
        check_wan_addresses 1
    elif [ "$ACTION" == "addrchk" ]; then
        check_wan_addresses "${ADDR_REPAIR:-0}"
    fi
    return "$failed"
}

# Настройка APT на одной ВМ одним вызовом гостевого агента (раньше — пять вызовов подряд).
# cache — направить на кэшер; direct — вернуть прямое обращение к зеркалу. Комментированные строки sources не меняются.
apt_job() {
    local vid=$1 mode=$2 cmd
    case "$mode" in
        cache)
            if [ "$APT_MODE" = "proxy" ]; then
                cmd="echo 'Acquire::http::Proxy \"http://${PROXY_IP}:${APT_CACHE_PORT}\";' > /etc/apt/apt.conf.d/99spetsnaz-proxy"
            else
                cmd="rm -f /etc/apt/apt.conf.d/99spetsnaz-proxy /etc/apt/sources.list.d/alt.list /etc/apt/sources.list.d/spetsnaz.list; sed -i -e '/x86_64-i586/s/^rpm/#rpm/' -e '/^[[:space:]]*#/!s|http://${APT_MIRROR_HOST}|http://${PROXY_IP}:${APT_CACHE_PORT}|g' /etc/apt/sources.list.d/yandex.list"
            fi ;;
        direct)
            cmd="rm -f /etc/apt/apt.conf.d/99spetsnaz-proxy; sed -i '/^[[:space:]]*#/!s|http://[0-9.]*:${APT_CACHE_PORT}/|http://${APT_MIRROR_HOST}/|g' /etc/apt/sources.list.d/yandex.list" ;;
    esac
    # Чистим кэш пакетов и СПИСКИ пакетов (только файлы, каталог lists/partial должен остаться): иначе после смены источника остаются индексы с прежнего источника
    # и apt-get update даёт «Size mismatch / Hash Sum mismatch»
    cmd="$cmd; apt-get clean; find /var/lib/apt/lists -type f -delete; mkdir -p /var/lib/apt/lists/partial"
    qm guest exec "$vid" -- bash -c "$cmd" >/dev/null 2>&1
}

post_flight_patch() {
    local stands_list=($(expand_ranges "$@"))

    local IP_OFFSET=10
    local SECRET_TARGET="ISP"
    local APT_TARGETS=""

    case "$MOD_TYPE" in
        GOLD_*)
            # Золотой эталон: топология зависит от образа (7 ВМ как в DEMO или 14 ВМ как в REG_B) — берём роли обеих
            IP_OFFSET=0;   SECRET_TARGET="ISP|GW-CORE"; APT_TARGETS="ISP|HQ-SRV|HQ-CLI|BR-SRV|GW-CORE|COD-SRV-1|COD-SRV-2|PUB|COD-ADMIN|DATA" ;;
        DEMO_1|DEMO_T1)
            IP_OFFSET=10;  SECRET_TARGET="ISP";     APT_TARGETS="ISP|HQ-SRV|HQ-CLI|BR-SRV" ;;
        DEMO_2|DEMO_T2)
            IP_OFFSET=50;  SECRET_TARGET="ISP";     APT_TARGETS="ISP|HQ-SRV|HQ-CLI|BR-SRV" ;;
        DEMO_3|DEMO_T3|DEMO_GOLD)
            IP_OFFSET=70;  SECRET_TARGET="ISP";     APT_TARGETS="ISP|HQ-SRV|HQ-CLI|BR-SRV" ;;
        REG_B|MOD_B)
            IP_OFFSET=100; SECRET_TARGET="GW-CORE"; APT_TARGETS="GW-CORE|COD-SRV-1|COD-SRV-2|PUB|COD-ADMIN|DATA" ;;
        REG_D|MOD_D)
            IP_OFFSET=120; SECRET_TARGET="GW-CORE"; APT_TARGETS="GW-CORE|COD-SRV-1|COD-SRV-2|PUB|COD-ADMIN|DATA" ;;
        REG_A|MOD_A)
            IP_OFFSET=140; SECRET_TARGET="GW-CORE"; APT_TARGETS="GW-CORE|COD-SRV-1|COD-SRV-2|PUB|COD-ADMIN|DATA" ;;
        *)
            IP_OFFSET=200; SECRET_TARGET="ISP";     APT_TARGETS="ISP|HQ-SRV|HQ-CLI|BR-SRV" ;;
    esac

    for s in "${stands_list[@]}"; do
        echo -e "${C_GREEN}Патчинг стенда $s (Модуль $MOD_TYPE)...${C_NC}"

        local pool_name="${MOD_TYPE}_S${s}"
        local vmids=$(pvesh get /pools/$pool_name --output-format json 2>/dev/null | grep -Po '"vmid":\K\d+')

        if [ -z "$vmids" ]; then
            echo -e "    ${C_YELLOW}⚠ Пул $pool_name пуст или не найден. Пропуск стенда.${C_NC}"
            continue
        fi

        local patched_vms=0
        for vid in $vmids; do
            if ! qm status $vid 2>/dev/null | grep -q "running"; then continue; fi

            local vm_name=$(qm config $vid | awk '/^name:/ {print $2}')

            if [[ ! "$vm_name" =~ ^($APT_TARGETS)$ ]]; then
                continue
            fi
            patched_vms=$((patched_vms + 1))

            if ! qm agent $vid ping >/dev/null 2>&1; then
                qm guest exec $vid -- bash -c "grep -q 'QEMU_GA_ARGS' /etc/sysconfig/qemu-ga || echo 'QEMU_GA_ARGS=\"\"' >> /etc/sysconfig/qemu-ga; systemctl restart qemu-guest-agent" >/dev/null 2>&1
                sleep 1
            fi

            if [ "${APT_DIRECT:-0}" = "1" ]; then
                echo -e "    [+] APT: возвращаю прямое обращение к $APT_MIRROR_HOST для ВМ $vid ($vm_name)..."
                apt_job "$vid" direct &
            elif [ -n "$PROXY_IP" ]; then
                if [ "$APT_MODE" = "proxy" ]; then
                    echo -e "    [+] Настройка APT (HTTP-прокси $PROXY_IP:$APT_CACHE_PORT) для ВМ $vid ($vm_name)..."
                else
                    echo -e "    [+] Настройка APT (зеркало $PROXY_IP:$APT_CACHE_PORT) для ВМ $vid ($vm_name)..."
                fi
                apt_job "$vid" cache &
            fi

            if [ "${APT_DIRECT:-0}" != "1" ] && [ "$SECRET_MODE" -eq 1 ] && [[ "$vm_name" =~ ^($SECRET_TARGET)$ ]]; then
                local VM_IP="${EXPERT_SUBNET}.$((IP_OFFSET + s))"
                echo -e "    [+] Экспертный доступ: вшиваем статический IP $VM_IP для $vm_name ($vid)..."

                qm guest exec $vid -- bash -c "echo -e 'BOOTPROTO=static\nTYPE=eth\nCONFIG_IPV4=yes' > /etc/net/ifaces/${EXPERT_IFACE}/options"
                qm guest exec $vid -- bash -c "echo '${VM_IP}/24' > /etc/net/ifaces/${EXPERT_IFACE}/ipv4address"
                qm guest exec $vid -- bash -c "echo 'default via ${EXPERT_GW}' > /etc/net/ifaces/${EXPERT_IFACE}/ipv4route"
                qm guest exec $vid -- bash -c "echo 'nameserver ${EXPERT_DNS}' > /etc/net/ifaces/${EXPERT_IFACE}/resolv.conf"
                qm guest exec $vid -- systemctl restart network >/dev/null 2>&1 &
            fi
        done
        wait
        if [ "${APT_DIRECT:-0}" = "1" ] && [ "$patched_vms" -gt 0 ]; then
            echo -e "    ${C_GREEN}✔ Кэшер отключён: ВМ стенда $s обращаются к $APT_MIRROR_HOST напрямую (скорость обновления ниже, чем через кэшер).${C_NC}"
        elif [ -n "$PROXY_IP" ] && [ "$patched_vms" -gt 0 ]; then
            echo -e "    ${C_YELLOW}Если на ВМ при apt-get update появится «Size mismatch»: Утилиты → 🆘 ПАМЯТКА (apt-get clean → очистка списков → при необходимости очистка кэша кэшера).${C_NC}"
        fi
        if [ "$patched_vms" -eq 0 ]; then
            echo -e "    ${C_YELLOW}⚠ В стенде $s не найдено запущенных ВМ из списка патча ($APT_TARGETS). Включите машины стенда и повторите (в кластере запускайте патч на том узле, где стенд развёрнут).${C_NC}"
        fi
    done
}

rotate_passwords() {
    local stands_list=($(expand_ranges "$@"))
    if [ ! -f "$ROT_FILE" ]; then
        echo "Стенд,Логин,Новый Пароль" > "$ROT_FILE"
        chmod 600 "$ROT_FILE" 2>/dev/null
    fi

    local mod_lower=$(echo "$MOD_TYPE" | tr '[:upper:]' '[:lower:]' | tr '_' '-')

    for s in "${stands_list[@]}"; do
        local USER="${mod_lower}-s${s}@pve"

        if pveum user list 2>/dev/null | grep -q "$USER"; then
            local NEW_PASS=$(gen_password 8)
            pvesh set /access/password --userid "$USER" --password "$NEW_PASS" >/dev/null 2>&1
            echo -e "    - Стенд $s: ${C_GREEN}Пароль для $USER успешно обновлен.${C_NC}"
            echo "Стенд $s,$USER,$NEW_PASS" >> "$ROT_FILE"
        else
            echo -e "    - Стенд $s: ${C_RED}Пользователь $USER не найден! Пропуск.${C_NC}"
        fi
    done

    echo -e "\n${C_GREEN}✔ Ротация завершена! Новые доступы лежат в: $ROT_FILE${C_NC}"
    cat "$ROT_FILE" | column -t -s ','
}

# ===================== Место на хранилищах =====================
SIZE_CACHE="${SIZE_CACHE:-.spetsnaz-sizes}"   # кэш оценок по архивам: путь|mtime|размер|объявлено|данные
SPACE_WARN_PCT="${SPACE_WARN_PCT:-80}"        # предупреждать, если после деплоя хранилище заполнено больше, чем на N %
[[ "$SPACE_WARN_PCT" =~ ^[0-9]+$ ]] || SPACE_WARN_PCT=80

gb() { awk -v b="${1:-0}" 'BEGIN{printf "%.1f", b/1073741824}'; }

# 32G, 512M, 4M, 1T, байты → байты
size_to_bytes() {
    [[ "$1" =~ ^([0-9.]+)([KMGT]?)$ ]] || { echo 0; return; }
    awk -v n="${BASH_REMATCH[1]}" -v u="${BASH_REMATCH[2]}" 'BEGIN{m=1; if(u=="K")m=1024; if(u=="M")m=1048576; if(u=="G")m=1073741824; if(u=="T")m=1099511627776; printf "%.0f", n*m}'
}

# Объявленный объём дисков по заголовку VMA (таблица устройств, числа big-endian)
vma_header_bytes() {
    perl -e 'local $/; my $d = <STDIN>; exit 1 unless defined $d && substr($d, 0, 4) eq "VMA\0";
        my $t = 0; for my $i (1 .. 255) { my $o = 4096 + $i * 32; last if $o + 16 > length $d;
        my ($hi, $lo) = unpack("NN", substr($d, $o + 8, 8)); $t += $hi * 4294967296 + $lo; }
        printf "%.0f", $t;' 2>/dev/null
}

# Запасной способ: строки size= из конфига ВМ внутри архива
vma_conf_bytes() {
    tr -c '[:print:]\n' '\n' | grep -E '^(scsi|sata|ide|virtio|efidisk|tpmstate)[0-9]+: ' | grep -v -e 'media=cdrom' -e 'backup=0' \
        | grep -oP '(^|,)size=\K[0-9.]+[KMGT]?' | while read -r sz; do size_to_bytes "$sz"; echo; done \
        | awk '{t+=$1} END{printf "%.0f", t}'
}

# "объявлено данные" (байты) для архива; результат кэшируется по пути, времени и размеру файла
archive_sizes() {
    local f=$1 key line decl data fs
    fs=$(stat -c %s "$f" 2>/dev/null)
    key="$(readlink -f "$f")|$(stat -c %Y "$f" 2>/dev/null)|$fs"
    line=$(grep -F "$key|" "$SIZE_CACHE" 2>/dev/null | tail -n 1)
    if [ -n "$line" ]; then
        awk -F'|' '{print $4, $5}' <<< "$line"; return
    fi
    echo -e "    … считаю объём $(basename "$f") (архив $(gb "$fs") ГБ, результат запоминается)" >&2
    decl=$(zstdcat "$f" 2>/dev/null | head -c 12288 | vma_header_bytes)
    if [ -z "$decl" ] || [ "$decl" = "0" ]; then
        decl=$(zstdcat "$f" 2>/dev/null | head -c 1048576 | vma_conf_bytes)
    fi
    data=$(zstdcat "$f" 2>/dev/null | wc -c)
    decl=${decl:-0}; data=${data:-0}
    echo "$key|$decl|$data" >> "$SIZE_CACHE" 2>/dev/null
    echo "$decl $data"
}

# Оценка одного стенда текущего модуля: "объявлено данные найдено_образов всего_ролей"
stand_estimate() {
    local decl=0 data=0 found=0 total=0 off name nets f d r
    while IFS='#' read -r off name nets; do
        [ -z "$name" ] && continue
        total=$((total + 1))
        f=$(find_image "$name" "$(role_label "$name")" 2>/dev/null) || continue
        [ -f "$f" ] || continue
        read -r d r < <(archive_sizes "$f")
        decl=$((decl + d)); data=$((data + r)); found=$((found + 1))
    done < <(stand_vm_list 0 1)
    echo "$decl $data $found $total"
}

declare -A STORAGE_CFG
storage_cfg() {
    [ -n "${STORAGE_CFG[$1]}" ] || STORAGE_CFG[$1]=$(pvesh get "/storage/$1" --output-format json 2>/dev/null)
    echo "${STORAGE_CFG[$1]}"
}

# Тонкое выделение: место занимают только записанные данные (1) или весь объём диска сразу (0)
storage_is_thin() {
    case "$2" in
        lvmthin|rbd|btrfs|dir|nfs|cifs|glusterfs|cephfs) echo 1 ;;
        zfspool) [ "$(storage_cfg "$1" | jq -r '.sparse // 0' 2>/dev/null)" = "1" ] && echo 1 || echo 0 ;;
        *) echo 0 ;;
    esac
}

# Хранилища дисков ВМ на этом узле: id|тип|тонкое|свободно|всего|занято_%
storage_list() {
    local id type avail total pct
    while IFS=$'\t' read -r id type avail total; do
        [ -z "$id" ] && continue
        avail=${avail%.*}; total=${total%.*}; pct=0
        [ "${total:-0}" -gt 0 ] && pct=$(( (total - avail) * 100 / total ))
        echo "$id|$type|$(storage_is_thin "$id" "$type")|$avail|$total|$pct"
    done < <(pvesh get "/nodes/$NODE/storage" --content images --output-format json 2>/dev/null \
        | jq -r '.[] | select((.active // 0) == 1 and (.enabled // 1) == 1) | [.storage, .type, (.avail // 0), (.total // 0)] | @tsv' 2>/dev/null)
}

# Что лежит под каталогом: zfs:<пул> | vg:<группа томов> | dev:<устройство>
path_backing() {
    local src fstype vg
    read -r src fstype < <(df --output=source,fstype "$1" 2>/dev/null | tail -n 1)
    [ -z "$src" ] && return
    if [ "$fstype" = "zfs" ]; then echo "zfs:${src%%/*}"; return; fi
    vg=$(LC_ALL=C lvs --noheadings -o vg_name "$src" 2>/dev/null | tr -d ' ')
    [ -n "$vg" ] && echo "vg:$vg" || echo "dev:$src"
}

storage_backing() {
    local j type
    j=$(storage_cfg "$1"); type=$(jq -r '.type // empty' <<< "$j" 2>/dev/null)
    case "$type" in
        zfspool)     echo "zfs:$(jq -r '.pool' <<< "$j" | cut -d/ -f1)" ;;
        lvmthin|lvm) echo "vg:$(jq -r '.vgname' <<< "$j")" ;;
        dir|btrfs)   path_backing "$(jq -r '.path' <<< "$j")" ;;
    esac
}

# Хранилища с отметкой, хватит ли места на N стендов: id|тип|тонкое|свободно|всего|занято_%|нужно|хватит(1/0)
storage_fit_list() {
    local n=$1 decl data found total id type thin avail tot pct need
    read -r decl data found total < <(stand_estimate)
    storage_list | while IFS='|' read -r id type thin avail tot pct; do
        if [ "$thin" = "1" ]; then need=$((data * n)); else need=$((decl * n)); fi
        echo "$id|$type|$thin|$avail|$tot|$pct|$need|$([ "$need" -le "$avail" ] && echo 1 || echo 0)"
    done
}

# Проверка перед деплоем N стендов на TARGET_STORAGE.
# Код: 0 — места хватает; 1 — хватает, но есть предупреждения; 2 — не хватает (деплой не выполняется)
space_check() {
    local n=$1 decl data found total rc=0 line id type thin avail tot pct need after kind
    read -r decl data found total < <(stand_estimate)
    echo -e "\nОценка места: $MOD_TYPE, стендов: $n (образов найдено: $found из $total)"
    if [ "$found" -eq 0 ]; then
        echo -e "${C_YELLOW}⚠ Образы не найдены — оценить место нельзя.${C_NC}"; return 0
    fi
    echo "  Один стенд: данных ~$(gb "$data") ГБ, объявленный объём дисков $(gb "$decl") ГБ"

    line=$(storage_list | grep "^${TARGET_STORAGE}|")
    if [ -z "$line" ]; then
        echo -e "${C_RED}✖ Хранилище '$TARGET_STORAGE' не найдено, выключено или не принимает диски ВМ.${C_NC}"
        rc=2
    else
        IFS='|' read -r id type thin avail tot pct <<< "$line"
        if [ "$thin" = "1" ]; then need=$((data * n)); kind="тонкое"; else need=$((decl * n)); kind="толстое"; fi
        echo "  Хранилище $id ($type, $kind): свободно $(gb "$avail") из $(gb "$tot") ГБ (занято $pct%)"
        echo "  Нужно на развёртывание: ~$(gb "$need") ГБ"
        if [ "$thin" != "1" ]; then
            echo -e "${C_YELLOW}  ⚠ Хранилище без тонкого выделения: каждая ВМ сразу занимает полный объём дисков."
            echo -e "    На тонком хранилище эти стенды заняли бы ~$(gb $((data * n))) ГБ.${C_NC}"
            [ "$type" = "zfspool" ] && echo -e "${C_YELLOW}    Для ZFS тонкое выделение включается в свойствах хранилища: «Thin provision» (sparse 1).${C_NC}"
            rc=1
        elif [ $((decl * n)) -gt "$avail" ]; then
            echo "  При заполнении дисков до объявленного объёма ($(gb $((decl * n))) ГБ) места не хватит —"
            echo "  следите за свободным местом (пункт «Место, занятое стендами»)."
        fi
        if [ "$need" -gt "$avail" ]; then
            echo -e "${C_RED}✖ Места не хватает: нужно ~$(gb "$need") ГБ, свободно $(gb "$avail") ГБ.${C_NC}"
            rc=2
        elif [ "${tot:-0}" -gt 0 ]; then
            after=$(( (tot - avail + need) * 100 / tot ))
            if [ "$after" -gt "$SPACE_WARN_PCT" ]; then
                echo -e "${C_YELLOW}  ⚠ После развёртывания хранилище будет заполнено на ~$after% (больше $SPACE_WARN_PCT%).${C_NC}"
                [ "$type" = "zfspool" ] && echo -e "${C_YELLOW}    ZFS при заполнении выше 80% заметно замедляется.${C_NC}"
                [ "$rc" -lt 1 ] && rc=1
            fi
        fi
        local img_b st_b
        img_b=$(path_backing "$IMG_DIR"); st_b=$(storage_backing "$id")
        if [ -n "$img_b" ] && [ "$img_b" = "$st_b" ]; then
            echo -e "${C_YELLOW}  ⚠ Папка с образами ($IMG_DIR) и диски ВМ на одном ${img_b%%:*}-разделе '${img_b#*:}': образы занимают то же место.${C_NC}"
            [ "$rc" -lt 1 ] && rc=1
        fi
    fi

    if [ "$rc" -eq 2 ]; then
        local fits
        fits=$(storage_fit_list "$n" | awk -F'|' -v cur="$TARGET_STORAGE" '$1 != cur && $8 == 1' | sort -t'|' -k4,4nr)
        if [ -n "$fits" ]; then
            echo "  Подходящие хранилища:"
            while IFS='|' read -r id type thin avail tot pct need _; do
                after=0; [ "${tot:-0}" -gt 0 ] && after=$(( (tot - avail + need) * 100 / tot ))
                printf "    %-16s %-8s %-7s свободно %8s ГБ, после деплоя занято ~%s%%\n" "$id" "$type" "$([ "$thin" = 1 ] && echo тонкое || echo толстое)" "$(gb "$avail")" "$after"
            done <<< "$fits"
        else
            echo "  Ни на одном хранилище места не хватает: удалите ненужные стенды/ВМ или уменьшите число стендов."
        fi
    fi
    return $rc
}

# Диски ВМ (без CD-ROM): строки "volid размер_из_конфига"
vm_volumes() {
    qm config "$1" 2>/dev/null | grep -E '^(scsi|sata|ide|virtio|efidisk|tpmstate|unused)[0-9]+: ' \
        | grep -v 'media=cdrom' | sed -E 's/^[a-z]+[0-9]+: //' \
        | awk -F, '{v=$1; s=""; for(i=2;i<=NF;i++) if ($i ~ /^size=/) s=substr($i,6); if (v ~ /:/ && v !~ /^\/dev\//) print v, s}'
}

# Фактически занятое томом место (байты, вместе со снапшотами для ZFS); пусто — неизвестно
volume_used_bytes() {
    local volid=$1 sid=${1%%:*} vname=${1#*:} j type p
    j=$(storage_cfg "$sid"); type=$(jq -r '.type // empty' <<< "$j" 2>/dev/null)
    case "$type" in
        zfspool) zfs get -Hp -o value used "$(jq -r '.pool' <<< "$j")/$vname" 2>/dev/null ;;
        lvmthin) LC_ALL=C lvs --noheadings --units b --nosuffix -o lv_size,data_percent "$(jq -r '.vgname' <<< "$j")/$vname" 2>/dev/null | awk '{printf "%.0f", $1 * $2 / 100}' ;;
        lvm)     LC_ALL=C lvs --noheadings --units b --nosuffix -o lv_size "$(jq -r '.vgname' <<< "$j")/$vname" 2>/dev/null | awk '{printf "%.0f", $1}' ;;
        *)       p=$(pvesm path "$volid" 2>/dev/null); [ -f "$p" ] && du -B1 "$p" 2>/dev/null | awk '{print $1}' ;;
    esac
}

# "занято объявлено" (байты) по всем дискам ВМ
vm_usage() {
    local used=0 decl=0 volid sz u
    while read -r volid sz; do
        [ -z "$volid" ] && continue
        decl=$((decl + $(size_to_bytes "$sz")))
        u=$(volume_used_bytes "$volid"); [[ "$u" =~ ^[0-9]+$ ]] && used=$((used + u))
    done < <(vm_volumes "$1")
    echo "$used $decl"
}

# "занято объявлено число_ВМ" по пулу стенда
pool_usage() {
    local used=0 decl=0 cnt=0 vid u d
    for vid in $(pvesh get "/pools/$1" --output-format json 2>/dev/null | grep -Po '"vmid":\K\d+'); do
        read -r u d < <(vm_usage "$vid")
        used=$((used + u)); decl=$((decl + d)); cnt=$((cnt + 1))
    done
    echo "$used $decl $cnt"
}

storage_table() {
    local id type thin avail tot pct
    echo "Хранилища дисков ВМ на узле $NODE:"
    storage_list | while IFS='|' read -r id type thin avail tot pct; do
        printf "  %-16s %-8s %-7s свободно %8s из %8s ГБ (занято %s%%)%s\n" "$id" "$type" "$([ "$thin" = 1 ] && echo тонкое || echo толстое)" \
            "$(gb "$avail")" "$(gb "$tot")" "$pct" "$([ "$pct" -ge 90 ] && echo '  ⚠ почти заполнено')"
    done
}

# ===================== Сохранение стенда как набора образов =====================
# EXPORT_ROLE — сохранить только одну машину (роль); остальные архивы папки не трогаются.
# Каждая ВМ стенда сохраняется vzdump (режим stop) в $IMG_DIR/<папка>/<РОЛЬ>.vma.zst.
# Сначала всё пишется во временную папку; прежний набор переносится в $IMG_DIR/_archive/ только после успеха.
export_stand() {
    local s=$1 pool="${MOD_TYPE}_S$1" target="${EXPORT_TARGET:-$MOD_TYPE}"
    local dir="$IMG_DIR/$target" tmp vmids vid name names=() bad=0 need=0 u d free est
    vmids=$(pvesh get "/pools/$pool" --output-format json 2>/dev/null | grep -Po '"vmid":\K\d+' | sort -n)
    if [ -z "$vmids" ]; then
        echo -e "${C_RED}✖ Стенд $s ($pool) не найден или пуст.${C_NC}"; return 1
    fi
    pool_check_single "$pool" || return 1
    if [ -n "$EXPORT_ROLE" ]; then
        local sel="" rlabel
        rlabel=$(role_label "$EXPORT_ROLE")
        for vid in $vmids; do
            name=$(qm config "$vid" 2>/dev/null | awk '/^name:/{print $2; exit}')
            if [ "$name" = "$rlabel" ] || [ "$name" = "$EXPORT_ROLE" ]; then sel="$vid"; break; fi
        done
        if [ -z "$sel" ]; then
            echo -e "${C_RED}✖ В стенде $s нет машины $rlabel.${C_NC}"; return 1
        fi
        vmids=$sel
    fi
    for vid in $vmids; do
        name=$(qm config "$vid" 2>/dev/null | awk '/^name:/{print $2; exit}')
        if [ -z "$name" ]; then echo -e "${C_RED}✖ У ВМ $vid нет имени — образ назвать нечем.${C_NC}"; bad=1; fi
        if printf '%s\n' "${names[@]}" | grep -qx "$name"; then echo -e "${C_RED}✖ Имя $name повторяется в стенде — образы перезапишут друг друга.${C_NC}"; bad=1; fi
        names+=("$name")
        read -r u d < <(vm_usage "$vid"); need=$((need + u))
    done
    [ "$bad" -eq 1 ] && return 1

    mkdir -p "$dir" || { echo -e "${C_RED}✖ Не удалось создать папку $dir.${C_NC}"; return 1; }
    free=$(df -B1 --output=avail "$dir" 2>/dev/null | tail -n 1 | tr -d ' ')
    est=$((need / 2))
    echo "Стенд $s ($pool)${EXPORT_ROLE:+, машина $(role_label "$EXPORT_ROLE")} → $dir"
    [ -n "$EXPORT_ZSTD_LEVEL" ] && echo "  Уровень сжатия zstd: $EXPORT_ZSTD_LEVEL"
    echo "  ВМ: $(echo $vmids | wc -w), данных на дисках ~$(gb "$need") ГБ; архивы обычно в 2–4 раза меньше (~$(gb "$est") ГБ и меньше)."
    echo "  Свободно в папке образов: $(gb "${free:-0}") ГБ"
    if [ -n "$free" ] && [ "$free" -lt "$est" ] && [ "${SPACE_FORCE:-0}" != "1" ]; then
        echo -e "${C_RED}✖ Места для архивов почти наверняка не хватит. Освободите место в $IMG_DIR.${C_NC}"; return 2
    elif [ -n "$free" ] && [ "$free" -lt "$need" ]; then
        echo -e "${C_YELLOW}⚠ Места может не хватить, если данные плохо сжимаются.${C_NC}"
    fi

    tmp="$IMG_DIR/_export-${target}-$$"; mkdir -p "$tmp" || return 1
    # vzdump пишет поток VMA в stdout, сжатие — zstd с заданным уровнем (vzdump сам уровень не настраивает)
    local lvl="${EXPORT_ZSTD_LEVEL:-3}" zopt=()
    [[ "$lvl" =~ ^[0-9]+$ ]] && [ "$lvl" -ge 1 ] && [ "$lvl" -le 19 ] || lvl=3
    zopt=(-q -T0 "-$lvl")
    [ "$lvl" -ge 10 ] && zopt+=(--long=27)
    local ok=0 fail=0 rc f t0=$SECONDS i=0
    for vid in $vmids; do
        name=${names[$i]}; i=$((i + 1))
        f="$tmp/$name.vma.zst"
        echo -e "  ▶ $name (ID $vid): сохраняю (ВМ будет остановлена на время копирования; сжатие zstd -$lvl)..."
        ( set -o pipefail; vzdump "$vid" --mode stop --stdout 2>"$tmp/$name.log" | zstd "${zopt[@]}" -o "$f" ); rc=$?
        if [ $rc -eq 0 ] && [ -s "$f" ]; then
            echo -e "    ${C_GREEN}✔ $name.vma.zst — $(gb "$(stat -c %s "$f")") ГБ${C_NC}"
            ok=$((ok + 1))
        else
            echo -e "    ${C_RED}✖ $name: $(grep -iE 'error|fail' "$tmp/$name.log" 2>/dev/null | tail -n 2 | tr '\n' ' ')${C_NC}"
            rm -f "$f"
            fail=$((fail + 1))
        fi
        rm -f "$tmp/$name.log"
    done
    rm -f "$tmp"/vzdump-qemu-* 2>/dev/null

    if [ "$fail" -gt 0 ]; then
        echo -e "\n${C_RED}✖ Сохранено $ok из $((ok + fail)). Прежний набор в $dir не тронут; удачные архивы оставлены в $tmp.${C_NC}"
        return 1
    fi
    local old n
    if [ -n "$EXPORT_ROLE" ]; then
        # одна машина: в архив уходят только образы этой роли (под обоими именами, как их ищет деплой)
        old=$(for n in "$EXPORT_ROLE" "$(role_label "$EXPORT_ROLE")"; do
                  find "$dir" -maxdepth 1 -type f \( -name "${n}${FILE_MASK}" -o -name "${n}-*${FILE_MASK}" -o -name "${n}_*${FILE_MASK}" -o -name "${n}.*${FILE_MASK}" \) 2>/dev/null
              done | sort -u)
    else
        old=$(find "$dir" -maxdepth 1 -type f -name "*${FILE_MASK}" 2>/dev/null)
    fi
    if [ -n "$old" ]; then
        local arch="$IMG_DIR/_archive/${target}-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$arch" && echo "$old" | while IFS= read -r f; do mv -f "$f" "$arch/"; done
        echo -e "  Прежн$([ -n "$EXPORT_ROLE" ] && echo 'ий образ' || echo 'ий набор образов') перенесён в $arch"
    fi
    mv -f "$tmp"/*"${FILE_MASK}" "$dir/" && rmdir "$tmp" 2>/dev/null
    if [ -n "$EXPORT_ROLE" ]; then
        echo -e "\n${C_GREEN}✔ Образ $(role_label "$EXPORT_ROLE") сохранён в $dir ($(( (SECONDS - t0) / 60 )) мин); остальные образы папки не изменены.${C_NC}"
    else
        echo -e "\n${C_GREEN}✔ Набор образов сохранён: $dir ($ok шт., $(( (SECONDS - t0) / 60 )) мин).${C_NC}"
    fi
    ls -l "$dir"/*"${FILE_MASK}" 2>/dev/null | awk '{printf "    %-28s %8.1f ГБ\n", $9, $5/1073741824}' | sed "s|$dir/||"
    echo "  Теперь этот набор разворачивается обычным деплоем модуля $target."
}

COMMAND=$1
shift
STANDS=("$@")

mkdir -p credentials
chmod 700 credentials 2>/dev/null

export MOD_SHORT=""
export ROTATION_NAME=""

case "$MOD_TYPE" in
    DEMO_1|DEMO_T1)                 MOD_SHORT="DE_1";  ROTATION_NAME="DE_1_Exam" ;;
    DEMO_2|DEMO_T2)                 MOD_SHORT="DE_2";  ROTATION_NAME="DE_2_Exam" ;;
    DEMO_3|DEMO_T3)                 MOD_SHORT="DE_3";  ROTATION_NAME="DE_3_Exam" ;;
    DEMO_GOLD)                      MOD_SHORT="DE_GOLD"; ROTATION_NAME="DE_GOLD_Exam" ;;

    REG_A|MOD_A)                    MOD_SHORT="REG_A"; ROTATION_NAME="Day_C1" ;;
    REG_B|MOD_B)                    MOD_SHORT="REG_B"; ROTATION_NAME="Day_C2" ;;
    REG_D|MOD_D)                    MOD_SHORT="REG_D"; ROTATION_NAME="Day_C3" ;;

    *)                              MOD_SHORT="$MOD_TYPE"; ROTATION_NAME="${MOD_TYPE}_Exam" ;;
esac

export CSV_FILE="credentials/deploy_${MOD_SHORT}.csv"
export ROT_FILE="credentials/${ROTATION_NAME}.csv"

# Один процесс на узел: защищает выбор ID и изменения сети от второго запуска оркестратора.
case "$COMMAND:${ACTION:-}" in
    deploy:*|redeploy:*|manage:destroy|manage:start)
        if [[ "$COMMAND" == deploy || "$COMMAND" == redeploy ]]; then
            if [[ ! "$WAN_BR" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,14}$ ]] || ! ip link show dev "$WAN_BR" >/dev/null 2>&1; then
                echo "✖ WAN-интерфейс '$WAN_BR' не найден на узле $NODE." >&2; exit 1
            fi
        fi
        if [[ ! "$MOD_TYPE" =~ ^(DEMO|REG|MOD|GOLD)_[A-Z0-9_]+$ ]]; then
            echo "✖ Недопустимое имя модуля." >&2; exit 1
        fi
        exec 9>/run/lock/spetsnaz-deploy.lock || exit 1
        flock -n 9 || { echo "✖ Другая операция со стендами уже выполняется." >&2; exit 1; }
        ;;
esac

case $COMMAND in
    deploy)
        [ ! -d "$IMG_DIR" ] && echo -e "${C_RED}✖ Ошибка: Директория $IMG_DIR не найдена!${C_NC}" && exit 1
        if [ ! -f "$CSV_FILE" ]; then
            (umask 077; printf 'Стенд,Логин,Пароль\n' > "$CSV_FILE") || exit 1
        fi

        echo -e "ИТ-СПЕЦНАЗ, версия скриптов: $SPETSNAZ_VERSION"
        IFS='|' read -r IMG_SRC_DIR IMG_SRC_DEPTH IMG_SRC_KIND <<< "$(resolve_img_dir)"
        case "$IMG_SRC_KIND" in
            exact)   echo -e "${C_GREEN}Начинаем компактный деплой ($MOD_TYPE). Образы: $IMG_SRC_DIR${C_NC}" ;;
            alias)   echo -e "${C_GREEN}Начинаем компактный деплой ($MOD_TYPE). Образы: $IMG_SRC_DIR${C_NC}"
                     echo -e "${C_YELLOW}ℹ Своей папки с образами у $MOD_TYPE нет — используется $(basename "$IMG_SRC_DIR") (параметр IMG_FROM_${MOD_TYPE}). Пулы, метки и учётные записи — $MOD_TYPE.${C_NC}" ;;
            similar) echo -e "${C_YELLOW}⚠ Папка $IMG_DIR/$MOD_TYPE не найдена, использую похожую по имени: $IMG_SRC_DIR${C_NC}" ;;
            root)
                if [ "$MOD_TYPE" = "DEMO_GOLD" ]; then
                    echo -e "${C_RED}✖ Папки $IMG_DIR/DEMO_GOLD с образами нет.${C_NC}"
                    echo -e "${C_YELLOW}  Эталон создаёт сам эксперт: выполните задания на стенде DEMO_2 и сохраните его пунктом${C_NC}"
                    echo -e "${C_YELLOW}  «Сохранить стенд или одну машину как образ(ы)» в папку DEMO_GOLD.${C_NC}"
                    exit 1
                fi
                if [ -z "$(find "$IMG_DIR" -maxdepth 1 -type f -name "*${FILE_MASK}" 2>/dev/null | head -n 1)" ]; then
                    echo -e "${C_RED}✖ Для модуля $MOD_TYPE не найдена ни папка $IMG_DIR/$MOD_TYPE, ни образы прямо в $IMG_DIR.${C_NC}"
                    echo -e "${C_YELLOW}  Подпапки с образами:$(find "$IMG_DIR" -mindepth 1 -maxdepth 1 -type d -printf ' %f' 2>/dev/null)${C_NC}"
                    echo -e "${C_YELLOW}  Создайте папку $IMG_DIR/$MOD_TYPE и положите в неё образы этого модуля.${C_NC}"
                    exit 1
                fi
                echo -e "${C_YELLOW}⚠ Папки $IMG_DIR/$MOD_TYPE нет — беру образы из корня $IMG_DIR (подпапки других модулей не просматриваются).${C_NC}"
                ;;
        esac

        ISO_MISSING=0
        ISO_SPEC_NAME=$(iso_spec); ISO_SPEC_NAME=${ISO_SPEC_NAME%%|*}
        if [ -n "$ISO_SPEC_NAME" ] && ! find_iso "$ISO_SPEC_NAME" >/dev/null; then
            echo -e "${C_YELLOW}⚠ Диск с дополнительными материалами $ISO_SPEC_NAME не найден ни в одном хранилище ISO: машины будут развёрнуты без него.${C_NC}"
        fi
        mapfile -t EXPANDED_STANDS < <(expand_ranges "${STANDS[@]}" | tr -s ' ' '\n' | sed '/^$/d' | sort -nu)
        if [ "${#EXPANDED_STANDS[@]}" -eq 0 ]; then
            echo "✖ Укажите номера стендов." >&2; exit 1
        fi
        # Оценка по полным комплектам нужна для новых стендов. Уже созданный
        # стенд восстанавливает только недостающие ВМ и не резервирует весь объём заново.
        POOLS=$(pool_inventory) || exit 1
        NEW_STANDS=0
        for s in "${EXPANDED_STANDS[@]}"; do
            if ! jq -e --arg pool "${MOD_TYPE}_S$s" 'any(.[]; .poolid == $pool)' >/dev/null <<< "$POOLS"; then
                NEW_STANDS=$((NEW_STANDS + 1))
            fi
        done
        SPACE_RC=0
        if [ "$NEW_STANDS" -gt 0 ]; then space_check "$NEW_STANDS"; SPACE_RC=$?; fi
        if [ "$SPACE_RC" -eq 2 ]; then
            if [ "${SPACE_FORCE:-0}" = "1" ]; then
                echo -e "${C_YELLOW}⚠ Места не хватает, но развёртывание запущено по подтверждению (FORCE). Возможны ошибки ввода-вывода (io-error) у ВМ.${C_NC}"
            else
                echo -e "${C_RED}✖ Развёртывание не выполнено: выберите другое хранилище или освободите место.${C_NC}"
                exit 2
            fi
        fi
        echo

        DEPLOY_OK=0 DEPLOY_FAIL=0
        for s in "${EXPANDED_STANDS[@]}"; do
            if deploy_from_images "$s"; then
                DEPLOY_OK=$((DEPLOY_OK + 1))
            else
                DEPLOY_FAIL=$((DEPLOY_FAIL + 1))
                echo "✖ Стенд $s: развёртывание не завершено." >&2
            fi
        done

        if [ "${ISO_MISSING:-0}" -gt 0 ]; then
            echo -e "\n${C_YELLOW}⚠ Без диска с дополнительными материалами (${ISO_SPEC_NAME}) осталось машин: $ISO_MISSING.${C_NC}"
            echo -e "${C_YELLOW}  Загрузите ISO в хранилище (local → ISO Images) и подключите: Состояние и доступ → «Подключить диск с доп. материалами».${C_NC}"
        fi
        echo "Итог $MOD_TYPE: готово стендов $DEPLOY_OK, не завершено $DEPLOY_FAIL. Доступы: $CSV_FILE"
        [ "$DEPLOY_FAIL" -eq 0 ] || exit 1
        ;;
    manage)
        echo -e "${C_GREEN}Выполняю команду $ACTION...${C_NC}"
        manage_state "${STANDS[@]}" || exit 1
        echo -e "${C_GREEN}✔ Операция $ACTION завершена.${C_NC}"
        ;;
    patch)
        SECRET_MODE=0
        CLEAN_STANDS=()

        for arg in "${STANDS[@]}"; do
            if [ "$arg" == "--expert-mode" ]; then
                SECRET_MODE=1
            else
                CLEAN_STANDS+=("$arg")
            fi
        done

        if [ "${APT_DIRECT:-0}" = "1" ]; then
            echo -e "${C_GREEN}Отключаю кэшер APT (прямое обращение к зеркалу)...${C_NC}"
        else
            echo -e "${C_GREEN}Применяю инфраструктурный патч (кэширование APT)...${C_NC}"
        fi
        SECRET_MODE=$SECRET_MODE post_flight_patch "${CLEAN_STANDS[@]}"
        echo -e "${C_GREEN}✔ Инъекция завершена.${C_NC}"
        ;;
    spacecheck)
        SC_N=0; SC_OLD=""
        for s in $(expand_ranges "${STANDS[@]}"); do
            if [ -n "$(pool_vmids "${MOD_TYPE}_S${s}")" ]; then SC_OLD+="$s "; else SC_N=$((SC_N + 1)); fi
        done
        [ -n "$SC_OLD" ] && echo -e "${C_YELLOW}⚠ Уже развёрнуты и будут пропущены стенды: ${SC_OLD}(сначала удалите их, если нужно развернуть заново).${C_NC}"
        [ "$SC_N" -eq 0 ] && { echo "Новых стендов для развёртывания нет."; exit 1; }
        space_check "$SC_N"
        exit $?
        ;;
    storages)
        # для меню: id|тип|тонкое|свободно|всего|занято_%|нужно|хватит (нужно — на указанное число стендов текущего модуля)
        if [ -z "${STANDS[0]}" ]; then storage_list | sed 's/$/|0|1/'; else storage_fit_list "${STANDS[0]}"; fi
        ;;
    export)
        EXP_LIST=($(expand_ranges "${STANDS[@]}"))
        if [ "${#EXP_LIST[@]}" -ne 1 ]; then
            echo -e "${C_RED}✖ Сохранять образы можно только с одного стенда (указано: ${STANDS[*]}).${C_NC}"; exit 1
        fi
        echo -e "ИТ-СПЕЦНАЗ, версия скриптов: $SPETSNAZ_VERSION"
        export_stand "${EXP_LIST[0]}"
        exit $?
        ;;
    roles)
        stand_vm_list 0 1 | awk -F'#' '{print $2}'
        ;;
    isoinfo)
        # для меню: «имя_ISO|роли|volid» (volid пуст — ISO не найден); пустой вывод — модулю диск не нужен
        ISPEC=$(iso_spec)
        [ -z "$ISPEC" ] && exit 0
        echo "${ISPEC}|$(find_iso "${ISPEC%%|*}")"
        ;;
    redeploy)
        [ -z "$REDEPLOY_ROLE" ] && { echo -e "${C_RED}✖ Не указана роль (REDEPLOY_ROLE).${C_NC}"; exit 1; }
        echo -e "ИТ-СПЕЦНАЗ, версия скриптов: $SPETSNAZ_VERSION"
        echo -e "${C_GREEN}Переразвёртывание $REDEPLOY_ROLE ($MOD_TYPE), стенды: ${STANDS[*]}${C_NC}"
        RD_OK=0; RD_FAIL=0
        for s in $(expand_ranges "${STANDS[@]}"); do
            if redeploy_vm "$s" "$REDEPLOY_ROLE"; then RD_OK=$((RD_OK + 1)); else RD_FAIL=$((RD_FAIL + 1)); fi
        done
        echo -e "\nИтог: переразвёрнуто $RD_OK, не выполнено $RD_FAIL."
        [ "${ISO_MISSING:-0}" -gt 0 ] && echo -e "${C_YELLOW}⚠ Без диска с дополнительными материалами: $ISO_MISSING ВМ (Состояние и доступ → «Подключить диск с доп. материалами»).${C_NC}"
        [ "$RD_FAIL" -eq 0 ]; exit $?
        ;;
    rotate)
        echo -e "${C_GREEN}Активирован протокол «День С». Генерирую новые ключи доступа...${C_NC}"
        rotate_passwords "${STANDS[@]}"
        ;;
esac
