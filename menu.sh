#!/bin/bash
MENU_VERSION="0.6.9"   # версия menu.sh; должна совпадать с версией core.sh (SPETSNAZ_VERSION)

if [ -z "$TMUX" ] && command -v tmux &> /dev/null; then
    tmux has-session -t it_spetsnaz 2>/dev/null
    if [ $? -ne 0 ]; then
        echo -e "\nОбнаружена незащищенная консоль. Создаю автономный контур безопасности (tmux)..."
        sleep 1
        exec tmux new-session -s it_spetsnaz "$0 $@"
    else
        echo -e "\nПодключаюсь к активному контуру ИТ-спецназа..."
        sleep 1
        exec tmux attach-session -t it_spetsnaz
    fi
fi

CORE_SCRIPT="./core.sh"

detect_host_os() {
    if [ -f /etc/altlinux-release ]; then
        echo "alt"; return
    fi
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "${ID,,}" in
            altlinux) echo "alt"; return ;;
            debian)   echo "debian"; return ;;
        esac
    fi
    if command -v rpm &>/dev/null && ! command -v dpkg &>/dev/null; then
        echo "alt"; return
    fi
    if command -v dpkg &>/dev/null; then
        echo "debian"; return
    fi
    echo "unknown"
}
export HOST_OS
HOST_OS=$(detect_host_os)

if command -v whiptail &>/dev/null; then
    UI_BACKEND="whiptail"
elif command -v dialog &>/dev/null; then
    UI_BACKEND="dialog"
else
    UI_BACKEND="text"
fi

ui_msgbox() {
    local title="$1" text="$2" h="${3:-10}" w="${4:-70}"
    case "$UI_BACKEND" in
        whiptail|dialog) "$UI_BACKEND" --title "$title" --msgbox "$text" "$h" "$w" ;;
        text)
            echo -e "\n===== ${title} =====\n${text}\n"
            read -n 1 -s -r -p "Нажмите любую клавишу..."
            echo
            ;;
    esac
}

ui_yesno() {
    local title="$1" text="$2" h="${3:-10}" w="${4:-70}"
    case "$UI_BACKEND" in
        whiptail|dialog) "$UI_BACKEND" --title "$title" --yesno "$text" "$h" "$w" ;;
        text)
            echo -e "\n===== ${title} =====\n${text}"
            local ans
            read -r -p "Да/Нет [y/N]: " ans
            [[ "$ans" =~ ^([YyДд]|[Yy][Ee][Ss])$ ]]
            ;;
    esac
}

ui_inputbox() {
    local title="$1" prompt="$2" h="${3:-10}" w="${4:-70}" default="$5"
    case "$UI_BACKEND" in
        whiptail|dialog) "$UI_BACKEND" --title "$title" --inputbox "$prompt" "$h" "$w" "$default" 3>&1 1>&2 2>&3 ;;
        text)
            echo -e "\n===== ${title} =====" >&2
            echo -e "${prompt}" >&2
            local val
            read -r -p "[${default}]: " val
            echo "${val:-$default}"
            ;;
    esac
}

ui_pathbox() {
    local title="$1" prompt="$2" default="$3" h="${4:-15}" w="${5:-70}"
    case "$UI_BACKEND" in
        dialog)
            local start_path="$default"
            [ -e "$start_path" ] || start_path="/"
            dialog --title "$title" --fselect "$start_path" "$h" "$w" 3>&1 1>&2 2>&3
            ;;
        whiptail|text)
            clear >&2
            echo -e "\n===== ${title} =====" >&2
            echo -e "${prompt}" >&2
            echo -e "(Tab — автодополнение пути, Enter — подтвердить)\n" >&2
            local val
            read -e -i "$default" -p "Путь> " val
            echo "${val:-$default}"
            ;;
    esac
}

ui_menu() {
    local title="$1" text="$2" h="$3" w="$4" lh="$5"; shift 5
    case "$UI_BACKEND" in
        whiptail|dialog) "$UI_BACKEND" --title "$title" --menu "$text" "$h" "$w" "$lh" "$@" 3>&1 1>&2 2>&3 ;;
        text)
            echo -e "\n===== ${title} =====" >&2
            echo -e "${text}" >&2
            local -a tags=() descs=()
            while [ $# -ge 2 ]; do tags+=("$1"); descs+=("$2"); shift 2; done
            local i
            for i in "${!tags[@]}"; do
                printf "  %2d) %-10s %s\n" "$((i + 1))" "${tags[$i]}" "${descs[$i]}" >&2
            done
            printf "   0) Отмена / Назад\n" >&2
            local choice
            read -r -p "Ваш выбор: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#tags[@]}" ]; then
                echo "${tags[$((choice - 1))]}"
                return 0
            fi
            return 1
            ;;
    esac
}

if [ "$UI_BACKEND" == "text" ]; then
    echo -e "\nwhiptail/dialog не найдены — перехожу на встроенное текстовое меню (пункт 'Установить базу' в 'Системные утилиты' поставит whiptail, если он доступен в репозитории)."
    sleep 1
fi

# ---- вспомогательные функции для SDN ----
# Зона, к которой реально относится vnet (она может называться иначе, чем сам vnet).
sdn_vnet_zone() {
    pvesh get "/cluster/sdn/vnets/$1" --output-format json 2>/dev/null | jq -r '.zone // empty'
}

# Подсети vnet'а: строки "cidr<TAB>id<TAB>gateway".
sdn_subnet_list() {
    pvesh get "/cluster/sdn/vnets/$1/subnets" --output-format json 2>/dev/null | \
        jq -r '.[] | [(.cidr // ((.network // "") + "/" + ((.mask // "") | tostring))), (.id // .subnet // ""), (.gateway // "")] | @tsv'
}

# Записи IPAM для vnet'а $1 (JSON-массив). У эндпоинта /cluster/sdn/vnets/<vnet>/ips нет GET — содержимое IPAM читается через статус ipam 'pve'.
sdn_ipam_entries() {
    local vnet=$1 out
    out=$(pvesh get /cluster/sdn/ipams/pve/status --output-format json 2>/dev/null)
    if [ -n "$out" ]; then
        echo "$out" | jq -c --arg v "$vnet" '[.[] | select((.vnet // "") == $v)]' 2>/dev/null && return 0
    fi
    pvesh get "/cluster/sdn/vnets/$vnet/ips" --output-format json 2>/dev/null || echo '[]'
}

# ID подсети по её CIDR (ID имеет вид <зона>-<сеть>-<маска>, и зона не обязана совпадать с именем vnet).
sdn_subnet_id_by_cidr() {
    sdn_subnet_list "$1" | awk -F'\t' -v c="$2" '$1==c {print $2; exit}'
}

ip_in_cidr() {
    local ip=$1 net=${2%/*} bits=${2#*/} mask
    mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
    [ $(( $(ip_to_int "$ip") & mask )) -eq $(( $(ip_to_int "$net") & mask )) ]
}

# Удаляет из IPAM записи vnet'а, попадающие в подсеть $3 (без этого Proxmox не даёт удалить подсеть: "not empty").
sdn_purge_ipam() {
    local vnet=$1 zone=$2 cidr=$3 ip
    for ip in $(sdn_ipam_entries "$vnet" | jq -r '.[].ip // empty'); do
        ip_in_cidr "$ip" "$cidr" || continue
        if pvesh delete "/cluster/sdn/vnets/$vnet/ips" --zone "$zone" --ip "$ip" >/dev/null 2>&1; then
            echo -e "    удалена запись IPAM: $ip"
        fi
    done
}

# Выбор одной подсети vnet'а: если подсеть одна — берётся она, если несколько — спрашиваем. Печатает "cidr<TAB>gateway".
sdn_pick_subnet() {
    local vnet=$1 title=$2 line cidr gw id
    local -a lines=() menu_args=()
    mapfile -t lines < <(sdn_subnet_list "$vnet")
    [ ${#lines[@]} -eq 0 ] && return 1
    if [ ${#lines[@]} -eq 1 ]; then
        IFS=$'\t' read -r cidr id gw <<< "${lines[0]}"
        printf '%s\t%s\n' "$cidr" "$gw"; return 0
    fi
    for line in "${lines[@]}"; do
        IFS=$'\t' read -r cidr id gw <<< "$line"
        menu_args+=("$cidr" "шлюз $gw")
    done
    cidr=$(ui_menu "$title" "В vnet '$vnet' несколько подсетей. Какую использовать?" 16 70 ${#lines[@]} "${menu_args[@]}")
    [ -z "$cidr" ] && return 1
    for line in "${lines[@]}"; do
        IFS=$'\t' read -r c2 id gw <<< "$line"
        [ "$c2" == "$cidr" ] && { printf '%s\t%s\n' "$cidr" "$gw"; return 0; }
    done
    return 1
}

# Конфигурация ВМ в виде строк "ключ: значение" — с любого узла кластера (qm config видит только свой узел).
vm_cfg_lines() {
    local vid=$1 out node
    out=$(qm config "$vid" 2>/dev/null)
    if [ -n "$out" ]; then echo "$out"; return 0; fi
    node=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | jq -r --argjson id "$vid" '.[] | select(.vmid == $id) | .node' | head -n 1)
    [ -z "$node" ] && return 1
    pvesh get "/nodes/$node/qemu/$vid/config" --output-format json 2>/dev/null | jq -r 'to_entries[] | "\(.key): \(.value)"'
}

# Разбор списка стендов "1-3, 5" -> "1 2 3 5" (menu.sh не подключает core.sh, поэтому своя копия)
expand_ranges() {
    local result=() item i
    local cleaned_input=$(echo "$@" | tr ',' ' ')
    for item in $cleaned_input; do
        if [[ $item =~ ^([0-9]+)-([0-9]+)$ ]]; then
            for ((i=${BASH_REMATCH[1]}; i<=${BASH_REMATCH[2]}; i++)); do result+=("$i"); done
        elif [[ $item =~ ^[0-9]+$ ]]; then
            result+=("$item")
        fi
    done
    echo "${result[@]}"
}

# Диалог параметров экспертного доступа (статические IP): сеть, шлюз, DNS.
# Предлагает значения по WAN-сети (если WAN — vnet SDN), иначе из spetsnaz.conf.
expert_net_dialog() {
    : "${EXPERT_SUBNET_CONF:=$EXPERT_SUBNET}" "${EXPERT_DNS_CONF:=$EXPERT_DNS}"   # значения из spetsnaz.conf — не затираем выбором прошлого диалога
    local det_sub="$EXPERT_SUBNET_CONF" det_gw="" det_dns="$EXPERT_DNS_CONF" pick cidr gw
    if [ -n "$WAN_BR" ] && pvesh get "/cluster/sdn/vnets/$WAN_BR" >/dev/null 2>&1; then
        if pick=$(sdn_pick_subnet "$WAN_BR" "ЭКСПЕРТНЫЙ ДОСТУП: ПОДСЕТЬ"); then
            IFS=$'\t' read -r cidr gw <<< "$pick"
            det_sub=$(echo "${cidr%/*}" | awk -F. '{print $1"."$2"."$3}')
            det_gw="$gw"; det_dns="$gw"
        fi
    fi
    EXPERT_SUBNET=$(ui_inputbox "ЭКСПЕРТНЫЙ ДОСТУП: СЕТЬ" "Три первых октета технической сети /24, из которой выдаются статические адреса\n(адрес = сеть.(смещение модуля + номер стенда)).\n\nПредложено по WAN-сети '$WAN_BR':" 14 74 "$det_sub")
    [ $? -ne 0 ] || [ -z "$EXPERT_SUBNET" ] && return 1
    EXPERT_GW=$(ui_inputbox "ЭКСПЕРТНЫЙ ДОСТУП: ШЛЮЗ" "Шлюз для статических адресов:" 10 70 "${det_gw:-${EXPERT_SUBNET}.1}")
    [ $? -ne 0 ] || [ -z "$EXPERT_GW" ] && return 1
    EXPERT_DNS=$(ui_inputbox "ЭКСПЕРТНЫЙ ДОСТУП: DNS" "DNS-сервер:" 10 70 "$det_dns")
    [ $? -ne 0 ] || [ -z "$EXPERT_DNS" ] && return 1
    export EXPERT_SUBNET EXPERT_GW EXPERT_DNS
    return 0
}

# Выбор зоны для НОВОЙ сети: существующая зона типа Simple или новая. Печатает ID зоны (всё остальное — в stderr/диалоги).
sdn_choose_zone() {
    local vnet=$1 z default_zone choice
    local -a zlist=() menu_args=()
    mapfile -t zlist < <(pvesh get /cluster/sdn/zones --output-format json 2>/dev/null | jq -r '.[] | select(.type == "simple") | .zone' 2>/dev/null)
    if [[ "$vnet" == vnet* ]]; then default_zone="zone${vnet#vnet}"; else default_zone="z${vnet}"; fi
    default_zone=$(echo "$default_zone" | cut -c1-8)

    if [ ${#zlist[@]} -gt 0 ]; then
        for z in "${zlist[@]}"; do menu_args+=("$z" "существующая зона (тип Simple)"); done
        menu_args+=("__new__" "создать новую зону")
        choice=$(ui_menu "ЗОНА ДЛЯ СЕТИ '$vnet'" "Сеть (VNet) всегда принадлежит какой-то зоне. Выберите уже существующую зону или создайте новую:" 18 74 $(( ${#zlist[@]} + 1 )) "${menu_args[@]}")
        [ -z "$choice" ] && return 1
        if [ "$choice" != "__new__" ]; then echo "$choice"; return 0; fi
    fi
    while true; do
        z=$(ui_inputbox "НОВАЯ ЗОНА SDN" "ID новой зоны (Simple). Зона — это «контейнер» для сетей: в ней задаются DHCP и узлы. Машины подключаются к сети (VNet), а не к зоне.\n\nЛатиница в нижнем регистре, до 8 символов, начинается с буквы:" 13 74 "$default_zone")
        [ -z "$z" ] && return 1
        if [[ ! "$z" =~ ^[a-z][a-z0-9]{0,7}$ ]]; then
            ui_msgbox "НЕВЕРНЫЙ ID" "ID зоны должен начинаться с буквы, содержать только строчные латинские буквы/цифры, не длиннее 8 символов." 9 70 >&2
            continue
        fi
        if pvesh get "/cluster/sdn/zones/$z" >/dev/null 2>&1 && ! printf '%s\n' "${zlist[@]}" | grep -qx "$z"; then
            ui_msgbox "ЗОНА УЖЕ ЕСТЬ" "Зона '$z' уже есть, но она не типа Simple — выберите другое имя." 9 70 >&2
            continue
        fi
        echo "$z"; return 0
    done
}

# DHCP в SDN-зонах (automatic DHCP) работает через dnsmasq: нужен пакет dnsmasq (юнит dnsmasq@.service). Проверяем и при необходимости ставим.
ensure_dnsmasq() {
    if [ -x /usr/sbin/dnsmasq ] && systemctl cat dnsmasq@.service >/dev/null 2>&1; then
        return 0
    fi
    if ui_yesno "НЕ УСТАНОВЛЕН dnsmasq" "Для автоматического DHCP в SDN нужен пакет dnsmasq, а на этом узле его нет.\n\nБез него сеть создастся, но машины не получат адреса по DHCP.\n\nУстановить сейчас (apt-get install dnsmasq) и отключить системный экземпляр (Proxmox запускает свои — по одному на зону)?\n\nВ кластере пакет нужен на каждом узле, где работает зона." 16 74; then
        clear
        echo -e "${C_GREEN}Устанавливаю dnsmasq...${C_NC}"
        if apt-get install -y dnsmasq; then
            systemctl disable --now dnsmasq 2>/dev/null
            echo -e "${C_GREEN}✔ dnsmasq установлен, системный экземпляр отключён.${C_NC}"
        else
            echo -e "${C_YELLOW}⚠ Не удалось установить dnsmasq (нет доступа к репозиторию? см. пункт apt в утилитах). Сеть будет создана, но DHCP заработает только после установки пакета.${C_NC}"
        fi
        sleep 2
    else
        echo -e "${C_YELLOW}Продолжаю без dnsmasq. Не забудьте установить его позже: apt-get install dnsmasq && systemctl disable --now dnsmasq${C_NC}"
        sleep 2
    fi
    return 0
}

provision_sdn_nat_dhcp() {
    local net_id cidr gw range_start range_end snat_flag node net_base ok
    local subnet_id zone_exists vnet_exists subnet_exists existing_nodes mode
    local mac_reg ip_reg zone_name

    node=$(hostname -s)

    while true; do
        net_id=$(ui_inputbox "СОЗДАНИЕ/ОБНОВЛЕНИЕ СЕТИ: ИМЯ СЕТИ (VNet)" "Имя сети (VNet): оно же имя моста, к которому подключаются машины (его же указывают как WAN-мост в настройках). Латиница в нижнем регистре, до 8 символов, начинается с буквы.\n\nЕсли такая сеть уже есть в кластере — мастер предложит обновить её или оставить как есть, а не упадёт с ошибкой:" 14 74 "vnet100")
        [ -z "$net_id" ] && return 0
        [[ "$net_id" =~ ^[a-z][a-z0-9]{0,7}$ ]] && break
        ui_msgbox "НЕВЕРНЫЙ ID" "ID должен начинаться с буквы, содержать только строчные латинские буквы/цифры, не длиннее 8 символов. Попробуйте снова." 10 70
    done

    ensure_dnsmasq

    vnet_exists=0
    pvesh get "/cluster/sdn/vnets/$net_id" >/dev/null 2>&1 && vnet_exists=1

    # Зона: у существующей сети берём её настоящую зону, для новой — предлагаем выбрать или создать
    if [ "$vnet_exists" -eq 1 ]; then
        zone_name=$(sdn_vnet_zone "$net_id")
        [ -z "$zone_name" ] && zone_name="$net_id"
    else
        zone_name=$(sdn_choose_zone "$net_id") || return 0
        [ -z "$zone_name" ] && return 0
    fi

    cidr=$(ui_inputbox "СЕТЬ (CIDR)" "Адрес подсети для '$net_id', например 10.250.100.0/24:" 10 70 "10.250.100.0/24")
    [ -z "$cidr" ] && return 0

    net_base=$(echo "$cidr" | cut -d'/' -f1 | awk -F. '{print $1"."$2"."$3}')

    gw=$(ui_inputbox "ШЛЮЗ" "Адрес шлюза для сети $cidr:" 10 70 "${net_base}.1")
    [ -z "$gw" ] && return 0

    range_start=$(ui_inputbox "DHCP: начало диапазона" "Первый адрес, выдаваемый по DHCP:" 10 70 "${net_base}.10")
    [ -z "$range_start" ] && return 0

    range_end=$(ui_inputbox "DHCP: конец диапазона" "Последний адрес, выдаваемый по DHCP:" 10 70 "${net_base}.200")
    [ -z "$range_end" ] && return 0

    snat_flag=0
    ui_yesno "SNAT (выход в Интернет)" "Разрешить машинам в сети $cidr выходить в Интернет через NAT хоста?" 10 70 && snat_flag=1

    zone_exists=0
    pvesh get "/cluster/sdn/zones/$zone_name" >/dev/null 2>&1 && zone_exists=1

    # ID подсети берём из самого Proxmox по CIDR, а не собираем по имени vnet
    subnet_id=""
    subnet_exists=0
    if [ "$vnet_exists" -eq 1 ]; then
        subnet_id=$(sdn_subnet_id_by_cidr "$net_id" "$cidr")
        [ -n "$subnet_id" ] && subnet_exists=1
    fi

    ok=true
    mode="create"

    if [ "$vnet_exists" -eq 1 ]; then
        clear
        echo -e "${C_YELLOW}Сеть (VNet) '$net_id' уже существует в кластере (зона '$zone_name'). Текущее состояние:${C_NC}"
        pvesh get "/cluster/sdn/zones/$zone_name" 2>/dev/null
        pvesh get "/cluster/sdn/vnets/$net_id/subnets" 2>/dev/null
        echo

        if [ "$subnet_exists" -eq 1 ]; then
            if ui_yesno "СЕТЬ УЖЕ СУЩЕСТВУЕТ" "Подсеть $cidr в vnet '$net_id' уже настроена (см. вывод выше).\n\nОбновить на ней шлюз/DHCP-диапазон/SNAT новыми значениями?\n  шлюз: $gw\n  диапазон: $range_start - $range_end\n  SNAT: $snat_flag\n\nДа — обновить. Нет — оставить как есть (и просто продолжить: регистрация в IPAM и т.д.)." 16 74; then
                mode="update"
            else
                mode="skip"
                echo -e "${C_YELLOW}Оставляю подсеть $cidr в vnet '$net_id' без изменений — использую как есть, она рабочая.${C_NC}"
            fi
        else
            if ! ui_yesno "!!! СЕТЬ VNET БУДЕТ ЗАМЕНЕНА !!!" "У vnet '$net_id' уже есть ДРУГАЯ подсеть (см. вывод выше), а вы указали новую: $cidr.\n\nЭто НЕ обновление — ВСЕ остальные подсети этого vnet будут УДАЛЕНЫ (их DHCP-резервации в IPAM пропадут), и вместо них создана новая $cidr.\n\nПродолжить?" 15 74; then
                echo -e "${C_YELLOW}Отменено, ничего не менялось.${C_NC}"
                return 0
            fi
            local confirm_replace
            confirm_replace=$(ui_inputbox "КОНТРОЛЬНОЕ ПОДТВЕРЖДЕНИЕ" "Для подтверждения замены сети введите слово REPLACE:" 10 70)
            if [ "$confirm_replace" != "REPLACE" ]; then
                ui_msgbox "БЛОКИРОВКА" "Контрольное слово введено неверно. Операция отменена." 8 60
                return 0
            fi
            mode="replace"
        fi
    fi

    if [ "$zone_exists" -eq 1 ]; then
        existing_nodes=$(pvesh get "/cluster/sdn/zones/$zone_name" --output-format json 2>/dev/null | grep -Po '"nodes":"\K[^"]+')
        if [ -n "$existing_nodes" ] && [[ ",$existing_nodes," != *",$node,"* ]]; then
            if ui_yesno "ДОБАВИТЬ НОДУ В ЗОНУ" "Зона '$zone_name' сейчас развёрнута на нодах: $existing_nodes.\nЭтой ноды ($node) там нет — без этого DHCP локально на ней работать не будет.\n\nДобавить '$node' в список нод зоны?" 12 74; then
                pvesh set "/cluster/sdn/zones/$zone_name" --nodes "${existing_nodes},${node}" || ok=false
            fi
        fi
        if [ "$(pvesh get "/cluster/sdn/zones/$zone_name" --output-format json 2>/dev/null | jq -r '.dhcp // empty')" != "dnsmasq" ]; then
            if ui_yesno "DHCP В ЗОНЕ" "В зоне '$zone_name' не включён автоматический DHCP (dnsmasq) — без него машины не получат адреса по DHCP.\n\nВключить DHCP (dnsmasq) в этой зоне?" 11 70; then
                pvesh set "/cluster/sdn/zones/$zone_name" --dhcp dnsmasq || ok=false
            fi
        fi
    fi

    clear
    if [ "$mode" == "create" ] || [ "$mode" == "update" ]; then
        case "$mode" in
            create) echo -e "${C_YELLOW}План создания сети '$net_id' (в кластере не найдена):${C_NC}" ;;
            update) echo -e "${C_YELLOW}План обновления существующей сети '$net_id':${C_NC}" ;;
        esac
        echo "  Зона (Simple):              $zone_name  (нода: $node, automatic DHCP: dnsmasq)"
        echo "  VNet:                       $net_id"
        echo "  Подсеть:                    $cidr, шлюз $gw, SNAT=$snat_flag"
        echo "  DHCP-диапазон:               $range_start - $range_end"
        [ "$mode" == "create" ] && echo "  Firewall (Datacenter, iface $net_id): ACCEPT in DHCPfwd; ACCEPT in DNS -> dest $gw"
        echo

        if ! ui_yesno "ПОДТВЕРЖДЕНИЕ" "Применить эти параметры в Proxmox SDN прямо сейчас?" 10 60; then
            echo -e "${C_YELLOW}Отменено, ничего не изменено.${C_NC}"
            return 0
        fi
    fi

    case "$mode" in
        create)
            if [ "$zone_exists" -eq 0 ]; then
                echo -e "\n${C_GREEN}Создаю зону '$zone_name'...${C_NC}"
                pvesh create /cluster/sdn/zones --zone "$zone_name" --type simple --dhcp dnsmasq --nodes "$node" || ok=false
            else
                echo -e "\n${C_GREEN}Зона '$zone_name' уже есть — использую её.${C_NC}"
            fi

            echo -e "${C_GREEN}Создаю VNet '$net_id'...${C_NC}"
            pvesh create /cluster/sdn/vnets --vnet "$net_id" --zone "$zone_name" || ok=false

            echo -e "${C_GREEN}Создаю подсеть $cidr...${C_NC}"
            pvesh create "/cluster/sdn/vnets/$net_id/subnets" --type subnet --subnet "$cidr" --gateway "$gw" \
                --snat "$snat_flag" --dhcp-range "start-address=$range_start,end-address=$range_end" || ok=false
            ;;
        update)
            echo -e "\n${C_GREEN}Обновляю подсеть $cidr (шлюз/диапазон/SNAT)...${C_NC}"
            pvesh set "/cluster/sdn/vnets/$net_id/subnets/$subnet_id" --gateway "$gw" \
                --snat "$snat_flag" --dhcp-range "start-address=$range_start,end-address=$range_end" || ok=false
            ;;
        replace)
            local old_cidr old_id old_gw
            while IFS=$'\t' read -r old_cidr old_id old_gw; do
                [ -z "$old_id" ] && continue
                [ "$old_cidr" == "$cidr" ] && continue
                echo -e "\n${C_GREEN}Очищаю записи IPAM подсети $old_cidr (иначе Proxmox не даст её удалить)...${C_NC}"
                sdn_purge_ipam "$net_id" "$zone_name" "$old_cidr"
                echo -e "${C_GREEN}Удаляю старую подсеть $old_id...${C_NC}"
                pvesh delete "/cluster/sdn/vnets/$net_id/subnets/$old_id" || ok=false
            done < <(sdn_subnet_list "$net_id")
            echo -e "${C_GREEN}Создаю новую подсеть $cidr...${C_NC}"
            pvesh create "/cluster/sdn/vnets/$net_id/subnets" --type subnet --subnet "$cidr" --gateway "$gw" \
                --snat "$snat_flag" --dhcp-range "start-address=$range_start,end-address=$range_end" || ok=false
            ;;
    esac

    if [ "$mode" != "skip" ]; then
        echo -e "${C_GREEN}Применяю конфигурацию SDN (pvesh set /cluster/sdn)...${C_NC}"
        pvesh set /cluster/sdn || ok=false
    fi

    if [ "$mode" == "create" ] || ! pvesh get /cluster/firewall/rules 2>/dev/null | grep -qF "$net_id"; then
        echo -e "${C_GREEN}Добавляю правила firewall для DHCP/DNS на '$net_id'...${C_NC}"
        pvesh create /cluster/firewall/rules --type in --action ACCEPT --macro DHCPfwd --iface "$net_id" --enable 1 || ok=false
        pvesh create /cluster/firewall/rules --type in --action ACCEPT --macro DNS --iface "$net_id" --dest "$gw" --enable 1 || ok=false
    else
        echo -e "${C_GREEN}Правила firewall для '$net_id' на этот iface уже есть — пропускаю, чтобы не плодить дубликаты.${C_NC}"
    fi

    echo
    if $ok; then
        echo -e "${C_GREEN}✔ Сеть '$net_id' готова к работе.${C_NC}"
    else
        echo -e "${C_YELLOW}⚠ Хотя бы одна из команд выше вернула ошибку — см. вывод над этой строкой.${C_NC}"
        echo -e "${C_YELLOW}  Частые причины: неверный формат CIDR/параметра, либо подсеть/зона поменялись у кого-то ещё параллельно.${C_NC}"
    fi

    echo -e "\n${C_YELLOW}DHCP сети '$net_id' — резервационный (через IPAM), а не 'свободный пул':${C_NC}"
    echo -e "${C_YELLOW}   адрес получит только MAC, уже известный IPAM. Сейчас можно сразу зарегистрировать${C_NC}"
    echo -e "${C_YELLOW}   в IPAM MAC-адреса машин, которым нужен DHCP в этой сети (можно и позже — тем же 'sdn_net').${C_NC}"

    while ui_yesno "РЕГИСТРАЦИЯ В IPAM" "Зарегистрировать в IPAM сети '$net_id' MAC-адрес ещё одной машины?\n\n(Только эти MAC получат адрес по DHCP; повторный вызов этого мастера с тем же ID позволит добавить ещё)" 12 70; do
        mac_reg=$(ui_inputbox "IPAM: MAC-адрес" "MAC-адрес машины (формат XX:XX:XX:XX:XX:XX):" 10 70)
        [ -z "$mac_reg" ] && break

        ip_reg=$(ui_inputbox "IPAM: IP-адрес" "IP-адрес из подсети $cidr, закрепляемый за этим MAC:" 10 70 "${net_base}.")
        [ -z "$ip_reg" ] && break

        if pvesh create "/cluster/sdn/vnets/$net_id/ips" --zone "$zone_name" --mac "$mac_reg" --ip "$ip_reg"; then
            echo -e "    ${C_GREEN}✔ IPAM: $mac_reg -> $ip_reg зарегистрирован.${C_NC}"
        else
            echo -e "    ${C_RED}✖ IPAM: не удалось зарегистрировать $mac_reg -> $ip_reg (см. ошибку выше — возможно, IP/MAC уже заняты).${C_NC}"
            ok=false
        fi
    done

    echo -e "${C_GREEN}Применяю конфигурацию SDN ещё раз, чтобы IPAM-записи попали в dnsmasq...${C_NC}"
    pvesh set /cluster/sdn || ok=false

    echo -e "\n${C_GREEN}Проверка:${C_NC}"
    pvesh get "/cluster/sdn/vnets/$net_id/subnets" 2>/dev/null
    pvesh get /cluster/firewall/rules 2>/dev/null | grep -F "$net_id"
    sdn_ipam_entries "$net_id" | jq -r '.[] | "  IPAM: \(.ip)  \(.mac // "-")"' 2>/dev/null

    echo -e "\n${C_YELLOW}Напоминание — это резерв на уровне Proxmox SDN (что получит машина по DHCP).${C_NC}"
    echo -e "${C_YELLOW}   Если нужно вшить статический IP прямо в гостевую ОС (без DHCP вообще) — для этого${C_NC}"
    echo -e "${C_YELLOW}   по-прежнему служит отдельный 'Экспертный доступ' в Патче.${C_NC}"
}

retag_existing_pools() {
    clear
    echo -e "${C_GREEN}Сканирую пулы (стенды) в кластере...${C_NC}"

    local pool_ids
    mapfile -t pool_ids < <(pvesh get /pools --output-format json 2>/dev/null | grep -Po '"poolid":"\K[^"]+')

    if [ ${#pool_ids[@]} -eq 0 ]; then
        ui_msgbox "ПУСТО" "В кластере не найдено ни одного пула (стенда) — перевешивать нечего." 8 60
        return
    fi

    local total_vms=0 total_pools=0 skipped=0
    local pool mod_type stand_num tag vmids vmid

    for pool in "${pool_ids[@]}"; do
        if [[ "$pool" =~ ^(.+)_S([0-9]+)$ ]]; then
            mod_type="${BASH_REMATCH[1]}"
            stand_num="${BASH_REMATCH[2]}"
            tag="${mod_type,,},stand_${stand_num}"

            vmids=$(pvesh get "/pools/$pool" --output-format json 2>/dev/null | grep -Po '"vmid":\K\d+')
            if [ -z "$vmids" ]; then
                continue
            fi

            total_pools=$((total_pools + 1))
            echo -e "  ${C_YELLOW}Пул $pool${C_NC} -> метка '$tag'"

            for vmid in $vmids; do
                qm set "$vmid" --tags "$tag" >/dev/null 2>&1 && total_vms=$((total_vms + 1))
            done
        else
            skipped=$((skipped + 1))
        fi
    done

    echo
    echo -e "${C_GREEN}✔ Готово: обновлены метки (Модуль/Стенд) на $total_vms ВМ в $total_pools пулах.${C_NC}"
    [ "$skipped" -gt 0 ] && echo -e "${C_YELLOW}  Пропущено пулов с нераспознанным именем (не формата МОДУЛЬ_SN): $skipped${C_NC}"
}

ip_to_int() {
    local a b c d
    IFS='.' read -r a b c d <<< "$1"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

int_to_ip() {
    local ip=$1
    echo "$(( (ip >> 24) & 255 )).$(( (ip >> 16) & 255 )).$(( (ip >> 8) & 255 )).$(( ip & 255 ))"
}

# Находит первый свободный адрес в DHCP-диапазоне подсети vnet'а $1,
# не входящий ни в шлюз, ни в уже зарегистрированные в IPAM адреса.
next_free_ip_in_subnet() {
    local net_id=$1 cidr=$2
    local subnet_json entry gw start_ip end_ip used_ips s_int e_int cur candidate

    subnet_json=$(pvesh get "/cluster/sdn/vnets/$net_id/subnets" --output-format json 2>/dev/null)
    if [ -n "$cidr" ]; then
        entry=$(echo "$subnet_json" | jq -c --arg c "$cidr" '[.[] | select(.cidr == $c)][0] // empty')
    else
        entry=$(echo "$subnet_json" | jq -c '.[0] // empty')
    fi
    [ -z "$entry" ] && return 1

    gw=$(echo "$entry" | jq -r '.gateway // empty')
    start_ip=$(echo "$entry" | jq -r '."dhcp-range"[0]."start-address" // empty')
    end_ip=$(echo "$entry" | jq -r '."dhcp-range"[0]."end-address" // empty')

    if [ -z "$start_ip" ] || [ -z "$end_ip" ]; then
        return 1
    fi

    used_ips=$(sdn_ipam_entries "$net_id" | jq -r '.[].ip // empty')

    s_int=$(ip_to_int "$start_ip")
    e_int=$(ip_to_int "$end_ip")

    for ((cur = s_int; cur <= e_int; cur++)); do
        candidate=$(int_to_ip "$cur")
        [ "$candidate" == "$gw" ] && continue
        if ! echo "$used_ips" | grep -qx "$candidate"; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# Авто-регистрация в IPAM: проходит по пулам уже РАЗВЁРНУТЫХ стендов
# (только те ВМ, что реально существуют в указанных пулах $mod_S$s —
# прочие машины, не созданные этим скриптом, в пулах просто
# отсутствуют и сканом никогда не затрагиваются), ищет у каждой ВМ
# сетевой интерфейс на указанном WAN-мосту/vnet'е, вытаскивает его
# реальный MAC и сама прописывает MAC -> следующий свободный IP в IPAM.
auto_register_ipam() {
    local net_id wan_iface stands_raw mod
    local stands_list s pool vmids vid vm_name net_line mac ip vm_cfg
    local total_registered=0 total_skipped=0 total_vms=0 zone_name pick cidr seen_bridges="" b seen_macs="" fail_streak=0 reg_err existing_ip

    net_id=$(ui_inputbox "АВТО-РЕГИСТРАЦИЯ MAC В IPAM" "ID сети (Zone/VNet), созданной через 5️⃣ (например vnet200), в которую нужно прописать MAC уже развёрнутых машин:" 10 75)
    [ -z "$net_id" ] && return 0

    if ! pvesh get "/cluster/sdn/vnets/$net_id" >/dev/null 2>&1; then
        ui_msgbox "ОШИБКА" "VNet '$net_id' не найден в кластере.\n\nСначала создайте сеть через пункт 5️⃣ Создать NAT+DHCP сеть." 10 70
        return 0
    fi

    wan_iface=$(ui_inputbox "WAN-МОСТ / VNET" "Какой мост используют машины как внешний (обычно совпадает с '$net_id' или с WAN_BR из настроек):" 10 75 "${WAN_BR:-$net_id}")
    [ -z "$wan_iface" ] && return 0

    mod=$(ui_inputbox "МОДУЛЬ" "Тип модуля, с которым разворачивали стенды (DEMO_1, REG_B и т.д.):" 10 75 "${MOD_TYPE:-DEMO_1}")
    [ -z "$mod" ] && return 0

    stands_raw=$(ui_inputbox "СТЕНДЫ" "Номера стендов для сканирования (например: 1-10, 12):" 10 75)
    [ -z "$stands_raw" ] && return 0

    stands_list=($(expand_ranges "$stands_raw"))
    if [ ${#stands_list[@]} -eq 0 ]; then
        ui_msgbox "СТЕНДЫ" "Не удалось разобрать номера стендов: '$stands_raw'.\n\nВводите числа через запятую или диапазоны, например: 4 или 1-10, 12." 10 70
        return 0
    fi

    zone_name=$(sdn_vnet_zone "$net_id")
    [ -z "$zone_name" ] && zone_name="$net_id"

    if ! pick=$(sdn_pick_subnet "$net_id" "ПОДСЕТЬ ДЛЯ DHCP"); then
        ui_msgbox "НЕТ ПОДСЕТИ" "В vnet '$net_id' не найдено подсетей (или выбор отменён).\n\nСоздайте подсеть через пункт sdn_net." 10 70
        return 0
    fi
    IFS=$'\t' read -r cidr _ <<< "$pick"

    clear
    echo -e "${C_GREEN}Адреса выдаются из подсети $cidr (vnet '$net_id', зона '$zone_name').${C_NC}"
    echo -e "${C_GREEN}[menu.sh ${MENU_VERSION}] Сканирую пулы: ${stands_list[*]/#/${mod}_S} — ищу машины на мосту '$wan_iface' (отключённые адаптеры link_down пропускаются)...${C_NC}"
    echo -e "${C_YELLOW}(машины, не входящие в эти пулы, в скан не попадают и не регистрируются)${C_NC}\n"

    for s in "${stands_list[@]}"; do
        pool="${mod}_S${s}"
        vmids=$(pvesh get "/pools/$pool" --output-format json 2>/dev/null | grep -Po '"vmid":\K\d+')

        if [ -z "$vmids" ]; then
            echo -e "    ${C_YELLOW}⚠ Пул $pool пуст или не найден — пропуск.${C_NC}"
            continue
        fi

        for vid in $vmids; do
            vm_cfg=$(vm_cfg_lines "$vid")
            if [ -z "$vm_cfg" ]; then
                echo -e "    ${C_YELLOW}⚠ ВМ $vid: не удалось прочитать конфигурацию (ВМ на другом узле, который недоступен?) — пропуск.${C_NC}"
                total_skipped=$((total_skipped + 1))
                continue
            fi
            total_vms=$((total_vms + 1))
            vm_name=$(echo "$vm_cfg" | awk '/^name:/ {print $2}')

            for b in $(echo "$vm_cfg" | grep -E '^net[0-9]+:' | grep -oP 'bridge=\K[^,]+'); do
                [[ " $seen_bridges " == *" $b "* ]] || seen_bridges="$seen_bridges $b"
            done

            # Адаптеры на WAN-мосту; отключённые (link_down=1) пропускаем — они не работают и адреса им не нужны
            net_line=$(echo "$vm_cfg" | grep -E '^net[0-9]+:' | grep -E "bridge=${wan_iface}(,|$)" | grep -v 'link_down=1' | head -n 1)
            if [ -z "$net_line" ]; then
                continue
            fi

            mac=$(echo "$net_line" | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -n 1)
            if [ -z "$mac" ]; then
                echo -e "    ${C_YELLOW}⚠ ВМ $vid ($vm_name): не удалось извлечь MAC из '$net_line' — пропуск.${C_NC}"
                total_skipped=$((total_skipped + 1))
                continue
            fi
            mac=${mac^^}

            if [[ " $seen_macs " == *" $mac "* ]]; then
                echo -e "    ${C_YELLOW}• ВМ $vid ($vm_name): MAC $mac уже встретился на другой ВМ в этом запуске (одинаковые MAC в образах) — пропуск.${C_NC}"
                total_skipped=$((total_skipped + 1))
                continue
            fi
            seen_macs="$seen_macs $mac"

            # MAC уже есть в IPAM (Proxmox часто регистрирует его сам при создании/запуске ВМ)?
            existing_ip=$(sdn_ipam_entries "$net_id" | jq -r --arg m "$mac" '[.[] | select(((.mac // "") | ascii_upcase) == $m)][0].ip // empty')
            if [ -n "$existing_ip" ]; then
                if ip_in_cidr "$existing_ip" "$cidr"; then
                    echo -e "    ${C_YELLOW}• ВМ $vid ($vm_name): MAC $mac уже в IPAM ($existing_ip) — пропуск.${C_NC}"
                    total_skipped=$((total_skipped + 1))
                    continue
                fi
                # Запись «осталась от прошлого»: адрес не из выбранной подсети — DHCP по ней адрес не выдаст
                echo -e "    ${C_YELLOW}⚠ ВМ $vid ($vm_name): MAC $mac закреплён за $existing_ip — это НЕ из подсети $cidr (устаревшая запись). Заменяю...${C_NC}"
                if ! reg_err=$(pvesh delete "/cluster/sdn/vnets/$net_id/ips" --zone "$zone_name" --ip "$existing_ip" 2>&1); then
                    echo -e "      ${C_RED}✖ Не удалось удалить старую запись: $(echo "$reg_err" | head -n 2 | tr '\n' ' ')${C_NC}"
                    total_skipped=$((total_skipped + 1))
                    continue
                fi
            fi

            ip=$(next_free_ip_in_subnet "$net_id" "$cidr")
            if [ -z "$ip" ]; then
                echo -e "    ${C_RED}✖ Свободных адресов в DHCP-диапазоне подсети '$net_id' не осталось — останавливаюсь.${C_NC}"
                break 2
            fi

            if reg_err=$(pvesh create "/cluster/sdn/vnets/$net_id/ips" --zone "$zone_name" --mac "$mac" --ip "$ip" 2>&1); then
                echo -e "    ${C_GREEN}✔ ВМ $vid ($vm_name): $mac -> $ip${C_NC}"
                total_registered=$((total_registered + 1))
                fail_streak=0
            else
                echo -e "    ${C_RED}✖ ВМ $vid ($vm_name): не удалось зарегистрировать $mac -> $ip${C_NC}"
                echo -e "      Ответ Proxmox: $(echo "$reg_err" | head -n 3 | tr '\n' ' ')"
                total_skipped=$((total_skipped + 1))
                fail_streak=$((fail_streak + 1))
                if [ "$fail_streak" -ge 3 ]; then
                    echo -e "    ${C_RED}✖ Три ошибки подряд — останавливаюсь, чтобы не повторять одно и то же. Причина указана в ответе Proxmox выше.${C_NC}"
                    break 2
                fi
            fi
        done
    done

    echo -e "\n${C_GREEN}Применяю конфигурацию SDN, чтобы новые записи попали в dnsmasq...${C_NC}"
    pvesh set /cluster/sdn >/dev/null 2>&1

    echo -e "\n${C_GREEN}✔ Готово: зарегистрировано $total_registered, пропущено $total_skipped.${C_NC}"

    if [ "$total_vms" -gt 0 ] && [ "$total_registered" -eq 0 ] && [ "$total_skipped" -eq 0 ]; then
        echo -e "\n${C_YELLOW}⚠ Просмотрено ВМ: $total_vms, но ни одна не подключена к мосту '$wan_iface'.${C_NC}"
        echo -e "${C_YELLOW}  Мосты, которые реально используют ВМ этих стендов:${seen_bridges}${C_NC}"
        echo -e "${C_YELLOW}  Если стенды развёрнуты с другим WAN-мостом (например vmbr0), укажите его в поле 'WAN-МОСТ' или${C_NC}"
        echo -e "${C_YELLOW}  переключите внешний сетевой адаптер ВМ на '$wan_iface' (Hardware → Network Device) / разверните стенд заново.${C_NC}"
    elif [ "$total_vms" -eq 0 ]; then
        echo -e "\n${C_YELLOW}⚠ В пулах ${mod}_S<N> не найдено ни одной доступной ВМ — проверьте тип модуля и номера стендов.${C_NC}"
    fi
}

export CSV_FILE="credentials_stands.csv"
export FILE_MASK=".vma.zst"

export C_GREEN='\033[0;32m'
export C_RED='\033[0;31m'
export C_YELLOW='\033[1;33m'
export C_NC='\033[0m'

CONFIG_FILE="spetsnaz.conf"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo -e "\nКонфигурация полигона загружена из $CONFIG_FILE (хост: $HOST_OS)"
    sleep 1
else
    ui_msgbox "ИТ-СПЕЦНАЗ: МАСТЕР НАСТРОЙКИ" "Обнаружен первый запуск.\n\nИнициализирую протокол первоначальной настройки полигона (обнаружена ОС хоста: $HOST_OS). Сейчас мы зададим базовые параметры (сети, хранилища). Они будут сохранены в файл $CONFIG_FILE и больше не потребуют ввода." 13 75

    DEFAULT_WAN=$(ip route show default | awk '{print $5}' | head -n 1)
    [ -z "$DEFAULT_WAN" ] && DEFAULT_WAN="vmbr0"

    WAN_BR=$(ui_inputbox "НАСТРОЙКА СЕТИ (WAN)" "Укажите мост/интерфейс с выходом в Интернет (ISP/GW):" 10 75 "$DEFAULT_WAN")
    [ -z "$WAN_BR" ] && exit 1

    IMG_DIR=$(ui_pathbox "ИСТОЧНИК ОБРАЗОВ (BYOI)" "Директория с .vma.zst бэкапами:\n\n💡 Подсказка: Вы можете использовать WinSCP, wget или USB-накопитель, чтобы закинуть сюда свои собственные образы стендов. Главное — сохраните стандартные имена (напр. HQ-SRV.vma.zst)!" "/var/lib/vz/dump" 15 75)
    [ -z "$IMG_DIR" ] && exit 1

    TARGET_STORAGE=$(ui_inputbox "ЦЕЛЕВОЕ ХРАНИЛИЩЕ" "Укажите хранилище для дисков ВМ (Storage ID, например local-lvm):" 10 75 "local-lvm")
    [ -z "$TARGET_STORAGE" ] && exit 1

    PROXY_IP=$(ui_inputbox "КЭШИРУЮЩИЙ ПРОКСИ" "IP-адрес APT-кэшера (оставьте пустым, если кэшера нет):" 10 75 "")

    APT_MODE="mirror"; APT_CACHE_PORT="3142"
    if [ -n "$PROXY_IP" ]; then
        APT_MODE=$(ui_menu "ТИП СЕРВЕРА ПАКЕТОВ" "Что находится по адресу $PROXY_IP?" 14 78 2 \
            "mirror" "Кэшер (apt-cacher-ng) или локальное зеркало репозитория — подменяется адрес репозитория" \
            "proxy"  "Обычный HTTP-прокси (squid и т.п.) — адреса репозиториев остаются прежними")
        [ -z "$APT_MODE" ] && APT_MODE="mirror"
        [ "$APT_MODE" = "proxy" ] && APT_CACHE_PORT="3128"
        APT_CACHE_PORT=$(ui_inputbox "ПОРТ" "Порт сервера пакетов ($APT_MODE):" 10 60 "$APT_CACHE_PORT")
        [ -z "$APT_CACHE_PORT" ] && APT_CACHE_PORT=$([ "$APT_MODE" = "proxy" ] && echo 3128 || echo 3142)
    fi

    echo "WAN_BR=\"$WAN_BR\"" > "$CONFIG_FILE"
    echo "IMG_DIR=\"$IMG_DIR\"" >> "$CONFIG_FILE"
    echo "TARGET_STORAGE=\"$TARGET_STORAGE\"" >> "$CONFIG_FILE"
    echo "PROXY_IP=\"$PROXY_IP\"" >> "$CONFIG_FILE"
    {
        echo "# Экспертный доступ (патч со статическим IP) и APT-кэш — при необходимости измените:"
        echo "EXPERT_SUBNET=\"10.100.100\"      # три первых октета технической подсети /24"
        echo "EXPERT_GW=\"10.100.100.1\""
        echo "EXPERT_DNS=\"77.88.8.8\""
        echo "EXPERT_IFACE=\"ens18\"            # имя интерфейса в гостевой ОС (etcnet, Альт)"
        echo "APT_MIRROR_HOST=\"mirror.yandex.ru\""
        echo "APT_MODE=\"$APT_MODE\"                # mirror или proxy"
        echo "APT_CACHE_PORT=\"$APT_CACHE_PORT\""
        echo "ADDR_CHECK=\"1\"                 # после старта стендов проверять, получили ли адрес внешние интерфейсы (1/0)"
        echo "ADDR_WAIT=\"150\"                # сколько секунд ждать адреса"
    } >> "$CONFIG_FILE"

    ui_msgbox "НАСТРОЙКА ЗАВЕРШЕНА" "Конфигурация успешно сохранена!\n\nПолигон готов к работе." 10 60
fi

EXPERT_SUBNET="${EXPERT_SUBNET:-10.100.100}"
EXPERT_GW="${EXPERT_GW:-${EXPERT_SUBNET}.1}"
EXPERT_DNS="${EXPERT_DNS:-77.88.8.8}"
EXPERT_IFACE="${EXPERT_IFACE:-ens18}"
APT_MIRROR_HOST="${APT_MIRROR_HOST:-mirror.yandex.ru}"
APT_MODE="${APT_MODE:-mirror}"
APT_CACHE_PORT="${APT_CACHE_PORT:-$([ "$APT_MODE" = proxy ] && echo 3128 || echo 3142)}"
ADDR_CHECK="${ADDR_CHECK:-1}"
ADDR_WAIT="${ADDR_WAIT:-150}"
export ADDR_CHECK ADDR_WAIT
export APT_MODE WAN_BR IMG_DIR TARGET_STORAGE PROXY_IP EXPERT_SUBNET EXPERT_GW EXPERT_DNS EXPERT_IFACE APT_MIRROR_HOST APT_CACHE_PORT

CORE_VERSION=$(grep -m1 -oP 'SPETSNAZ_VERSION="\K[0-9.]+' ./core.sh 2>/dev/null)
if [ "$CORE_VERSION" = "$MENU_VERSION" ]; then
    VERSION_LABEL="$MENU_VERSION"
else
    VERSION_LABEL="menu ${MENU_VERSION} / core ${CORE_VERSION:-?}"
    ui_msgbox "РАЗНЫЕ ВЕРСИИ ФАЙЛОВ" "menu.sh имеет версию ${MENU_VERSION}, а core.sh — ${CORE_VERSION:-не найден}.\n\nЭто частая причина странных ошибок: при обновлении нужно заменять ОБА файла (menu.sh и core.sh) и запускать меню заново из этой папки." 12 70
fi

while true; do
    MAIN_CAT=$(ui_menu "ИТ-СПЕЦНАЗ ${VERSION_LABEL}: УПРАВЛЕНИЕ ПОЛИГОНОМ (WAN: $WAN_BR / ОС: $HOST_OS)" "Выберите категорию операций:" 15 75 6 \
    "deploy"   "🚀 Развертывание и Настройка (Деплой, Патч)" \
    "power"    "⚡ Питание стендов (Запуск / Остановка)" \
    "state"    "📷 Управление состоянием (Снапшоты, Откаты)" \
    "system"   "⚙️ Системные утилиты (Подготовка PVE)" \
    "danger"   "☠️ КРИТИЧЕСКОЕ: Удаление полигона" \
    "exit"     "🚪 Выход в консоль")

    if [ $? -ne 0 ] || [ "$MAIN_CAT" == "exit" ]; then
        echo -e "\nСистемы переведены в ждущий режим."
        break
    fi

    ACTION=""
    case "$MAIN_CAT" in
        deploy)
            ACTION=$(ui_menu "РАЗВЕРТЫВАНИЕ И НАСТРОЙКА" "Выберите операцию:" 13 78 4 \
            "deploy"    "🚀 Развернуть новые стенды" \
            "patch"     "💉 Накатить инфраструктурный патч (APT/IP)" \
            "aptdirect" "🌐 Отключить кэшер APT (ВМ — напрямую к зеркалу)" \
            "rotate"    "🔑 Ротация паролей (Протокол День С)")
            ;;
        power)
            ACTION=$(ui_menu "УПРАВЛЕНИЕ ПИТАНИЕМ" "Выберите операцию:" 16 78 5 \
            "start"    "▶️ Каскадный старт (τ-задержка + проверка адресов)" \
            "addrchk"  "🔍 Проверить, получили ли адрес внешние интерфейсы" \
            "stop"     "⏹️ Жесткая остановка (Power Off)" \
            "shutdown" "🔌 Мягкое выключение (ACPI Shutdown)" \
            "reboot"   "🔄 Перезагрузка стендов")
            ;;
        state)
            ACTION=$(ui_menu "СОСТОЯНИЕ И ДОСТУП" "Выберите операцию:" 20 78 9 \
            "snapshot"   "📷 Создать НОВЫЙ снапшот (Task1, Check2 и т.п.)" \
            "rollback"   "⏪ Откат к снапшоту, напр. Day0 (Внимание!)" \
            "delsnap"    "🗑️ Удалить конкретный снапшот" \
            "lock"       "🔒 Заблокировать студентам доступ" \
            "unlock"     "🔓 Разблокировать доступ" \
            "netperm_on" "🔧 Выдать участникам право менять VLAN/сеть ВМ" \
            "netperm_off" "🚫 Отозвать право менять VLAN/сеть ВМ" \
            "rbperm_on"  "⏪ Разрешить участникам откат ВМ (только тренировка)" \
            "rbperm_off" "🚫 Запретить участникам откат ВМ")
            ;;
        system)
            ACTION=$(ui_menu "СИСТЕМНЫЕ УТИЛИТЫ" "Выберите операцию:" 12 75 2 \
            "utils"  "🛠️ Утилиты хоста (apt, OVS, загрузка)" \
            "reconf" "⚙️ Перенастройка (Сброс spetsnaz.conf)")
            ;;
        danger)
            ACTION="destroy"
            ;;
    esac

    [ -z "$ACTION" ] && continue

    if [ "$ACTION" == "reconf" ]; then
        if ui_yesno "СБРОС КОНФИГУРАЦИИ" "Вы собираетесь уничтожить текущий файл $CONFIG_FILE.\n\nВсе базовые параметры (WAN-мост, ZFS-хранилище, IP-прокси) будут стерты, а Мастер настройки запустится заново.\n\nПродолжить?" 10 70; then
            rm -f "$CONFIG_FILE"
            echo -e "\nСтарая конфигурация стерта. Инициирую перезагрузку оболочки..."
            sleep 1
            exec "$0" "$@"
        fi
        continue
    fi

    if [ "$ACTION" == "utils" ]; then
        UTIL_ACTION=$(ui_menu "ПОДГОТОВКА ХОСТА PVE (ОС: $HOST_OS)" "Выберите действие:" 22 75 10 \
            "fix_repo" "1️⃣ Отключить PVE-Enterprise (Починить apt)" \
            "deps"     "2️⃣ Установить базу: OVS, jq, expect, zstd, dnsmasq" \
            "sdn_net"  "5️⃣ Создать NAT+DHCP сеть (SDN Zone/VNet/Firewall)" \
            "retag"    "6️⃣ Перевесить метки Модуль/Стенд на уже развёрнутых ВМ" \
            "ipam_reg" "7️⃣ Авто-регистрация MAC развёрнутых ВМ в IPAM" \
            "download" "3️⃣ Скачать бэкапы шаблонов (.vma.zst) по URL" \
            "howto"    "ℹ️ СПРАВКА: Как загрузить свои образы?" \
            "aptfix"   "🆘 ПАМЯТКА: apt «Size mismatch» / кэшер" \
            "usb"      "4️⃣ Загрузить образы с USB-флешки" \
            "back"     "🔙 Вернуться в главное меню")

        clear
        case $UTIL_ACTION in
            fix_repo)
                if [ "$HOST_OS" == "debian" ]; then
                    echo -e "${C_GREEN}Отключаем платный репозиторий Proxmox (Debian-ветка)...${C_NC}"
                    sed -i 's/^deb/#deb/g' /etc/apt/sources.list.d/pve-enterprise.list 2>/dev/null
                    rm -f /etc/apt/sources.list.d/tailscale.list /etc/apt/sources.list.d/netbird.list /etc/apt/sources.list.d/netdata.list 2>/dev/null
                    rm -f /etc/apt/sources.list.d/pve-no-subscription.list 2>/dev/null
                    if ! grep -q "pve-no-subscription" /etc/apt/sources.list; then
                        CODENAME=$(grep -oP 'VERSION_CODENAME=\K\w+' /etc/os-release)
                        if [ -n "$CODENAME" ]; then
                            echo -e "\n# Free PVE Repository\ndeb http://download.proxmox.com/debian/pve $CODENAME pve-no-subscription" >> /etc/apt/sources.list
                        else
                            echo -e "${C_YELLOW}⚠ Не удалось определить VERSION_CODENAME — строка no-subscription не добавлена, добавьте вручную.${C_NC}"
                        fi
                    fi
                    apt-get clean && apt-get update
                elif [ "$HOST_OS" == "alt" ]; then
                    echo -e "${C_YELLOW}Обнаружен Alt PVE (RPM/apt-rpm).${C_NC}"
                    echo -e "На Alt PVE нет схемы enterprise/no-subscription в стиле Debian — состав и адрес"
                    echo -e "репозиториев (/etc/apt/sources.list, строки вида 'rpm [...] ...') задаёт сама"
                    echo -e "сборка Alt PVE. Здесь я лишь обновляю кэш пакетов; если репозиторий недоступен,"
                    echo -e "проверьте строки 'rpm' в /etc/apt/sources.list вручную."
                    apt-get update
                else
                    echo -e "${C_RED}✖ Не удалось определить тип хостовой ОС (не Debian и не Alt) — операция пропущена, чтобы не повредить конфигурацию apt.${C_NC}"
                fi
                ;;
            deps)
                echo -e "${C_GREEN}Развертывание базового арсенала (OVS, zstd, ntfs-3g, dnsmasq)...${C_NC}"
                apt-get update
                COMMON_PKGS="zstd ntfs-3g jq expect wget curl tmux dnsmasq"
                OVS_INSTALLED=0
                for ovs_pkg in openvswitch-switch openvswitch; do
                    if apt-get install -y "$ovs_pkg" $COMMON_PKGS; then
                        OVS_INSTALLED=1
                        break
                    fi
                done
                if [ "$OVS_INSTALLED" -eq 0 ]; then
                    echo -e "${C_RED}✖ Не удалось установить пакет Open vSwitch ни под одним из известных имён (openvswitch-switch/openvswitch).${C_NC}"
                    echo -e "${C_YELLOW}   Проверьте точное имя пакета в вашем репозитории: apt-cache search openvswitch${C_NC}"
                    apt-get install -y $COMMON_PKGS
                fi
                systemctl enable --now openvswitch-switch 2>/dev/null || systemctl enable --now openvswitch 2>/dev/null || \
                    echo -e "${C_YELLOW}⚠ Не удалось включить сервис Open vSwitch автоматически — проверьте имя юнита: systemctl list-unit-files | grep -i vswitch${C_NC}"
                # Proxmox SDN запускает собственные экземпляры dnsmasq (по одному на зону); общий системный dnsmasq не нужен и может занимать порт 53
                systemctl disable --now dnsmasq 2>/dev/null && echo -e "${C_GREEN}Системный dnsmasq отключён (DHCP для SDN-зон запускает сам Proxmox).${C_NC}"
                if [ "$UI_BACKEND" == "text" ]; then
                    apt-get install -y whiptail 2>/dev/null || apt-get install -y newt 2>/dev/null
                fi
                ;;
            download)
                YA_URL=$(ui_inputbox "ЗАГРУЗКА ИЗ ЯНДЕКС.ДИСКА" "Введите публичную ссылку на архив (.tar) с Яндекс.Диска\n(вида https://disk.yandex.ru/d/...):" 10 75)

                if [ -n "$YA_URL" ]; then
                    SUB_DIR=$(ui_inputbox "СТРУКТУРА ХРАНЕНИЯ" "Укажите имя папки для этого модуля (она будет создана внутри $IMG_DIR):\nНапример: DEMO_1, REG_B, REG_D" 10 75 "DEMO_1")

                    [ -z "$SUB_DIR" ] && continue

                    TARGET_DIR="$IMG_DIR/$SUB_DIR"

                    if [ -d "$TARGET_DIR" ] && [ -n "$(find "$TARGET_DIR" -maxdepth 2 -type f -name '*.vma.zst' 2>/dev/null | head -n 1)" ]; then
                        if ! ui_yesno "ПАПКА УЖЕ СОДЕРЖИТ ОБРАЗЫ" "В $TARGET_DIR уже есть образы .vma.zst.\n\nЕсли это комплект ДРУГОГО модуля — новые файлы перезапишут старые с теми же именами, и стенды двух модулей окажутся из одних образов.\n\nВведите другое имя папки (например DEMO_2), если качаете другой модуль.\n\nПродолжить и распаковать в эту папку?" 16 74; then
                            continue
                        fi
                    fi

                    clear
                    echo -e "${C_GREEN}Обращаюсь к API Яндекс.Диска для получения прямой ссылки...${C_NC}"

                    DIRECT_URL=$(curl -s "https://cloud-api.yandex.net/v1/disk/public/resources/download?public_key=$YA_URL" | jq -r .href)

                    if [ "$DIRECT_URL" == "null" ] || [ -z "$DIRECT_URL" ]; then
                        ui_msgbox "ОШИБКА API" "Не удалось получить ссылку.\nПроверьте, что ссылка публичная и файл существует на Диске." 10 60
                        continue
                    fi

                    echo -e "${C_GREEN}Телеметрия получена. Начинаю загрузку боекомплекта...${C_NC}"
                    TEMP_ARCH="/tmp/spetsnaz_bundle.tar"

                    wget --show-progress -O "$TEMP_ARCH" "$DIRECT_URL"

                    if [ -f "$TEMP_ARCH" ]; then
                        echo -e "${C_GREEN}Распаковываю боекомплект в $TARGET_DIR...${C_NC}"

                        mkdir -p "$TARGET_DIR"

                        tar -xvf "$TEMP_ARCH" -C "$TARGET_DIR"
                        rm -f "$TEMP_ARCH"

                        ui_msgbox "УСПЕХ" "Боекомплект успешно загружен и аккуратно распакован в $TARGET_DIR!\n\nМожно переходить к Развертыванию стендов." 10 65
                    else
                        ui_msgbox "ОШИБКА ЗАГРУЗКИ" "Сбой при скачивании файла. Проверьте сетевое соединение." 8 60
                    fi
                fi
                ;;
            usb)
                clear
                echo -e "${C_GREEN}Инициализирую поиск съемных накопителей...${C_NC}"

                USB_DEV=$(lsblk -rno NAME,RM,TYPE | awk '$2==1 && $3=="part" {print $1}' | head -n 1)

                if [ -z "$USB_DEV" ]; then
                    ui_msgbox "ОШИБКА ПОИСКА" "USB-накопитель не найден.\n\nПожалуйста, вставьте флешку в USB-порт сервера, подождите 5 секунд и повторите попытку." 10 60
                    continue
                fi

                if ui_yesno "ОБНАРУЖЕН НАКОПИТЕЛЬ" "Найден USB-диск (/dev/$USB_DEV).\nПриступить к копированию .vma.zst архивов в $IMG_DIR?" 10 60; then
                    echo -e "${C_GREEN}Монтирую /dev/$USB_DEV...${C_NC}"
                    mkdir -p /mnt/usb

                    if mount "/dev/$USB_DEV" /mnt/usb 2>/dev/null; then
                        echo -e "${C_YELLOW}ВНИМАНИЕ: Идет копирование боекомплекта. Не извлекайте флешку!${C_NC}"

                        # Вложенные папки на флешке (DEMO_1/, DEMO_2/…) переносятся как есть — образы разных модулей
                        # с одинаковыми именами не перезаписывают друг друга.
                        (cd /mnt/usb && find . -mindepth 2 -type f -name "*.vma.zst" -exec cp -v --parents {} "$IMG_DIR" \;)
                        # Образы прямо в корне флешки — спрашиваем, в папку какого модуля их положить.
                        if [ -n "$(find /mnt/usb -maxdepth 1 -type f -name '*.vma.zst' 2>/dev/null | head -n 1)" ]; then
                            USB_SUB=$(ui_inputbox "ПАПКА МОДУЛЯ" "Образы лежат прямо в корне флешки.\nВ какую папку модуля их положить (DEMO_1, DEMO_2, REG_B …)?\nПусто — в корень $IMG_DIR (не рекомендуется):" 12 74 "")
                            mkdir -p "$IMG_DIR/$USB_SUB"
                            find /mnt/usb -maxdepth 1 -type f -name "*.vma.zst" -exec cp -v {} "$IMG_DIR/$USB_SUB/" \;
                        fi

                        umount /mnt/usb
                        rmdir /mnt/usb
                        ui_msgbox "УСПЕХ" "Архивы успешно скопированы!\n\nМожно безопасно извлечь флешку из сервера." 8 60
                    else
                        ui_msgbox "ОШИБКА ФАЙЛОВОЙ СИСТЕМЫ" "Не удалось прочитать флешку.\n\nУбедитесь, что она отформатирована в FAT32, NTFS или ext4." 10 60
                    fi
                fi
                ;;
            sdn_net)
                provision_sdn_nat_dhcp
                ;;
            retag)
                retag_existing_pools
                ;;
            ipam_reg)
                auto_register_ipam
                ;;
            aptfix)
                echo -e "${C_RED}=== 🆘 APT: «Size mismatch» / «Hash Sum mismatch» / «Failed to fetch» ===${C_NC}"
                echo -e "\n${C_GREEN}НА ВИРТУАЛЬНОЙ МАШИНЕ (от root), СТРОГО ПО ПОРЯДКУ:${C_NC}\n"
                echo -e "    1.  apt-get clean"
                echo -e "    2.  find /var/lib/apt/lists -type f -delete     (удаляет только файлы, каталог partial остаётся)"
                echo -e "    3.  apt-get update"
                echo -e "\nНе помогло — повторить шаг 3 с отключённым конвейером:"
                echo -e "        apt-get -o Acquire::http::Pipeline-Depth=0 update"
                echo -e "\n${C_YELLOW}ВСЁ ЕЩЁ ОШИБКА — виноват кэш на сервере кэшера (действия эксперта):${C_NC}"
                echo -e "    а) открыть в браузере http://${PROXY_IP:-<IP кэшера>}:3142/acng-report.html (с любой машины той же сети)"
                echo -e "       и в разделе «Expiration» (очистка) отметить галочку «Force the download of index files»,"
                echo -e "       при необходимости ещё «Truncate damaged files immediately»; НЕ отмечать «Purge unreferenced"
                echo -e "       files after scan» и «Validate by file name AND file contents» (опасно / очень медленно);"
                echo -e "       нажать «Start Scan and/or Expiration» и дождаться конца. Если вывод покажет список ненужных файлов —"
                echo -e "       отметить их и нажать «Delete» (или «Delete all unreferenced files» на главной странице отчёта);"
                echo -e "       (на самом кэшере: lynx http://127.0.0.1:3142/acng-report.html; стрелки Вверх/Вниз — по полям,"
                echo -e "        Enter — поставить/снять галочку и нажать кнопку, / — поиск (набрать Expiration), q — выход);"
                echo -e "    б) либо удалить СОДЕРЖИМОЕ каталога зеркала, например:"
                echo -e "           systemctl stop apt-cacher-ng"
                echo -e "           rm -rf /var/cache/apt-cacher-ng/<зеркало>/*"
                echo -e "           chown -R apt-cacher-ng: /var/cache/apt-cacher-ng"
                echo -e "           systemctl start apt-cacher-ng"
                echo -e "       Сам каталог /var/cache/apt-cacher-ng и его подкаталоги верхнего уровня НЕ удалять."
                echo -e "    в) затем снова шаги 1–3 на ВМ."
                echo -e "\n${C_YELLOW}КЭШЕР НЕ ЗАПУСКАЕТСЯ (failed / «Start request repeated too quickly»):${C_NC}"
                echo -e "    1.  Настоящую причину покажет запуск вручную (от пользователя службы; остановка — Ctrl+C):"
                echo -e "           systemctl reset-failed apt-cacher-ng"
                echo -e "           runuser -u apt-cacher-ng -- /usr/sbin/apt-cacher-ng -c /etc/apt-cacher-ng ForeGround=1"
                echo -e "       (нет runuser:  su -s /bin/sh apt-cacher-ng -c '/usr/sbin/apt-cacher-ng -c /etc/apt-cacher-ng ForeGround=1')"
                echo -e "       Журнал и лог кэшера:  journalctl -u apt-cacher-ng -n 50 --no-pager ; tail -n 50 /var/log/apt-cacher-ng/apt-cacher.err"
                echo -e "    2.  Порт занят старым процессом?   ss -ltnp | grep 3142   (убить: pkill apt-cacher-ng)"
                echo -e "    3.  Кончилось место?               df -h /var/cache /var/log ; df -i /var/cache"
                echo -e "    4.  Права и наличие каталогов:     ls -ld /var/cache/apt-cacher-ng /var/log/apt-cacher-ng"
                echo -e "           mkdir -p /var/cache/apt-cacher-ng /var/log/apt-cacher-ng"
                echo -e "           chown -R apt-cacher-ng: /var/cache/apt-cacher-ng /var/log/apt-cacher-ng"
                echo -e "    5.  После исправления:             systemctl reset-failed apt-cacher-ng && systemctl start apt-cacher-ng"
                echo -e "\n${C_YELLOW}Почему не помогает откат на Day0:${C_NC} снапшот возвращает диск ВМ, но не кэш"
                echo -e "кэшера; а если в Day0 остались списки пакетов от другого источника —"
                echo -e "шаги 1–2 нужны и после отката."
                echo -e "\nПатч («Накатить патч») сам выполняет шаги 1–2 на ВМ стенда."
                echo -e "\n${C_YELLOW}ВНИМАНИЕ:${C_NC} НЕ используйте rm -rf /var/lib/apt/lists/* — оно удалит и каталог partial."
                echo -e "Если он уже удалён: mkdir -p /var/lib/apt/lists/partial  (затем apt-get update)."
                ;;
            howto)
                ui_msgbox "ℹ️ ИНФОРМАЦИОННЫЙ БЮЛЛЕТЕНЬ" "Полигон поддерживает принцип BYOI (Bring Your Own Image).\n\nВы можете использовать собственные образы машин. Просто сделайте бэкап вашей ВМ в формате .vma.zst и положите его в директорию $IMG_DIR.\n\nКак перенести файлы без WinSCP:\n1. Загрузите их на любой веб-сервер/Яндекс.Диск и скачайте через меню 'Утилиты -> Скачать по URL (wget)'.\n2. Закиньте на USB-флешку, вставьте в сервер и скопируйте в консоли (cp /media/usb/*.zst $IMG_DIR).\n\nОбязательное условие: Имена файлов должны содержать роли (ISP, HQ-SRV, BR-RTR и т.д.)." 18 75
                ;;
        esac
        echo -e "\n---------------------------------------------------"
        read -n 1 -s -r -p "Операция завершена. Нажми любую клавишу..."
        continue
    fi

    MOD_TYPE=$(ui_menu "ВЫБОР ЗАДАНИЯ" "Укажите тип экзамена/модуля:" 17 75 7 \
        "DEMO_1" "Демоэкзамен: Задание 1" \
        "DEMO_2" "Демоэкзамен: Задание 2" \
        "DEMO_3" "Демоэкзамен: Задание3" \
        "REG_B"  "Рег. чемпионат: Модуль Б" \
        "REG_D"  "Рег. чемпионат: Модуль Д" \
        "REG_A"  "Рег. чемпионат: Модуль А" \
        "GOLD_B" "Золотой эталон (Модуль Б)")

    [ $? -ne 0 ] && continue

    STANDS=$(ui_inputbox "ВЫБОР ЦЕЛЕЙ" "Введите номера стендов (например: 1-10, 12, 15):" 10 70)
    [ $? -ne 0 ] || [ -z "$STANDS" ] && continue

    if [ "$ACTION" == "deploy" ]; then

        if [[ "$MOD_TYPE" == DEMO* ]]; then
            VLAN_CONF=$(ui_inputbox "НАСТРОЙКА VLAN (DEMO)" "Введите теги VLAN через пробел (HQ_SRV HQ_CLI Management):\nПо умолчанию: 100 200 999" 10 70 "100 200 999")
            [ $? -ne 0 ] && continue

            export VLAN_1=$(echo "$VLAN_CONF" | awk '{print $1}')
            export VLAN_2=$(echo "$VLAN_CONF" | awk '{print $2}')
            export VLAN_3=$(echo "$VLAN_CONF" | awk '{print $3}')

            [ -z "$VLAN_1" ] && export VLAN_1=100
            [ -z "$VLAN_2" ] && export VLAN_2=200
            [ -z "$VLAN_3" ] && export VLAN_3=999
        fi
    fi

    if [ "$ACTION" == "destroy" ]; then
        CONFIRM=$(ui_inputbox "!!! УГРОЗА УНИЧТОЖЕНИЯ ДАННЫХ !!!" "Вы собираетесь БЕЗВОЗВРАТНО удалить стенды: [ $STANDS ].\nДля подтверждения введите слово DESTROY:" 12 70)
        if [ "$CONFIRM" != "DESTROY" ]; then
            ui_msgbox "БЛОКИРОВКА" "Защита сработала. Операция отменена." 8 60
            continue
        fi
    fi

    EXPERT_FLAG=""
    if [ "$ACTION" == "patch" ]; then
        if ui_yesno "АВТОРИЗАЦИЯ" "Включить 'Экспертный доступ' (статический IP для ISP/GW)?\n\nДа - Для Главного Эксперта.\nНет - Базовый проброс APT." 10 70; then
            EXPERT_FLAG="--expert-mode"
            expert_net_dialog || { echo -e "${C_YELLOW}Параметры экспертного доступа не заданы — отмена.${C_NC}"; sleep 1; continue; }
        fi
    fi

    clear
    echo -e "${C_GREEN}Инициирую протокол $ACTION для $MOD_TYPE (Стенды: $STANDS)...${C_NC}"
    export MOD_TYPE

    if [[ "$ACTION" == "snapshot" || "$ACTION" == "rollback" || "$ACTION" == "delsnap" ]]; then
        case "$ACTION" in
            snapshot) SNAP_NAME=$(ui_inputbox "СОЗДАНИЕ СНАПШОТА" "Имя нового снапшота (например, Task1 или Check2).\n\nDay0 здесь создавать не нужно: он создаётся автоматически при развёртывании стенда и хранит чистый старт." 12 72 "Task1") ;;
            rollback) SNAP_NAME=$(ui_inputbox "ОТКАТ К СНАПШОТУ" "К какому снапшоту откатить стенды? Day0 — чистый старт, созданный при развёртывании:" 10 72 "Day0") ;;
            *)        SNAP_NAME=$(ui_inputbox "УДАЛЕНИЕ СНАПШОТА" "Имя удаляемого снапшота (например, Task1).\nDay0 лучше не удалять — это чистый старт стенда:" 11 72 "Task1") ;;
        esac

        if [ $? -ne 0 ] || [ -z "$SNAP_NAME" ]; then
            continue
        fi

        if [ "$ACTION" == "rollback" ]; then
            if ! ui_yesno "!!! ВНИМАНИЕ: ОПАСНОСТЬ ПОТЕРИ ДАННЫХ !!!" "Вы собираетесь выполнить ОТКАТ (Rollback) стендов [ $STANDS ] к снапшоту: '$SNAP_NAME'.\n\nВсе несохраненные изменения студентов будут БЕЗВОЗВРАТНО УНИЧТОЖЕНЫ.\n\nПродолжить?" 12 70; then
                ui_msgbox "ОТМЕНА ОПЕРАЦИИ" "Защита сработала. Откат отменен, данные в безопасности." 8 60
                continue
            fi

            CONFIRM_RB=$(ui_inputbox "КОНТРОЛЬНОЕ ПОДТВЕРЖДЕНИЕ" "Для подтверждения катастрофического отката введите слово ROLLBACK:" 10 70)
            if [ "$CONFIRM_RB" != "ROLLBACK" ]; then
                ui_msgbox "БЛОКИРОВКА" "Контрольное слово введено неверно. Операция отменена." 8 60
                continue
            fi
        fi

        export SNAP_NAME
        if [ "$ACTION" == "snapshot" ] && [ "$SNAP_NAME" == "Day0" ]; then
            SNAP_REPLACE=0
            CONFIRM_D0=$(ui_inputbox "DAY0 — СЛУЖЕБНЫЙ СНАПШОТ" "Day0 создаётся при развёртывании и хранит чистый старт стенда.\n\nПо умолчанию он НЕ пересоздаётся: машинам, у которых Day0 уже есть, он пропускается.\n\nЧтобы ПЕРЕЗАПИСАТЬ Day0 текущим состоянием (например, после патча, чтобы чистый старт включал настройки APT/IP), введите слово DAY0. Старый чистый старт будет утрачен. Пусто — не пересоздавать:" 17 76)
            [ "$CONFIRM_D0" == "DAY0" ] && SNAP_REPLACE=1
            export SNAP_REPLACE
        elif [ "$ACTION" == "snapshot" ]; then
            SNAP_REPLACE=0
            ui_yesno "СНАПШОТ '$SNAP_NAME' УЖЕ ЕСТЬ НА МАШИНЕ?" "Если у машины снапшот с именем '$SNAP_NAME' уже существует:\n\nНет — пропустить такую машину (старый снапшот сохранится).\nДа — удалить старый и создать заново (состояние будет записано заново).\n\nПересоздавать существующие снапшоты?" 14 72 && SNAP_REPLACE=1
            export SNAP_REPLACE
        fi
    fi

    if [ "$ACTION" == "rbperm_on" ]; then
        if ! ui_yesno "ОТКАТ ВМ УЧАСТНИКАМИ (ТРЕНИРОВОЧНЫЙ РЕЖИМ)" "Участники стендов [ $STANDS ] смогут сами откатывать СВОИ ВМ к снапшоту (в веб-интерфейсе: ВМ → Snapshots → Rollback).\n\nСоздавать и удалять снапшоты они НЕ смогут.\n\nВАЖНО:\n- только для тренировок, НЕ для демоэкзамена;\n- право привязано к ВМ, а не к имени снапшота: откатиться можно к любому существующему снапшоту (если кроме Day0 есть другие — скрипт предупредит);\n- Day0 хранит состояние на момент развёртывания: настройки патча (APT, IP) после отката пропадут, если Day0 не пересоздан после патча.\n\nВыдать право?" 22 78; then
            ui_msgbox "ОТМЕНА ОПЕРАЦИИ" "Права не изменены." 8 50
            continue
        fi
    fi

    if [ "$ACTION" == "netperm_on" ]; then
        if ! ui_yesno "ПРАВО НА ИЗМЕНЕНИЕ СЕТИ ВМ" "Участники стендов [ $STANDS ] смогут менять VLAN-теги и подключения сетевых адаптеров своих ВМ (только на мостах своего стенда, внешний WAN-мост недоступен).\n\nЭто допустимо, только если задание требует настройки коммутации на уровне гипервизора и решение принято Главным экспертом.\n\nВыдать право?" 14 74; then
            ui_msgbox "ОТМЕНА ОПЕРАЦИИ" "Права не изменены." 8 50
            continue
        fi
    fi

    if [ "$ACTION" == "addrchk" ]; then
        if ui_yesno "ПРОВЕРКА АДРЕСОВ" "Если у какой-то машины не окажется адреса, попробовать перезапустить на ней сеть (systemctl restart network)?\n\nНе делайте этого, пока участники работают на стендах." 12 70; then
            export ADDR_REPAIR=1
        else
            export ADDR_REPAIR=0
        fi
    fi

    if [ "$ACTION" == "start" ]; then
        TAU_CHOICE=$(ui_menu "ПАУЗА МЕЖДУ ЗАПУСКОМ МАШИН (τ)" "Выберите паузу между стартом соседних ВМ.\nЕсли после старта не все машины получают адрес — берите паузу побольше:" 16 80 4 \
        "perf"   "🚀 3 сек  — мощный сервер, NVMe" \
        "mid"    "⚖️ 5 сек  — средний сервер (рекомендуется при пропусках адресов)" \
        "legacy" "🐢 10 сек — слабый сервер, SATA SSD" \
        "custom" "✏️ Своё значение (от 1 до 30 сек)")

        [ -z "$TAU_CHOICE" ] && continue

        case "$TAU_CHOICE" in
            perf)   export TAU_DELAY=3 ;;
            mid)    export TAU_DELAY=5 ;;
            legacy) export TAU_DELAY=10 ;;
            custom)
                TAU_CUSTOM=$(ui_inputbox "СВОЯ ПАУЗА (τ)" "Пауза между стартом машин, секунд (целое число от 1 до 30):" 10 70 "5")
                if [[ "$TAU_CUSTOM" =~ ^[0-9]+$ ]] && [ "$TAU_CUSTOM" -ge 1 ] && [ "$TAU_CUSTOM" -le 30 ]; then
                    export TAU_DELAY=$TAU_CUSTOM
                else
                    ui_msgbox "НЕВЕРНОЕ ЗНАЧЕНИЕ" "Нужно целое число от 1 до 30. Взято значение по умолчанию: 5 сек." 8 66
                    export TAU_DELAY=5
                fi
                ;;
        esac
    fi

    if [ "$ACTION" == "aptdirect" ]; then
        APT_DIRECT=1 $CORE_SCRIPT patch $STANDS
    elif [ "$ACTION" == "deploy" ] || [ "$ACTION" == "patch" ] || [ "$ACTION" == "rotate" ]; then
        $CORE_SCRIPT $ACTION $STANDS $EXPERT_FLAG
    else
        export ACTION
        $CORE_SCRIPT manage $STANDS
    fi

    echo -e "\n---------------------------------------------------"
    read -n 1 -s -r -p "Операция завершена. Нажми любую клавишу для возврата в меню..."
done
