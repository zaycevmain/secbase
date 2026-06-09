# Базовая настройка сетевой безопасности сервера (полная инструкция)

## Содержание
1. Установка и настройка скрипта управления пользователями [admuser.sh](admuser.sh)
2. Создание административного пользователя
3. Настройка SSH (безопасность + доп параметры)
4. Проверка SSH
5. Настройка фаервола (UFW)
6. Настройка fail2ban
7. Итоговая проверка
8. Установка и использвания скрипта отключения автоматических обновлений [off-update.sh](off-update.sh)
9. Справочная информация

---

### Ожидаемый результат

| Возможность | Статус |
|-------------|--------|
| Вход по SSH для обычного пользователя | ✅ порт 7722, только по ключу |
| Вход root через SSH | ❌ запрещён |
| Вход по паролю через SSH | ❌ запрещён |
| Лимит попыток входа | ✅ 3 попытки (MaxAuthTries) |
| Защита от брутфорса (fail2ban) | ✅ блокировка на 1 час |
| Использование sudo | ✅ работает |
| Переключение в root через `sudo su -` | ✅ работает |
| Фаервол | ✅ включён |
| Автоматические обновления | ❌ отключены (ручной контроль) |


## Часть 1. Установка скрипта admuser.sh

Создайте файл скрипта:

```bash
sudo tee /usr/local/bin/admuser.sh << 'EOF'
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
EOF

# Делаем скрипт исполняемым
sudo chmod +x /usr/local/bin/admuser.sh
```

---

## Часть 2. Создание административного пользователя

```bash
# Запускаем скрипт от root
sudo /usr/local/bin/admuser.sh

# В скрипте:
# Выбрать пункт 1 (Создать пользователя)
# Ввести имя (например admin)
# Добавить в sudo? y
# Добавить SSH-ключ? y (вставить ваш публичный ключ)
# Сгенерировать SSH-ключи? n

# Выйти из скрипта (пункт 0)

# Выход из root и вход под новым пользователем
exit
ssh admin@<IP-адрес-сервера>
```

---

## Часть 3. Настройка SSH (безопасность)

```bash
# Редактируем конфиг
sudo nano /etc/ssh/sshd_config

# Меняем/добавляем строки:
Port 7722
PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
MaxSessions 2
ClientAliveInterval 300
ClientAliveCountMax 2

# Проверяем синтаксис
sudo sshd -t

# Перезапускаем SSH
sudo systemctl restart sshd
```

**Объяснение параметров:**
| Параметр | Значение | Зачем |
|----------|----------|-------|
| `Port 7722` | нестандартный порт | снижает количество сканеров/брутфорса |
| `PermitRootLogin no` | запрет root | нельзя зайти под root по SSH |
| `PasswordAuthentication no` | только ключи | защита от подбора пароля |
| `MaxAuthTries 3` | 3 попытки | после 3 неудач разрыв соединения |
| `MaxSessions 2` | 2 сессии | ограничение DoS |
| `ClientAliveInterval 300` | проверка каждые 5 мин | очистка "мертвых" сессий |
| `ClientAliveCountMax 2` | 2 пропуска | отключение при пропаже клиента |

---

## Часть 4. Проверка SSH (в новом терминале)

```bash
# Проверка входа на новом порту
ssh admin@<IP-адрес-сервера> -p 7722

# Проверка запрета root
ssh root@<IP-адрес-сервера> -p 7722
# Должен отказать (Permission denied)

# Проверка запрета пароля
ssh -o PreferredAuthentications=password admin@<IP-адрес-сервера> -p 7722
# Должен отказать
```

---

## Часть 5. Настройка фаервола (UFW)

```bash
# Разрешаем нужные порты
sudo ufw allow 7722/tcp
sudo ufw allow 8081/tcp
sudo ufw allow 443/tcp
# sudo ufw allow 80/tcp   # не рекомендуется

# Включаем фаервол
sudo ufw enable

# Проверяем
sudo ufw status numbered

# Перезагружаем сервер
sudo reboot
```

---

## Часть 6. Настройка fail2ban (защита от брутфорса)

**Что это:** fail2ban мониторит логи и временно блокирует IP, с которого идут неудачные попытки входа.

```bash
# Установка
sudo apt update
sudo apt install fail2ban -y

# Создаём конфиг для SSH на порту 7722
sudo tee /etc/fail2ban/jail.d/ssh-custom.conf << 'EOF'
[sshd]
enabled = true
port = 7722
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
EOF

# Запускаем fail2ban
sudo systemctl restart fail2ban
sudo systemctl enable fail2ban

# Проверяем статус
sudo fail2ban-client status sshd
```

**Объяснение:**
- `maxretry = 3` — после 3 неудачных попыток
- `bantime = 3600` — блокировка на 1 час
- `findtime = 600` — за последние 10 минут

fail2ban + `MaxAuthTries 3` в SSH дают двойную защиту.

---

## Часть 7. Итоговая проверка

```bash
# Заходим на сервер
ssh admin@<IP-адрес-сервера> -p 7722

# Проверяем sudo
sudo whoami                    # должно вернуть root

# Проверяем переключение в root
sudo su -
whoami                         # должно вернуть root
exit

# Проверяем статус фаервола
sudo ufw status verbose

# Проверяем статус fail2ban
sudo fail2ban-client status
sudo fail2ban-client status sshd
```

---

## Часть 8. Отключение автоматических обновлений (обязательно в боевом режиме)

**Почему отключают:** автоматические обновления могут перезапустить сервисы (nginx, Docker, базы данных) в неподходящий момент или сломать совместимость.

```bash
# Создаём и запускаем скрипт отключения
cat << 'SCRIPT' | sudo bash
#!/bin/sh
set -e

echo "== Отключаем unattended-upgrades =="
systemctl disable --now unattended-upgrades 2>/dev/null || true

echo "== Отключаем apt timers =="
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

echo "== Маскируем службы =="
systemctl mask unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

echo "== Настройка APT =="
CONF="/etc/apt/apt.conf.d/20auto-upgrades"
if [ -f "$CONF" ]; then
    sed -i 's/"1"/"0"/g' "$CONF"
else
    cat << 'EOFCONF' > "$CONF"
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOFCONF
fi

echo "== Удаление unattended-upgrades =="
apt purge -y unattended-upgrades 2>/dev/null || true
apt autoremove -y

echo "== Отключаем snap автообновления =="
if command -v snap >/dev/null 2>&1; then
    systemctl disable --now snapd.refresh.timer 2>/dev/null || true
    systemctl mask snapd.refresh.timer 2>/dev/null || true
    snap set system refresh.disabled=true || true
fi

echo "== Проверка таймеров =="
systemctl list-timers | grep -E "apt|snap|unattended|update|upgrade" || echo "OK: все таймеры отключены"
SCRIPT
```

**Важно:** После отключения автообновлений обновления нужно ставить вручную:
```bash
sudo apt update && sudo apt upgrade -y
```

---

## Часть 9. Справочная информация

### Полезные команды для управления скриптом admuser.sh

```bash
# Запуск скрипта
sudo /usr/local/bin/admuser.sh

# Показать всех пользователей
sudo /usr/local/bin/admuser.sh  # затем пункт 4

# Экспорт отчёта о пользователях
sudo /usr/local/bin/admuser.sh  # затем пункт 12
# Отчёт сохранится в /root/users_report_*.txt

# Заблокировать пользователя (пункт 7)
# Разблокировать (пункт 8)
# Удалить пользователя (пункт 9)
```

### Бэкап конфигов (рекомендуется)

```bash
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
sudo cp /etc/default/ufw /etc/default/ufw.backup
sudo cp /etc/fail2ban/jail.local /etc/fail2ban/jail.local.backup 2>/dev/null || true
```

### Восстановление доступа (если что-то пошло не так)

Если вы потеряли доступ через SSH:
1. Зайдите через консоль VPS/KVM
2. Восстановите настройки:
```bash
# Вернуть SSH на порт 22
sudo cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
sudo systemctl restart sshd

# Отключить фаервол
sudo ufw disable
```
