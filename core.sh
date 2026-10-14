#!/bin/bash
SPETSNAZ_VERSION="0.6.9 (2026-10-14)"
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
    local base_id=$1 i tries br
    for i in 9 10; do
        br="vmbr$((base_id + i))"
        tries=0
        until ovs-vsctl br-exists "$br" 2>/dev/null || [ $tries -ge 30 ]; do
            sleep 1; tries=$((tries + 1))
        done
        ovs-ofctl add-flow "$br" "table=0, dl_dst=01:80:c2:00:00:02, actions=flood" >/dev/null 2>&1
        if ! ovs-ofctl dump-flows "$br" 2>/dev/null | grep -q "01:80:c2:00:00:02"; then
            echo -e "    ${C_YELLOW}⚠ ВНИМАНИЕ: не удалось добавить правило LACP на $br. Повторите: ovs-ofctl add-flow $br \"table=0, dl_dst=01:80:c2:00:00:02, actions=flood\"${C_NC}"
        fi
    done
}

attach_iso() {
    # attach_iso <vmid> <iso> [soft]
    # soft — диск не обязателен: если ISO нет, это просто информационное сообщение, а не предупреждение
    local v_id=$1 iso=$2 mode=${3:-hard}
    if pvesm list local --content iso 2>/dev/null | grep -q "iso/${iso}"; then
        qm set $v_id --ide2 local:iso/$iso,media=cdrom >/dev/null 2>&1
    elif [ "$mode" = "soft" ]; then
        echo -e "    ${C_NC}ℹ ISO $iso в хранилище local не найден — ВМ $v_id создана без диска. Если задание его требует, положите файл в local (ISO Images) и подключите позже: qm set $v_id --ide2 local:iso/$iso,media=cdrom (или Hardware → CD/DVD Drive).${C_NC}"
    else
        echo -e "    ${C_YELLOW}⚠ ВНИМАНИЕ: ISO $iso не найден в хранилище local — диск не подключён к ВМ $v_id.${C_NC}"
    fi
}

# Определяет каталог с образами для текущего модуля.
# 1) $IMG_DIR/$MOD_TYPE; 2) подпапка с «похожим» именем (регистр, «_» и «-» не важны);
# 3) иначе — сам $IMG_DIR, но только файлы верхнего уровня (чтобы не подхватить образы другого модуля из его подпапки).
# Печатает "<каталог>|<глубина поиска>|<exact|similar|root>".
resolve_img_dir() {
    local want have d
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

get_next_free_hundred() {
    local base=10000 used_ids
    # ID занятых ВМ берём по всему кластеру (qm list показывает только текущий узел)
    used_ids=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | grep -Po '"vmid":\K\d+')
    [ -z "$used_ids" ] && used_ids=$(qm list | awk 'NR>1 {print $1}')
    while true; do
        local conflict=0
        for vmid in $used_ids; do
            if [ "$vmid" -ge "$base" ] && [ "$vmid" -lt $((base + 100)) ]; then
                conflict=1; break
            fi
        done
        if [ $conflict -eq 0 ]; then echo $base; return; fi
        base=$((base + 100))
    done
}

deploy_from_images() {
    local s=$1; local b_id=$2; local mod_type=$3; local br=$b_id
    local suffix="$mod_type"; local pool="${suffix}_S${s}"; local pve_tag="${mod_type,,},stand_$s"

    pvesh get /pools/$pool >/dev/null 2>&1 || pvesh create /pools --poolid $pool --comment "Stand $suffix - $s" >/dev/null

    local mod_lower=$(echo "$MOD_TYPE" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
    USER="${mod_lower}-s${s}@pve"
    PASS=$(gen_password 8)

    if ! pveum user list | grep -q "$USER"; then pveum user add $USER >/dev/null 2>&1; fi
    pvesh set /access/password --userid "$USER" --password "$PASS" >/dev/null 2>&1
    pveum acl modify /pool/$pool -users $USER -roles Participant_RC >/dev/null

    echo "Стенд $s ($suffix),$USER,$PASS" >> "$CSV_FILE"
    chmod 600 "$CSV_FILE" 2>/dev/null

    for i in {1..10}; do
        local bridge="vmbr$((br+i))"
        local is_ovs=0

        if [[ "$MOD_TYPE" == REG_* || "$MOD_TYPE" == MOD_* || "$MOD_TYPE" == GOLD_* ]] && [[ "$i" -ge 9 && "$i" -le 10 ]]; then is_ovs=1; fi
        if [[ "$MOD_TYPE" == DEMO* ]] && [ "$i" -eq 3 ]; then is_ovs=1; fi

        if pvesh get /nodes/$NODE/network/$bridge >/dev/null 2>&1; then
            local bridge_type=$(pvesh get /nodes/$NODE/network/$bridge --output-format json | grep -Po '"type":"\K[^"]+')
            if [ "$is_ovs" -eq 1 ] && [ "$bridge_type" != "OVSBridge" ]; then
                pvesh delete /nodes/$NODE/network/$bridge >/dev/null 2>&1
            fi
        fi

        if ! pvesh get /nodes/$NODE/network/$bridge >/dev/null 2>&1; then
            if [ "$is_ovs" -eq 1 ]; then
                pvesh create /nodes/$NODE/network --iface $bridge --type OVSBridge --autostart 1 >/dev/null 2>&1
            else
                pvesh create /nodes/$NODE/network --iface $bridge --type bridge --autostart 1 >/dev/null 2>&1
            fi
        fi
    done

    pvesh set /nodes/$NODE/network >/dev/null 2>&1

    if [[ "$MOD_TYPE" == REG_* || "$MOD_TYPE" == MOD_* || "$MOD_TYPE" == GOLD_* ]]; then
        ensure_ovs_flows "$br"
    fi

    patch_net() {
        local v_id=$1; local iface=$2; local target=$3
        local current=$(qm config $v_id | grep "^${iface}:" | sed "s/^${iface}:\s*//")
        if [ -z "$current" ]; then
            echo -e "    ${C_YELLOW}⚠ ВНИМАНИЕ: В шаблоне ВМ $v_id отсутствует адаптер $iface! Сеть $target не подключена.${C_NC}" >&2
            return
        fi

        local new_bridge=$(echo "$target" | cut -d',' -f1)
        local patched=$(echo "$current" | sed -E "s/bridge=[^,]+/bridge=$new_bridge/")

        if [[ "$target" == *"tag="* ]]; then
            local new_tag=$(echo "$target" | grep -o 'tag=[0-9]*')
            if [[ "$patched" == *"tag="* ]]; then
                patched=$(echo "$patched" | sed -E "s/tag=[0-9]+/$new_tag/")
            else
                patched="$patched,$new_tag"
            fi
        fi

        if [[ "$target" == *"macaddr="* ]]; then
            local new_mac=$(echo "$target" | sed -E 's/.*macaddr=([0-9a-fA-F:]+).*/\1/')
            patched=$(echo "$patched" | sed -E "s/[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}/$new_mac/")
        fi
        if [[ "$target" == *"link_down=1"* ]] && [[ "$patched" != *"link_down="* ]]; then patched="$patched,link_down=1"; fi

        qm set $v_id --$iface "$patched" >/dev/null 2>&1
    }

    local mac_stand_byte
    mac_stand_byte=$(printf '%02X' $((10#$s % 256)))

    local vms=()
    if [[ "$MOD_TYPE" == DEMO* ]]; then
        vms=(
            "1#ISP#net0:$WAN_BR,macaddr=1C:87:76:40:${mac_stand_byte}:01 net1:vmbr$((br+1)) net2:vmbr$((br+2))"
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
            "3#COD-GW#net0:$WAN_BR,macaddr=1C:87:76:40:${mac_stand_byte}:03,link_down=1 net1:vmbr$((br+4)) net2:vmbr$((br+5))"
            "4#GW-1#net0:$WAN_BR,macaddr=1C:87:76:40:${mac_stand_byte}:04,link_down=1 net1:vmbr$((br+1)) net2:vmbr$((br+4))"
            "5#GW-2#net0:$WAN_BR,macaddr=1C:87:76:40:${mac_stand_byte}:05,link_down=1 net1:vmbr$((br+2)) net2:vmbr$((br+6))"
            "6#GW-3#net0:$WAN_BR,macaddr=1C:87:76:40:${mac_stand_byte}:06,link_down=1 net1:vmbr$((br+3)) net2:vmbr$((br+8))"
            "7#ZSPD-FW#net0:vmbr$((br+7))"
            "8#GW-CORE#net0:$WAN_BR,macaddr=1C:87:76:40:${mac_stand_byte}:08 net1:vmbr$((br+1)) net2:vmbr$((br+2)) net3:vmbr$((br+3))"
            "9#ZSPD-SW#net0:vmbr$((br+6)) net1:vmbr$((br+7))"
            "10#COD-SRV-1#net0:vmbr$((br+5)) net1:vmbr$((br+5))"
            "11#COD-SRV-2#net0:vmbr$((br+5))"
            "12#PUB#net0:vmbr$((br+5))"
            "13#COD-ADMIN#net0:vmbr$((br+5)) net1:vmbr$((br+5))"
            "14#DATA#net0:vmbr$((br+5))"
        )
    fi

    for vm in "${vms[@]}"; do
        local off name nets_config vid

        IFS='#' read -r off name nets_config <<< "$vm"

        vid=$((b_id + off))

        local vm_label="$name"
        case "$name" in
            PROV-GW) vm_label="PROVIDER-GW" ;;
            PROV-SW) vm_label="PROVIDER-SW" ;;
        esac

        local full_archive_path
        full_archive_path=$(find_image "$name" "$vm_label")

        if [ -z "$full_archive_path" ] || [ ! -f "$full_archive_path" ]; then
            local search_dir
            IFS='|' read -r search_dir _ _ <<< "$(resolve_img_dir)"
            echo -e "${C_YELLOW}⚠ ВНИМАНИЕ: Образ для ${name} не найден в ${search_dir}! Пропускаю ВМ.${C_NC}"
            DEPLOY_SKIPPED=$((DEPLOY_SKIPPED + 1))
            continue
        fi

        zstdcat "$full_archive_path" | qmrestore - $vid --storage "$TARGET_STORAGE" --force 1 >/dev/null 2>&1
        qm set $vid --name "$vm_label" >/dev/null 2>&1

        echo -e "    ${C_GREEN}✔ Боевая единица $vm_label (ID: $vid) успешно развернута! Образ: ${full_archive_path#$IMG_DIR/}${C_NC}"

        # Дополнительные ISO: DEMO_1 — не нужны; DEMO_2/DEMO_3 — Additional_de.iso (необязательный, подключается к HQ-SRV/BR-SRV, если лежит в local);
        # REG/MOD/GOLD — Additional_rc.iso для COD-ADMIN (обязателен — при отсутствии выводится предупреждение)
        if [[ "$MOD_TYPE" == DEMO_2 || "$MOD_TYPE" == DEMO_3 || "$MOD_TYPE" == DEMO_T2 || "$MOD_TYPE" == DEMO_T3 ]]; then
            if [[ "$name" == "HQ-SRV" || "$name" == "BR-SRV" ]]; then
                attach_iso $vid "Additional_de.iso" soft
            fi
        elif [[ "$MOD_TYPE" == REG_* || "$MOD_TYPE" == MOD_* || "$MOD_TYPE" == GOLD_* ]]; then
            if [[ "$name" == "COD-ADMIN" ]]; then
                attach_iso $vid "Additional_rc.iso"
            fi
        fi

        for net_rule in $nets_config; do
            local iface="${net_rule%%:*}"; local target="${net_rule#*:}"
            patch_net $vid $iface "$target"
        done

        qm set $vid --tags "$pve_tag" >/dev/null 2>&1
        pvesh set /pools/$pool -vms $vid >/dev/null 2>&1
        qm set $vid --tablet 1 --vga qxl >/dev/null 2>&1

        sleep 1; qm unlock $vid >/dev/null 2>&1
        if ! snap_exists "$vid" "Day0"; then
            snap_err=$(qm snapshot $vid "Day0" --description "Чистый старт стенда" 2>&1) || echo -e "    ${C_YELLOW}⚠ VM $vid: снапшот Day0 не создан: $(echo "$snap_err" | tail -n 1)${C_NC}"
        fi
    done
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

manage_state() {
    local stands_list=($(expand_ranges "$@"))
    local tau_delay=${TAU_DELAY:-8}
    ADDR_PENDING=()

    for s in "${stands_list[@]}"; do
        mapfile -t pool_arr < <(pvesh get /pools --output-format json 2>/dev/null | grep -Po '"poolid":"\K[^"]+' | grep "^${MOD_TYPE}_S${s}$")
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
            local vmids=$(pvesh get /pools/$pool_name --output-format json 2>/dev/null | grep -Po '"vmid":\K\d+')

            if [ "$ACTION" == "destroy" ]; then
                local mod_lower_d=$(echo "$MOD_TYPE" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
                revoke_net_access "$pool_name" "${mod_lower_d}-s${s}@pve"
            fi

            if [ "$ACTION" == "start" ] && [ -n "$vmids" ]; then
                if [[ "$MOD_TYPE" == REG_* || "$MOD_TYPE" == MOD_* || "$MOD_TYPE" == GOLD_* ]]; then
                    local ovs_base=$(stand_base_id "$pool_name")
                    [ -n "$ovs_base" ] && ensure_ovs_flows "$ovs_base"
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
                        qm start $vmid >/dev/null 2>&1
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
                    destroy)
                        qm stop $vmid >/dev/null 2>&1; sleep 1; qm destroy $vmid --purge 1 --skiplock 1 >/dev/null 2>&1
                        ;;
                    snapshot|rollback|delsnap)
                        snap_op "$ACTION" "$vmid" "$SNAP_NAME"
                        ;;
                esac
            done

            if [ "$ACTION" == "destroy" ]; then
                pvesh delete /pools/$pool_name >/dev/null 2>&1
                if [ -n "$vmids" ]; then
                    local first_vmid=$(echo "$vmids" | head -n 1)
                    local base_id=$(( (first_vmid / 100) * 100 ))
                    for i in {1..10}; do pvesh delete /nodes/$NODE/network/vmbr$((base_id + i)) >/dev/null 2>&1; done
                    pvesh set /nodes/$NODE/network >/dev/null 2>&1
                fi

                local mod_lower=$(echo "$MOD_TYPE" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
                pveum user delete "${mod_lower}-s${s}@pve" >/dev/null 2>&1
            fi
        done
    done

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
        DEMO_3|DEMO_T3)
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

    REG_A|MOD_A)                    MOD_SHORT="REG_A"; ROTATION_NAME="Day_C1" ;;
    REG_B|MOD_B)                    MOD_SHORT="REG_B"; ROTATION_NAME="Day_C2" ;;
    REG_D|MOD_D)                    MOD_SHORT="REG_D"; ROTATION_NAME="Day_C3" ;;

    *)                              MOD_SHORT="$MOD_TYPE"; ROTATION_NAME="${MOD_TYPE}_Exam" ;;
esac

export CSV_FILE="credentials/deploy_${MOD_SHORT}.csv"
export ROT_FILE="credentials/${ROTATION_NAME}.csv"

case $COMMAND in
    deploy)
        [ ! -d "$IMG_DIR" ] && echo -e "${C_RED}✖ Ошибка: Директория $IMG_DIR не найдена!${C_NC}" && exit 1
        if [ ! -f "$CSV_FILE" ]; then
            echo "Стенд,Логин,Пароль" > "$CSV_FILE"
            chmod 600 "$CSV_FILE" 2>/dev/null
        fi
        setup_pve_roles

        echo -e "ИТ-СПЕЦНАЗ, версия скриптов: $SPETSNAZ_VERSION"
        IFS='|' read -r IMG_SRC_DIR IMG_SRC_DEPTH IMG_SRC_KIND <<< "$(resolve_img_dir)"
        case "$IMG_SRC_KIND" in
            exact)   echo -e "${C_GREEN}Начинаем компактный деплой ($MOD_TYPE). Образы: $IMG_SRC_DIR${C_NC}" ;;
            similar) echo -e "${C_YELLOW}⚠ Папка $IMG_DIR/$MOD_TYPE не найдена, использую похожую по имени: $IMG_SRC_DIR${C_NC}" ;;
            root)
                if [ -z "$(find "$IMG_DIR" -maxdepth 1 -type f -name "*${FILE_MASK}" 2>/dev/null | head -n 1)" ]; then
                    echo -e "${C_RED}✖ Для модуля $MOD_TYPE не найдена ни папка $IMG_DIR/$MOD_TYPE, ни образы прямо в $IMG_DIR.${C_NC}"
                    echo -e "${C_YELLOW}  Подпапки с образами:$(find "$IMG_DIR" -mindepth 1 -maxdepth 1 -type d -printf ' %f' 2>/dev/null)${C_NC}"
                    echo -e "${C_YELLOW}  Создайте папку $IMG_DIR/$MOD_TYPE и положите в неё образы этого модуля.${C_NC}"
                    exit 1
                fi
                echo -e "${C_YELLOW}⚠ Папки $IMG_DIR/$MOD_TYPE нет — беру образы из корня $IMG_DIR (подпапки других модулей не просматриваются).${C_NC}"
                ;;
        esac

        DEPLOY_SKIPPED=0
        EXPANDED_STANDS=($(expand_ranges "${STANDS[@]}"))
        for s in "${EXPANDED_STANDS[@]}"; do
            STAND_BASE=$(get_next_free_hundred)
            deploy_from_images "$s" "$STAND_BASE" "$MOD_TYPE"
            sleep 1
        done

        if [ "$DEPLOY_SKIPPED" -gt 0 ]; then
            echo -e "\n${C_YELLOW}⚠ Пропущено машин из-за отсутствия образов: $DEPLOY_SKIPPED. Проверьте имена файлов в $IMG_DIR/$MOD_TYPE.${C_NC}"
        fi
        echo -e "\n${C_GREEN}✔ Деплой ($MOD_TYPE) завершен! Доступы в $CSV_FILE${C_NC}"
        cat "$CSV_FILE" | column -t -s ','
        ;;
    manage)
        echo -e "${C_GREEN}Выполняю команду $ACTION...${C_NC}"
        manage_state "${STANDS[@]}"
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
    rotate)
        echo -e "${C_GREEN}Активирован протокол «День С». Генерирую новые ключи доступа...${C_NC}"
        rotate_passwords "${STANDS[@]}"
        ;;
esac
