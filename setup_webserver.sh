#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# ====== إعداد needrestart لمنع أي توقف أثناء التحديث ======
sudo bash -c 'cat > /etc/needrestart/needrestart.conf <<CONF
$nrconf{restart} = "a";
CONF'

# ====== تحديث النظام ======
sudo apt-get update -y
sudo apt-get -y -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" upgrade

# ====== تثبيت Apache ======
sudo apt-get install -y apache2
sudo systemctl enable --now apache2

# ====== تثبيت PHP ======
sudo apt-get install -y software-properties-common wget unzip
sudo add-apt-repository -y ppa:ondrej/php || true
sudo apt-get update -y

sudo apt-get install -y php7.4 php7.4-cli php7.4-common php7.4-mbstring php7.4-zip php7.4-xml php7.4-curl unzip \
                       php7.4-mysqli php7.4-bcmath php7.4-intl php7.4-gd

sudo chown -R www-data:www-data /var/www/html
sudo find /var/www/html -type d -exec chmod 755 {} \;
sudo find /var/www/html -type f -exec chmod 644 {} \;

# ====== تحميل TinyFileManager ======
TFM_RAW_URL="https://raw.githubusercontent.com/prasathmani/tinyfilemanager/master/tinyfilemanager.php"
sudo wget -q -O /var/www/html/tinyfilemanager.php "$TFM_RAW_URL" || { echo "failed tinyfilemanager.php"; exit 1; }

sudo mv /var/www/html/tinyfilemanager.php /var/www/html/manager.php
sudo chown www-data:www-data /var/www/html/manager.php
sudo chmod 640 /var/www/html/manager.php

sudo systemctl reload apache2 || sudo systemctl restart apache2

# ====== دالة قراءة من /dev/tty ======
_read() {
  local __var="$1"; shift
  local prompt="$*"
  if [ -c /dev/tty ]; then
    read -r -p "$prompt" "$__var" < /dev/tty
  else
    read -r -p "$prompt" "$__var"
  fi
}

_read_secret() {
  local __var="$1"; shift
  local prompt="$*"
  if [ -c /dev/tty ]; then
    read -s -r -p "$prompt" "$__var" < /dev/tty
    echo "" > /dev/tty
  else
    read -s -r -p "$prompt" "$__var"
    echo ""
  fi
}

# ====== عرض البنر ======
clear
cat <<'BANNER'
  ______ _ _        __  __                                   
 |  ____(_) |      |  \/  |                                  
 | |__   _| | ___  | \  / | __ _ _ __   __ _  __ _  ___ _ __ 
 |  __| | | |/ _ \ | |\/| |/ _` | '_ \ / _` |/ _` |/ _ \ '__|
 | |    | | |  __/ | |  | | (_| | | | | (_| | (_| |  __/ |   
 |_|    |_|_|\___| |_|  |_|\__,_|_| |_|\__,_|\__, |\___|_|   
                                              __/ |          
                                             |___/           
BANNER

# ====== إدخال اليوزر والرمز ======
TFM_USER="${TFM_USER:-}"
TFM_PASS="${TFM_PASS:-}"

if [ -z "$TFM_USER" ] || [ -z "$TFM_PASS" ]; then
  _read TFM_USER "Enter username for manager.php: "
  while [ -z "$TFM_USER" ]; do
    echo "Username cannot be empty." > /dev/tty
    _read TFM_USER "Enter username for manager.php: "
  done

  while true; do
    _read_secret TFM_PASS "Enter password for '$TFM_USER': "
    _read_secret TFM_PASS2 "Confirm password: "
    if [ -z "$TFM_PASS" ]; then
      echo "Password cannot be empty." > /dev/tty
      continue
    fi
    [ "$TFM_PASS" = "$TFM_PASS2" ] && break
    echo "Passwords do not match. Try again." > /dev/tty
  done
fi

# ====== تشفير كلمة المرور ======
TFM_HASH=$(php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "$TFM_PASS")
if [ -z "$TFM_HASH" ]; then
  echo "Failed to generate password hash."
  exit 1
fi

TFM_FILE="/var/www/html/manager.php"
if [ ! -f "$TFM_FILE" ]; then
  echo "manager.php not found at $TFM_FILE. Exiting."
  exit 1
fi

ESC_HASH=$(printf '%s' "$TFM_HASH" | sed 's/\\/\\\\/g; s/\$/\\\$/g')

if grep -q "\$auth_users\s*=" "$TFM_FILE"; then
  if grep -qE "['\"]${TFM_USER}['\"]\s*=>\s*['\"][^'\"]*['\"]" "$TFM_FILE"; then
    echo "User '$TFM_USER' exists — updating hash."
    sudo perl -0777 -i -pe "s/(['\"])${TFM_USER}(['\"]\s*=>\s*['\"])[^'\"]*(['\"])/\$1${TFM_USER}\$2${ESC_HASH}\$3/s" "$TFM_FILE"
  else
    echo "Adding user '$TFM_USER' to auth array."
    sudo perl -0777 -i -pe "s/(\$auth_users\s*=\s*array\s*\(\s*)(.*?)(\s*\);)/\$1\$2,\n    '${TFM_USER}' => '${ESC_HASH}'\n\$3/s" "$TFM_FILE"
  fi
else
  echo "Creating new auth array."
  TMP_AUTH="$(mktemp)"
  cat > "$TMP_AUTH" <<'PHPBLOCK'
$auth_users = array(
    'REPLACE_USER' => 'REPLACE_HASH'
);
PHPBLOCK
  sed -i "s/REPLACE_USER/$TFM_USER/; s|REPLACE_HASH|$TFM_HASH|" "$TMP_AUTH"
  sudo bash -c "cat '$TMP_AUTH' '$TFM_FILE' > '$TFM_FILE.new' && mv '$TFM_FILE.new' '$TFM_FILE'"
  rm -f "$TMP_AUTH"
fi

sudo chown www-data:www-data "$TFM_FILE"
sudo chmod 640 "$TFM_FILE"

sudo systemctl reload apache2 || sudo systemctl restart apache2

echo ""
echo "✅ Installation completed successfully!"
echo "➡️  Now open: http://<IP-or-domain>/manager.php"
echo "👤 Username: $TFM_USER"
EOF
