#!/bin/bash
# ==============================================================================
# ИНТЕРФЕЙС ГЛАВНОГО ЭКСПЕРТА
# ==============================================================================

# ==============================================================================
# 🛡️ 1. ЗАЩИТА ОТ ОБРЫВА СВЯЗИ (АВТО-TMUX ОБЕРТКА)
# ==============================================================================
if [ -z "$TMUX" ] && command -v tmux &> /dev/null; then
    tmux has-session -t it_spetsnaz 2>/dev/null
    if [ $? -ne 0 ]; then
        echo -e "\n🐾 [БАГИР]: Обнаружена незащищенная консоль. Создаю автономный контур безопасности (tmux)..."
        sleep 1
        exec tmux new-session -s it_spetsnaz "$0 $@"
    else
        echo -e "\n🐾 [БАГИР]: Подключаюсь к активному контуру ИТ-спецназа..."
        sleep 1
        exec tmux attach-session -t it_spetsnaz
    fi
fi
# ==============================================================================

CORE_SCRIPT="./core"

# ==============================================================================
# 🌍 2. ГЛОБАЛЬНАЯ БОЕВАЯ СРЕДА И МАСТЕР НАСТРОЙКИ (spetsnaz.conf)
# ==============================================================================
export CSV_FILE="credentials_stands.csv"
export FILE_MASK=".vma.zst"
export ISO_TARGET="cloudinit.iso"

export C_GREEN='\033[0;32m'
export C_RED='\033[0;31m'
export C_YELLOW='\033[1;33m'
export C_NC='\033[0m'

CONFIG_FILE="spetsnaz.conf"

if [ -f "$CONFIG_FILE" ]; then
    # Если конфиг существует, просто читаем его (тихий режим)
    source "$CONFIG_FILE"
    echo -e "\n🐾 [БАГИР]: Конфигурация полигона загружена из $CONFIG_FILE"
    sleep 1
else
    # МАСТЕР ПЕРВОНАЧАЛЬНОЙ НАСТРОЙКИ
    whiptail --title "ИТ-СПЕЦНАЗ: МАСТЕР НАСТРОЙКИ" --msgbox "🐾 [БАГИР]: Обнаружен первый запуск.\n\nИнициализирую протокол первоначальной настройки полигона. Сейчас мы зададим базовые параметры (сети, хранилища). Они будут сохранены в файл $CONFIG_FILE и больше не потребуют ввода." 12 75

    DEFAULT_WAN=$(ip route show default | awk '{print $5}' | head -n 1)
    [ -z "$DEFAULT_WAN" ] && DEFAULT_WAN="vmbr0"

    WAN_BR=$(whiptail --title "НАСТРОЙКА СЕТИ (WAN)" --inputbox "Укажите мост/интерфейс с выходом в Интернет (ISP/GW):" 10 75 "$DEFAULT_WAN" 3>&1 1>&2 2>&3)
    [ -z "$WAN_BR" ] && exit 1

    IMG_DIR=$(whiptail --title "ИСТОЧНИК ОБРАЗОВ (BYOI)" --inputbox "Директория с .vma.zst бэкапами:\n\n💡 Подсказка: Вы можете использовать WinSCP, wget или USB-накопитель, чтобы закинуть сюда свои собственные образы стендов. Главное — сохраните стандартные имена (напр. HQ-SRV.vma.zst)!" 12 75 "/zfs-nvme/archives/dump" 3>&1 1>&2 2>&3)
    [ -z "$IMG_DIR" ] && exit 1

    TARGET_STORAGE=$(whiptail --title "ЦЕЛЕВОЕ ХРАНИЛИЩЕ" --inputbox "Укажите ZFS-хранилище (Storage ID):" 10 75 "ZFS-NVME" 3>&1 1>&2 2>&3)
    [ -z "$TARGET_STORAGE" ] && exit 1

    PROXY_IP=$(whiptail --title "КЭШИРУЮЩИЙ ПРОКСИ" --inputbox "IP-адрес APT-кэшера:" 10 75 "10.111.1.200" 3>&1 1>&2 2>&3)

    # Сохраняем все в файл
    echo "WAN_BR=\"$WAN_BR\"" > "$CONFIG_FILE"
    echo "IMG_DIR=\"$IMG_DIR\"" >> "$CONFIG_FILE"
    echo "TARGET_STORAGE=\"$TARGET_STORAGE\"" >> "$CONFIG_FILE"
    echo "PROXY_IP=\"$PROXY_IP\"" >> "$CONFIG_FILE"

    whiptail --title "НАСТРОЙКА ЗАВЕРШЕНА" --msgbox "🐾 [БАГИР]: Конфигурация успешно сохранена!\n\nПолигон готов к работе. Добро пожаловать на командный мостик, Главный Эксперт." 10 60
fi

export WAN_BR IMG_DIR TARGET_STORAGE PROXY_IP
# ==============================================================================

# ♻️ 3. БЕСКОНЕЧНЫЙ БОЕВОЙ ЦИКЛ
while true; do
    # 🐾 БАГИР: Ветвление 1 уровня (Тактические категории)
    MAIN_CAT=$(whiptail --title "ИТ-СПЕЦНАЗ: УПРАВЛЕНИЕ ПОЛИГОНОМ (WAN: $WAN_BR)" --menu "Выберите категорию операций:" 14 75 6 \
    "deploy"   "🚀 Развертывание и Настройка (Деплой, Патч)" \
    "power"    "⚡ Питание стендов (Запуск / Остановка)" \
    "state"    "📷 Управление состоянием (Снапшоты, Откаты)" \
    "system"   "⚙️ Системные утилиты (Подготовка PVE)" \
    "danger"   "☠️ КРИТИЧЕСКОЕ: Удаление полигона" \
    "exit"     "🚪 Выход в консоль" 3>&1 1>&2 2>&3)

    if [ $? -ne 0 ] || [ "$MAIN_CAT" == "exit" ]; then
        echo -e "\n🐾 [БАГИР]: Системы переведены в ждущий режим. До связи!"
        break
    fi

    # Ветвление 2 уровня
    ACTION=""
    case "$MAIN_CAT" in
        deploy)
            ACTION=$(whiptail --title "РАЗВЕРТЫВАНИЕ И НАСТРОЙКА" --menu "Выберите операцию:" 12 75 3 \
            "deploy" "🚀 Развернуть новые стенды" \
            "patch"  "💉 Накатить инфраструктурный патч (APT/IP)" \
            "rotate" "🔑 Ротация паролей (Протокол День С)" 3>&1 1>&2 2>&3)
            ;;
        power)
            ACTION=$(whiptail --title "УПРАВЛЕНИЕ ПИТАНИЕМ" --menu "Выберите операцию:" 14 75 4 \
            "start"    "▶️ Каскадный старт (τ-задержка для слабых серверов)" \
            "stop"     "⏹️ Жесткая остановка (Power Off)" \
            "shutdown" "🔌 Мягкое выключение (ACPI Shutdown)" \
            "reboot"   "🔄 Перезагрузка стендов" 3>&1 1>&2 2>&3)
            ;;
        state)
            ACTION=$(whiptail --title "СОСТОЯНИЕ И ДОСТУП" --menu "Выберите операцию:" 15 75 5 \
            "snapshot" "📷 Создать снапшот (Day0, Task1 и т.д.)" \
            "rollback" "⏪ Откат к снапшоту (Внимание!)" \
            "delsnap"  "🗑️ Удалить конкретный снапшот" \
            "lock"     "🔒 Заблокировать студентам доступ" \
            "unlock"   "🔓 Разблокировать доступ" 3>&1 1>&2 2>&3)
            ;;
        system)
            ACTION=$(whiptail --title "СИСТЕМНЫЕ УТИЛИТЫ" --menu "Выберите операцию:" 12 75 2 \
            "utils"  "🛠️ Утилиты хоста (apt, OVS, загрузка)" \
            "reconf" "⚙️ Перенастройка (Сброс spetsnaz.conf)" 3>&1 1>&2 2>&3)
            ;;
        danger)
            # Прямой проброс без подменю, защита сработает дальше по коду
            ACTION="destroy"
            ;;
    esac

    # Если эксперт нажал "Отмена" в подменю — мягко возвращаемся в главное меню
    [ -z "$ACTION" ] && continue

    # ==========================================================================
    # ⚙️ ПЕРЕНАСТРОЙКА ПОЛИГОНА (СБРОС КОНФИГУРАЦИИ)
    # ==========================================================================
    if [ "$ACTION" == "reconf" ]; then
        if whiptail --title "СБРОС КОНФИГУРАЦИИ" --yesno "Вы собираетесь уничтожить текущий файл $CONFIG_FILE.\n\nВсе базовые параметры (WAN-мост, ZFS-хранилище, IP-прокси) будут стерты, а Мастер настройки запустится заново.\n\nПродолжить?" 10 70; then
            rm -f "$CONFIG_FILE"
            echo -e "\n🐾 [БАГИР]: Старая конфигурация стерта. Инициирую перезагрузку оболочки..."
            sleep 1
            # Подменяем текущий процесс новым запуском самого себя
            exec "$0" "$@"
        fi
        continue
    fi

    # ==========================================================================
    # БЛОК УТИЛИТ (ПОДГОТОВКА ГИПЕРВИЗОРА)
    # ==========================================================================
    if [ "$ACTION" == "utils" ]; then
        UTIL_ACTION=$(whiptail --title "ПОДГОТОВКА ХОСТА PVE" --menu "Выберите действие:" 0 0 0 \
            "fix_repo" "1️⃣ Отключить PVE-Enterprise (Починить apt)" \
            "deps"     "2️⃣ Установить базу: OVS, jq, expect, zstd" \
            "download" "3️⃣ Скачать бэкапы шаблонов (.vma.zst) по URL" \
            "howto"    "ℹ️ СПРАВКА: Как загрузить свои образы?" \
            "usb" "4️⃣ Загрузить образы с USB-флешки" \
            "back"     "🔙 Вернуться в главное меню" 3>&1 1>&2 2>&3)

        clear
        case $UTIL_ACTION in
            fix_repo)
                echo -e "${C_GREEN}🐾 [БАГИР]: Отключаем платный репозиторий Proxmox...${C_NC}"
                sed -i 's/^deb/#deb/g' /etc/apt/sources.list.d/pve-enterprise.list 2>/dev/null
                rm -f /etc/apt/sources.list.d/tailscale.list /etc/apt/sources.list.d/netbird.list /etc/apt/sources.list.d/netdata.list 2>/dev/null
                rm -f /etc/apt/sources.list.d/pve-no-subscription.list 2>/dev/null
                if ! grep -q "pve-no-subscription" /etc/apt/sources.list; then
                    echo -e "\n# Free PVE Repository\ndeb http://download.proxmox.com/debian/pve $(grep -oP 'VERSION_CODENAME=\K\w+' /etc/os-release) pve-no-subscription" >> /etc/apt/sources.list
                fi
                apt-get clean && apt-get update
                ;;
            deps)
                echo -e "${C_GREEN}🐾 [БАГИР]: Развертывание базового арсенала (OVS, zstd, ntfs-3g)...${C_NC}"
                # Ставим zstd для быстрой распаковки и ntfs-3g для чтения Windows-флешек экспертов
                apt-get update && apt-get install -y openvswitch-switch zstd ntfs-3g jq expect wget curl tmux
                systemctl enable --now openvswitch-switch
                ;;
            download)
                YA_URL=$(whiptail --title "ЗАГРУЗКА ИЗ ЯНДЕКС.ДИСКА" --inputbox "Введите публичную ссылку на архив (.tar) с Яндекс.Диска\n(вида https://disk.yandex.ru/d/...):" 10 75 3>&1 1>&2 2>&3)

                if [ -n "$YA_URL" ]; then
                    # Спрашиваем, как назвать подпапку для идеального порядка
                    SUB_DIR=$(whiptail --title "СТРУКТУРА ХРАНЕНИЯ" --inputbox "Укажите имя папки для этого модуля (она будет создана внутри $IMG_DIR):\nНапример: DEMO_1, REG_B, REG_D" 10 75 "DEMO_1" 3>&1 1>&2 2>&3)

                    [ -z "$SUB_DIR" ] && continue

                    TARGET_DIR="$IMG_DIR/$SUB_DIR"

                    clear
                    echo -e "${C_GREEN}🐾 [БАГИР]: Обращаюсь к API Яндекс.Диска для получения прямой ссылки...${C_NC}"

                    DIRECT_URL=$(curl -s "https://cloud-api.yandex.net/v1/disk/public/resources/download?public_key=$YA_URL" | jq -r .href)

                    if [ "$DIRECT_URL" == "null" ] || [ -z "$DIRECT_URL" ]; then
                        whiptail --title "ОШИБКА API" --msgbox "🐾 [БАГИР]: Не удалось получить ссылку.\nПроверьте, что ссылка публичная и файл существует на Диске." 10 60
                        continue
                    fi

                    echo -e "${C_GREEN}🐾 [БАГИР]: Телеметрия получена. Начинаю загрузку боекомплекта...${C_NC}"
                    TEMP_ARCH="/tmp/spetsnaz_bundle.tar"

                    wget --show-progress -O "$TEMP_ARCH" "$DIRECT_URL"

                    if [ -f "$TEMP_ARCH" ]; then
                        echo -e "${C_GREEN}🐾 [БАГИР]: Распаковываю боекомплект в $TARGET_DIR...${C_NC}"

                        # Создаем аккуратную подпапку
                        mkdir -p "$TARGET_DIR"

                        # Извлекаем все .vma.zst прямо в целевую подпапку
                        tar -xvf "$TEMP_ARCH" -C "$TARGET_DIR"
                        rm -f "$TEMP_ARCH"

                        whiptail --title "УСПЕХ" --msgbox "Боекомплект успешно загружен и аккуратно распакован в $TARGET_DIR!\n\nМожно переходить к Развертыванию стендов." 10 65
                    else
                        whiptail --title "ОШИБКА ЗАГРУЗКИ" --msgbox "Сбой при скачивании файла. Проверьте сетевое соединение." 8 60
                    fi
                fi
                ;;
            usb)
                clear
                echo -e "${C_GREEN}🐾 [БАГИР]: Инициализирую поиск съемных накопителей...${C_NC}"

                # Ищем разделы на съемных дисках (RM=1)
                USB_DEV=$(lsblk -rno NAME,RM,TYPE | awk '$2==1 && $3=="part" {print $1}' | head -n 1)

                if [ -z "$USB_DEV" ]; then
                    whiptail --title "ОШИБКА ПОИСКА" --msgbox "🐾 [БАГИР]: USB-накопитель не найден.\n\nПожалуйста, вставьте флешку в USB-порт сервера, подождите 5 секунд и повторите попытку." 10 60
                    continue
                fi

                if whiptail --title "ОБНАРУЖЕН НАКОПИТЕЛЬ" --yesno "Найден USB-диск (/dev/$USB_DEV).\nПриступить к копированию .vma.zst архивов в $IMG_DIR?" 10 60; then
                    echo -e "${C_GREEN}🐾 [БАГИР]: Монтирую /dev/$USB_DEV...${C_NC}"
                    mkdir -p /mnt/usb

                    # Пытаемся смонтировать (благодаря ntfs-3g проглотит почти всё)
                    if mount "/dev/$USB_DEV" /mnt/usb 2>/dev/null; then
                        echo -e "${C_YELLOW}ВНИМАНИЕ: Идет копирование боекомплекта. Не извлекайте флешку!${C_NC}"

                        # Ищем и копируем все vma.zst с флешки в папку назначения
                        find /mnt/usb -type f -name "*.vma.zst" -exec cp -v {} "$IMG_DIR" \;

                        # Мягко отмонтируем
                        umount /mnt/usb
                        rmdir /mnt/usb
                        whiptail --title "УСПЕХ" --msgbox "Архивы успешно скопированы!\n\nМожно безопасно извлечь флешку из сервера." 8 60
                    else
                        whiptail --title "ОШИБКА ФАЙЛОВОЙ СИСТЕМЫ" --msgbox "Не удалось прочитать флешку.\n\nУбедитесь, что она отформатирована в FAT32, NTFS или ext4." 10 60
                    fi
                fi
                ;;
            howto)
            whiptail --title "ℹ️ ИНФОРМАЦИОННЫЙ БЮЛЛЕТЕНЬ" --msgbox "🐾 [БАГИР]: Полигон поддерживает принцип BYOI (Bring Your Own Image).\n\nВы можете использовать собственные образы машин. Просто сделайте бэкап вашей ВМ в формате .vma.zst и положите его в директорию $IMG_DIR.\n\nКак перенести файлы без WinSCP:\n1. Загрузите их на любой веб-сервер/Яндекс.Диск и скачайте через меню 'Утилиты -> Скачать по URL (wget)'.\n2. Закиньте на USB-флешку, вставьте в сервер и скопируйте в консоли (cp /media/usb/*.zst $IMG_DIR).\n\nОбязательное условие: Имена файлов должны содержать роли (ISP, HQ-SRV, BR-RTR и т.д.)." 18 75
                ;;


        esac
        echo -e "\n---------------------------------------------------"
        read -n 1 -s -r -p "🐾 Операция завершена. Нажми любую клавишу..."
        continue
    fi

    # ==========================================================================
    # ОСНОВНАЯ ЛОГИКА (ДЕПЛОЙ И УПРАВЛЕНИЕ)
    # ==========================================================================
    MOD_TYPE=$(whiptail --title "ВЫБОР ЗАДАНИЯ" --menu "Укажите тип экзамена/модуля:" 0 0 0 \
        "DEMO_1" "Демоэкзамен: Задание 1" \
        "DEMO_2" "Демоэкзамен: Задание 2 / 3" \
        "REG_B"  "Рег. чемпионат: Модуль Б" \
        "REG_D"  "Рег. чемпионат: Модуль Д" \
        "REG_A"  "Рег. чемпионат: Модуль А" \
        "GOLD_B" "Золотой эталон (Модуль Б)" 3>&1 1>&2 2>&3)

    [ $? -ne 0 ] && continue

    STANDS=$(whiptail --title "ВЫБОР ЦЕЛЕЙ" --inputbox "Введите номера стендов (например: 1-10, 12, 15):" 10 70 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] || [ -z "$STANDS" ] && continue

    if [ "$ACTION" == "deploy" ]; then

        # 🐾 БАГИР: Запрос VLAN строго изолирован внутри логики развертывания!
        if [[ "$MOD_TYPE" == DEMO* ]]; then
            VLAN_CONF=$(whiptail --title "НАСТРОЙКА VLAN (DEMO)" --inputbox "Введите теги VLAN через пробел (HQ_SRV HQ_CLI Management):\nПо умолчанию: 100 200 999" 10 70 "100 200 999" 3>&1 1>&2 2>&3)
            [ $? -ne 0 ] && continue

            export VLAN_1=$(echo "$VLAN_CONF" | awk '{print $1}')
            export VLAN_2=$(echo "$VLAN_CONF" | awk '{print $2}')
            export VLAN_3=$(echo "$VLAN_CONF" | awk '{print $3}')

            # Защита от пустых значений
            [ -z "$VLAN_1" ] && export VLAN_1=100
            [ -z "$VLAN_2" ] && export VLAN_2=200
            [ -z "$VLAN_3" ] && export VLAN_3=999
        fi
    fi

    if [ "$ACTION" == "destroy" ]; then
        CONFIRM=$(whiptail --title "!!! УГРОЗА УНИЧТОЖЕНИЯ ДАННЫХ !!!" --inputbox \
        "Вы собираетесь БЕЗВОЗВРАТНО удалить стенды: [ $STANDS ].\nДля подтверждения введите слово DESTROY:" 12 70 3>&1 1>&2 2>&3)
        if [ "$CONFIRM" != "DESTROY" ]; then
            whiptail --title "БЛОКИРОВКА" --msgbox "Защита сработала. Операция отменена." 8 60
            continue
        fi
    fi

    AKELA_FLAG=""
    if [ "$ACTION" == "patch" ]; then
        if whiptail --title "АВТОРИЗАЦИЯ" --yesno "Применить 'Режим Бога' (статика для ISP/GW)?\n\nДа - Для Главного Эксперта.\nНет - Базовый проброс APT." 10 70; then
            AKELA_FLAG="--akela"
        fi
    fi

    clear
    echo -e "${C_GREEN}🐾 [БАГИР]: Инициирую протокол $ACTION для $MOD_TYPE (Стенды: $STANDS)...${C_NC}"
    export MOD_TYPE

    # ==========================================================================
    # 📷 РАБОТА СО СНАПШОТАМИ И ЗАЩИТА ОТ КАТАСТРОФ (ROLLBACK)
    # ==========================================================================
    if [[ "$ACTION" == "snapshot" || "$ACTION" == "rollback" || "$ACTION" == "delsnap" ]]; then
        SNAP_NAME=$(whiptail --title "УПРАВЛЕНИЕ СОСТОЯНИЕМ" --inputbox "Укажите имя снапшота (например, Day0 или Task1):" 10 70 "Day0" 3>&1 1>&2 2>&3)

        if [ $? -ne 0 ] || [ -z "$SNAP_NAME" ]; then
            continue
        fi

        # 🐾 БАГИР: Двойной контур защиты для отката (Rollback Guard)
        if [ "$ACTION" == "rollback" ]; then
            # Рубеж 1: Тревожное предупреждение
            if ! whiptail --title "!!! ВНИМАНИЕ: ОПАСНОСТЬ ПОТЕРИ ДАННЫХ !!!" --yesno "Вы собираетесь выполнить ОТКАТ (Rollback) стендов [ $STANDS ] к снапшоту: '$SNAP_NAME'.\n\nВсе несохраненные изменения студентов будут БЕЗВОЗВРАТНО УНИЧТОЖЕНЫ.\n\nПродолжить?" 12 70; then
                whiptail --title "ОТМЕНА ОПЕРАЦИИ" --msgbox "Защита сработала. Откат отменен, данные в безопасности." 8 60
                continue
            fi

            # Рубеж 2: Ввод контрольного слова
            CONFIRM_RB=$(whiptail --title "КОНТРОЛЬНОЕ ПОДТВЕРЖДЕНИЕ" --inputbox "Для подтверждения катастрофического отката введите слово ROLLBACK:" 10 70 3>&1 1>&2 2>&3)
            if [ "$CONFIRM_RB" != "ROLLBACK" ]; then
                whiptail --title "БЛОКИРОВКА" --msgbox "Контрольное слово введено неверно. Операция отменена." 8 60
                continue
            fi
        fi

        export SNAP_NAME
    fi

    # ==========================================================================
    # ⚡ ПРОФИЛИРОВАНИЕ НАГРУЗКИ ПРИ СТАРТЕ (Защита от I/O Storm)
    # ==========================================================================
    if [ "$ACTION" == "start" ]; then
        TAU_CHOICE=$(whiptail --title "ПРОФИЛЬ НАГРУЗКИ (τ-задержка)" --menu "Выберите профиль оборудования для старта ВМ:" 14 75 2 \
        "perf"   "🚀 Performance (Мощный сервер, NVMe) -> τ = 3 сек" \
        "legacy" "🐢 Balanced (Слабый сервер, SATA SSD) -> τ = 10 сек" 3>&1 1>&2 2>&3)

        # Если нажали Отмену — прерываем операцию и возвращаемся в меню
        [ -z "$TAU_CHOICE" ] && continue

        if [ "$TAU_CHOICE" == "perf" ]; then
            export TAU_DELAY=3
        else
            export TAU_DELAY=10
        fi
    fi

    # ==========================================================================
    # 🚀 ВЫЗОВ ЯДРА (ВОССТАНОВЛЕНО)
    # ==========================================================================
    if [ "$ACTION" == "deploy" ] || [ "$ACTION" == "patch" ] || [ "$ACTION" == "rotate" ]; then
        $CORE_SCRIPT $ACTION $STANDS $AKELA_FLAG
    else
        export ACTION
        $CORE_SCRIPT manage $STANDS
    fi

    echo -e "\n---------------------------------------------------"
    read -n 1 -s -r -p "🐾 Операция завершена. Нажми любую клавишу для возврата в меню..."
done

