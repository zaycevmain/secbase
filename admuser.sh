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
