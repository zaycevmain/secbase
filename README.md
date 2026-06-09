# Базовая настройка сетевой безопасности сервера

Полная пошаговая инструкция: пользователи, SSH, UFW, fail2ban, отключение автообновлений.

---

## Содержание

| # | Раздел |
|---|--------|
| 1 | [Установка скрипта admuser.sh](#часть-1-установка-скрипта-admusersh) |
| 2 | [Создание административного пользователя](#часть-2-создание-административного-пользователя) |
| 3 | [Настройка SSH](#часть-3-настройка-ssh-безопасность) |
| 4 | [Проверка SSH](#часть-4-проверка-ssh-в-новом-терминале) |
| 5 | [Настройка фаервола (UFW)](#часть-5-настройка-фаервола-ufw) |
| 6 | [Настройка fail2ban](#часть-6-настройка-fail2ban-защита-от-брутфорса) |
| 7 | [Итоговая проверка](#часть-7-итоговая-проверка) |
| 8 | [Отключение автообновлений (off-update.sh)](#часть-8-отключение-автоматических-обновлений) |
| 9 | [Справочная информация](#часть-9-справочная-информация) |

---

## Ожидаемый результат

| Возможность | Статус |
|-------------|--------|
| Вход по SSH для обычного пользователя | ✅ порт `7722`, только по ключу |
| Вход root через SSH | ❌ запрещён |
| Вход по паролю через SSH | ❌ запрещён |
| Лимит попыток входа | ✅ 3 попытки (`MaxAuthTries`) |
| Защита от брутфорса (fail2ban) | ✅ блокировка на 1 час |
| Использование sudo | ✅ работает |
| Переключение в root через `sudo su -` | ✅ работает |
| Фаервол | ✅ включён |
| Автоматические обновления | ❌ отключены (ручной контроль) |

---

## Часть 1. Установка скрипта admuser.sh

Скрипт управления пользователями: [admuser.sh](admuser.sh)

### 1.1 Создание файла

```bash
touch /usr/local/bin/admuser.sh
```

### 1.2 Редактирование

```bash
nano /usr/local/bin/admuser.sh
```

### 1.3 Содержимое скрипта

<details>
<summary>Развернуть код admuser.sh</summary>

```bash
#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Этот скрипт нужно запускать от root: sudo ./admin_user_tool.sh"
  exit 1
fi

SUDOERS_DIR="/etc/sudoers.d"

pause() {
  read -r -p "Нажмите Enter для продолжения..."
}

print_header() {
  clear || true
  echo "=============================================="
  echo "  User Admin Tool (Linux)"
  echo "=============================================="
}

user_exists() {
  local username="$1"
  id "$username" >/dev/null 2>&1
}

get_home_dir() {
  local username="$1"
  getent passwd "$username" | cut -d: -f6
}

validate_username() {
  local username="$1"
  [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

create_user_interactive() {
  local username
  read -r -p "Введите имя нового пользователя: " username

  if ! validate_username "$username"; then
    echo "Некорректное имя пользователя."
    echo "Разрешено: a-z, 0-9, _, - ; начинаться должно с буквы/_."
    pause
    return
  fi

  if user_exists "$username"; then
    echo "Пользователь '$username' уже существует."
    pause
    return
  fi

  echo "Создаю пользователя '$username'..."
  adduser "$username"

  read -r -p "Добавить пользователя в группу sudo? [y/N]: " add_sudo
  if [[ "${add_sudo,,}" == "y" ]]; then
    usermod -aG sudo "$username"
    echo "Пользователь '$username' добавлен в sudo."
  fi

  read -r -p "Добавить SSH-ключ прямо сейчас? [y/N]: " add_key
  if [[ "${add_key,,}" == "y" ]]; then
    add_ssh_key_for_user "$username"
  fi

  read -r -p "Сгенерировать SSH-ключи для пользователя прямо сейчас? [y/N]: " gen_key
  if [[ "${gen_key,,}" == "y" ]]; then
    generate_ssh_keypair_for_user "$username"
  fi

  echo "Готово."
  pause
}

ensure_user_ssh_dir() {
  local username="$1"
  local home_dir
  home_dir="$(get_home_dir "$username")"
  if [[ -z "$home_dir" || ! -d "$home_dir" ]]; then
    echo "Не удалось определить home-dir пользователя '$username'."
    return 1
  fi
  install -d -m 700 -o "$username" -g "$username" "$home_dir/.ssh"
  touch "$home_dir/.ssh/authorized_keys"
  chown "$username:$username" "$home_dir/.ssh/authorized_keys"
  chmod 600 "$home_dir/.ssh/authorized_keys"
  echo "$home_dir"
}

add_ssh_key_for_user() {
  local username="${1:-}"
  if [[ -z "$username" ]]; then
    read -r -p "Введите пользователя: " username
  fi

  if ! user_exists "$username"; then
    echo "Пользователь '$username' не найден."
    pause
    return
  fi

  local home_dir
  if ! home_dir="$(ensure_user_ssh_dir "$username")"; then
    pause
    return
  fi

  local key
  echo "Вставьте открытый SSH-ключ одной строкой (ssh-ed25519/ssh-rsa ...):"
  read -r key

  if [[ ! "$key" =~ ^ssh-(ed25519|rsa|ecdsa) ]]; then
    echo "Похоже, это не SSH public key."
    pause
    return
  fi

  if grep -qxF "$key" "$home_dir/.ssh/authorized_keys"; then
    echo "Ключ уже есть у пользователя '$username'."
  else
    echo "$key" >> "$home_dir/.ssh/authorized_keys"
    echo "Ключ добавлен."
  fi
  pause
}

generate_ssh_keypair_for_user() {
  local username="${1:-}"
  if [[ -z "$username" ]]; then
    read -r -p "Введите пользователя: " username
  fi

  if ! user_exists "$username"; then
    echo "Пользователь '$username' не найден."
    pause
    return
  fi

  local home_dir
  if ! home_dir="$(ensure_user_ssh_dir "$username")"; then
    pause
    return
  fi

  local ssh_dir key_name key_type key_comment priv_path pub_path
  ssh_dir="$home_dir/.ssh"
  key_name="id_ed25519_generated"
  key_type="ed25519"
  key_comment="${username}@$(hostname)-generated"

  read -r -p "Имя файлов ключа [${key_name}]: " user_key_name
  if [[ -n "${user_key_name:-}" ]]; then
    key_name="$user_key_name"
  fi
  read -r -p "Тип ключа (ed25519/rsa) [${key_type}]: " user_key_type
  if [[ -n "${user_key_type:-}" ]]; then
    key_type="$user_key_type"
  fi
  if [[ "$key_type" != "ed25519" && "$key_type" != "rsa" ]]; then
    echo "Поддерживаются только ed25519 и rsa."
    pause
    return
  fi

  priv_path="$ssh_dir/$key_name"
  pub_path="$priv_path.pub"

  if [[ -e "$priv_path" || -e "$pub_path" ]]; then
    echo "Файлы ключей уже существуют: $priv_path(.pub)"
    pause
    return
  fi

  if [[ "$key_type" == "ed25519" ]]; then
    ssh-keygen -t ed25519 -C "$key_comment" -N "" -f "$priv_path" >/dev/null
  else
    ssh-keygen -t rsa -b 4096 -C "$key_comment" -N "" -f "$priv_path" >/dev/null
  fi
  chown "$username:$username" "$priv_path" "$pub_path"
  chmod 600 "$priv_path"
  chmod 644 "$pub_path"

  read -r -p "Добавить сгенерированный public key в authorized_keys? [Y/n]: " add_auth
  if [[ "${add_auth,,}" != "n" ]]; then
    cat "$pub_path" >> "$ssh_dir/authorized_keys"
    sort -u "$ssh_dir/authorized_keys" -o "$ssh_dir/authorized_keys"
    chown "$username:$username" "$ssh_dir/authorized_keys"
    chmod 600 "$ssh_dir/authorized_keys"
    echo "Public key добавлен в authorized_keys."
  fi

  echo
  echo "Ключи созданы:"
  echo " - Private: $priv_path"
  echo " - Public : $pub_path"
  echo
  echo "ВАЖНО: передайте пользователю ТОЛЬКО private key безопасным каналом."
  echo "Public key можно хранить на сервере."
  pause
}

change_user_password() {
  local username
  read -r -p "Введите пользователя: " username
  if ! user_exists "$username"; then
    echo "Пользователь '$username' не найден."
    pause
    return
  fi
  echo "Сейчас будет запуск passwd для '$username'."
  passwd "$username"
  pause
}

lock_user_account() {
  local username
  read -r -p "Введите пользователя для блокировки: " username
  if ! user_exists "$username"; then
    echo "Пользователь '$username' не найден."
    pause
    return
  fi
  if [[ "$username" == "root" ]]; then
    echo "Блокировка root запрещена."
    pause
    return
  fi
  usermod -L "$username"
  passwd -l "$username" >/dev/null 2>&1 || true
  echo "Пользователь '$username' заблокирован."
  pause
}

unlock_user_account() {
  local username
  read -r -p "Введите пользователя для разблокировки: " username
  if ! user_exists "$username"; then
    echo "Пользователь '$username' не найден."
    pause
    return
  fi
  usermod -U "$username"
  passwd -u "$username" >/dev/null 2>&1 || true
  echo "Пользователь '$username' разблокирован."
  pause
}

export_users_report() {
  local report_file ts
  ts="$(date +%Y%m%d_%H%M%S)"
  report_file="/root/users_report_${ts}.txt"

  {
    echo "User report generated: $(date -Is)"
    echo "Hostname: $(hostname)"
    echo
    echo "== Users (bash/sh/zsh) =="
    awk -F: '($7 ~ /\/(bash|sh|zsh)$/) {printf "%-20s uid=%s gid=%s home=%s shell=%s\n",$1,$3,$4,$6,$7}' /etc/passwd
    echo
    echo "== Sudo group =="
    getent group sudo
    echo
    echo "== /etc/sudoers.d files =="
    ls -la "$SUDOERS_DIR" 2>/dev/null || true
    echo
    echo "== SSH authorized_keys presence =="
    while IFS=: read -r u _ _ _ _ h s; do
      [[ "$s" =~ /(bash|sh|zsh)$ ]] || continue
      if [[ -f "$h/.ssh/authorized_keys" ]]; then
        cnt="$(wc -l < "$h/.ssh/authorized_keys" | tr -d ' ')"
        echo "$u : authorized_keys lines=$cnt"
      else
        echo "$u : authorized_keys missing"
      fi
    done < /etc/passwd
  } > "$report_file"

  chmod 600 "$report_file"
  echo "Отчет сохранен: $report_file"
  pause
}

list_users() {
  echo "Пользователи с shell (/bin/bash, /bin/sh, /bin/zsh):"
  awk -F: '($7 ~ /\/(bash|sh|zsh)$/) {printf " - %-20s uid=%s home=%s shell=%s\n",$1,$3,$6,$7}' /etc/passwd
  echo
  echo "Пользователи в группе sudo:"
  getent group sudo | awk -F: '{print ($4=="" ? " - (пусто)" : " - "$4)}'
  pause
}

show_user_keys() {
  local username
  read -r -p "Введите пользователя: " username

  if ! user_exists "$username"; then
    echo "Пользователь '$username' не найден."
    pause
    return
  fi

  local home_dir auth_file
  home_dir="$(getent passwd "$username" | cut -d: -f6)"
  auth_file="$home_dir/.ssh/authorized_keys"

  if [[ ! -f "$auth_file" ]]; then
    echo "Файл ключей отсутствует: $auth_file"
    pause
    return
  fi

  echo "Ключи пользователя '$username':"
  nl -ba "$auth_file"
  pause
}

remove_user_interactive() {
  local username
  read -r -p "Введите пользователя для удаления: " username

  if [[ "$username" == "root" ]]; then
    echo "Удаление root запрещено."
    pause
    return
  fi

  if ! user_exists "$username"; then
    echo "Пользователь '$username' не найден."
    pause
    return
  fi

  read -r -p "Удалить вместе с home-директорией? [y/N]: " delete_home
  read -r -p "Точно удалить '$username'? [type username]: " confirm
  if [[ "$confirm" != "$username" ]]; then
    echo "Подтверждение не совпало. Отмена."
    pause
    return
  fi

  if [[ "${delete_home,,}" == "y" ]]; then
    userdel -r "$username"
    echo "Пользователь '$username' и его home удалены."
  else
    userdel "$username"
    echo "Пользователь '$username' удалён (home сохранен)."
  fi

  rm -f "$SUDOERS_DIR/$username" || true
  pause
}

grant_nopasswd_sudo() {
  local username
  read -r -p "Введите пользователя: " username

  if ! user_exists "$username"; then
    echo "Пользователь '$username' не найден."
    pause
    return
  fi

  usermod -aG sudo "$username"
  echo "$username ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_DIR/$username"
  chmod 440 "$SUDOERS_DIR/$username"

  if visudo -cf "$SUDOERS_DIR/$username" >/dev/null; then
    echo "NOPASSWD sudo настроен для '$username'."
  else
    echo "Ошибка в sudoers файле, откатываю изменения."
    rm -f "$SUDOERS_DIR/$username"
  fi
  pause
}

revoke_nopasswd_sudo() {
  local username
  read -r -p "Введите пользователя: " username
  rm -f "$SUDOERS_DIR/$username"
  echo "NOPASSWD правило удалено (если существовало)."
  pause
}

show_main_menu() {
  print_header
  cat <<'EOF'
1) Создать пользователя (опционально sudo + SSH ключ)
2) Добавить SSH ключ пользователю
3) Сгенерировать SSH-ключи для пользователя (private+public)
4) Показать всех пользователей и sudo-группу
5) Показать authorized_keys пользователя
6) Сменить пароль пользователя
7) Заблокировать пользователя
8) Разблокировать пользователя
9) Удалить пользователя
10) Выдать NOPASSWD sudo пользователю
11) Убрать NOPASSWD sudo у пользователя
12) Экспорт отчета по пользователям в /root
0) Выход
EOF
  echo
}

while true; do
  show_main_menu
  read -r -p "Выберите пункт: " choice
  case "$choice" in
    1) create_user_interactive ;;
    2) add_ssh_key_for_user ;;
    3) generate_ssh_keypair_for_user ;;
    4) list_users ;;
    5) show_user_keys ;;
    6) change_user_password ;;
    7) lock_user_account ;;
    8) unlock_user_account ;;
    9) remove_user_interactive ;;
    10) grant_nopasswd_sudo ;;
    11) revoke_nopasswd_sudo ;;
    12) export_users_report ;;
    0) echo "Выход."; exit 0 ;;
    *) echo "Неизвестный пункт."; pause ;;
  esac
done
```

</details>

### 1.4 Права на выполнение

```bash
sudo chmod +x /usr/local/bin/admuser.sh
```

---

## Часть 2. Создание административного пользователя

### 2.1 Запуск скрипта от root

```bash
sudo /usr/local/bin/admuser.sh
```

В меню скрипта:

| Шаг | Действие |
|-----|----------|
| 1 | Пункт **1** — создать пользователя |
| 2 | Имя, например `admin` |
| 3 | Добавить в sudo? **y** |
| 4 | Добавить SSH-ключ? **y** (вставить публичный ключ) |
| 5 | Сгенерировать SSH-ключи? **n** |
| 6 | Пункт **0** — выход |

### 2.2 Выход из root и вход под новым пользователем

```bash
exit
```

```bash
ssh admin@<IP-адрес-сервера>
```

---

## Часть 3. Настройка SSH (безопасность)

### 3.1 Редактирование конфига

```bash
sudo nano /etc/ssh/sshd_config
```

### 3.2 Параметры

Добавьте или измените строки:

```bash
Port 7722
PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
MaxSessions 4
ClientAliveInterval 300
ClientAliveCountMax 2
```

### 3.3 Проверка синтаксиса

```bash
sudo sshd -t
```

### 3.4 Перезапуск SSH

```bash
sudo systemctl restart sshd
```

### Справка по параметрам

| Параметр | Значение | Назначение |
|----------|----------|------------|
| `Port 7722` | нестандартный порт | меньше сканеров и брутфорса |
| `PermitRootLogin no` | запрет root | вход под root по SSH невозможен |
| `PasswordAuthentication no` | только ключи | защита от подбора пароля |
| `MaxAuthTries 3` | 3 попытки | разрыв соединения после неудач |
| `MaxSessions 4` | 4 сессии | ограничение нагрузки |
| `ClientAliveInterval 300` | каждые 5 мин | проверка активности клиента |
| `ClientAliveCountMax 2` | 2 пропуска | отключение «мёртвых» сессий |

---

## Часть 4. Проверка SSH (в новом терминале)

> [!IMPORTANT]
> Проверки выполняйте в **отдельном** терминале, не закрывая текущую сессию.

### 4.1 Вход на новом порту

```bash
ssh admin@<IP-адрес-сервера> -p 7722
```

### 4.2 Запрет root — ожидается отказ

```bash
ssh root@<IP-адрес-сервера> -p 7722
```

### 4.3 Запрет пароля — ожидается отказ

```bash
ssh -o PreferredAuthentications=password admin@<IP-адрес-сервера> -p 7722
```

---

## Часть 5. Настройка фаервола (UFW)

### 5.1 Разрешение портов

```bash
sudo ufw allow 7722/tcp
```

```bash
sudo ufw allow 8081/tcp
```

```bash
sudo ufw allow 443/tcp
```

```bash
# sudo ufw allow 80/tcp   # не рекомендуется
```

### 5.2 Включение фаервола

```bash
sudo ufw enable
```

### 5.3 Проверка

```bash
sudo ufw status numbered
```

### 5.4 Перезагрузка

```bash
sudo reboot
```

---

## Часть 6. Настройка fail2ban (защита от брутфорса)

fail2ban мониторит логи и временно блокирует IP с неудачными попытками входа.

> [!WARNING]
> Если сетью управляет сторонняя организация и пробросы портов, маршрутизация, DHCP и т.п. настроены некорректно — все входящие подключения могут приходить с одного IP (например, маршрутизатора). В этом случае блокировка fail2ban может полностью отрезать внешний доступ.

### 6.1 Установка

```bash
sudo apt update
```

```bash
sudo apt install fail2ban -y
```

### 6.2 Конфиг для SSH на порту 7722

```bash
sudo touch /etc/fail2ban/jail.d/ssh-custom.conf
```

```bash
sudo nano /etc/fail2ban/jail.d/ssh-custom.conf
```

Содержимое:

```bash
[sshd]
enabled = true
port = 7722
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
```

### 6.3 Запуск и автозагрузка

```bash
sudo systemctl restart fail2ban
```

```bash
sudo systemctl enable fail2ban
```

### 6.4 Проверка

```bash
sudo fail2ban-client status sshd
```

| Параметр | Значение | Смысл |
|----------|----------|-------|
| `maxretry` | 3 | блокировка после 3 неудач |
| `bantime` | 3600 | бан на 1 час |
| `findtime` | 600 | окно учёта — 10 минут |

fail2ban и `MaxAuthTries 3` в SSH дают двойную защиту.

---

## Часть 7. Итоговая проверка

### 7.1 Вход на сервер

```bash
ssh admin@<IP-адрес-сервера> -p 7722
```

### 7.2 sudo

```bash
sudo whoami
```

Ожидается: `root`

### 7.3 Переключение в root

```bash
sudo su -
```

```bash
whoami
```

```bash
exit
```

### 7.4 Фаервол

```bash
sudo ufw status verbose
```

### 7.5 fail2ban

```bash
sudo fail2ban-client status
```

```bash
sudo fail2ban-client status sshd
```

---

## Часть 8. Отключение автоматических обновлений

Скрипт: [off-update.sh](off-update.sh)

Автообновления могут перезапустить сервисы (nginx, Docker, БД) в неподходящий момент или нарушить совместимость. В боевом режиме их отключают.

### 8.1 Создание файла

```bash
touch /usr/local/bin/off-update.sh
```

### 8.2 Редактирование

```bash
nano /usr/local/bin/off-update.sh
```

### 8.3 Содержимое скрипта

<details>
<summary>Развернуть код off-update.sh</summary>

```bash
#!/bin/sh
set -e

echo "== Отключаем unattended-upgrades =="

sudo systemctl disable --now unattended-upgrades 2>/dev/null || true

echo "== Отключаем apt timers =="

sudo systemctl disable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

echo "== Маскируем службы =="

sudo systemctl mask unattended-upgrades.service \
    apt-daily.timer \
    apt-daily-upgrade.timer 2>/dev/null || true

echo "== Настройка APT автообновлений =="

CONF="/etc/apt/apt.conf.d/20auto-upgrades"

if [ -f "$CONF" ]; then
    sudo sed -i 's/"1"/"0"/g' "$CONF"
else
    echo "Создаём $CONF"
    cat <<EOF | sudo tee "$CONF" >/dev/null
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
fi

echo "== Удаление unattended-upgrades =="

sudo apt purge -y unattended-upgrades 2>/dev/null || true
sudo apt autoremove -y

echo "== Проверка Docker =="

if command -v docker >/dev/null 2>&1; then
    echo "Docker найден"
    sudo systemctl disable --now docker.timer 2>/dev/null || true
fi

echo "== Отключаем snap автообновления =="

if command -v snap >/dev/null 2>&1; then
    sudo systemctl disable --now snapd.refresh.timer 2>/dev/null || true
    sudo systemctl mask snapd.refresh.timer 2>/dev/null || true

    sudo snap set system refresh.disabled=true || true
    sudo snap get system refresh.disabled || true
fi

echo "== Проверка таймеров =="

systemctl list-timers | grep -E "apt|snap|unattended|update|upgrade" || echo "OK: таймеры не найдены"

echo "== Проверка статусов =="

systemctl status unattended-upgrades 2>&1 | grep -E "Active|Loaded" || true
systemctl status apt-daily.timer 2>&1 | grep "Active" || true
systemctl status snapd.refresh.timer 2>&1 | grep "Active" || true

echo "== Готово =="
```

</details>

### 8.4 Ручные обновления

После отключения автообновлений:

```bash
sudo apt update && sudo apt upgrade -y
```

---

## Часть 9. Справочная информация

### admuser.sh — быстрые ссылки

| Действие | Пункт меню |
|----------|------------|
| Запуск | — |
| Список пользователей | 4 |
| Экспорт отчёта | 12 |
| Блокировка | 7 |
| Разблокировка | 8 |
| Удаление | 9 |

```bash
sudo /usr/local/bin/admuser.sh
```

> [!NOTE]
> Отчёт (пункт 12) сохраняется в `/root/users_report_*.txt`

### Бэкап конфигов

```bash
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
```

```bash
sudo cp /etc/default/ufw /etc/default/ufw.backup
```

```bash
sudo cp /etc/fail2ban/jail.local /etc/fail2ban/jail.local.backup 2>/dev/null || true
```

### Восстановление доступа

Если потерян SSH-доступ:

1. Зайдите через консоль VPS/KVM
2. Восстановите настройки

**Вернуть SSH на порт 22**

```bash
sudo cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
```

```bash
sudo systemctl restart sshd
```

**Отключить фаервол**

```bash
sudo ufw disable
```
