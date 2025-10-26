#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

sudo bash -c 'cat > /etc/needrestart/needrestart.conf <<CONF
$nrconf{restart} = "a";
CONF'

sudo apt-get update -y
sudo apt-get -y -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" upgrade

sudo apt-get install -y apache2
sudo systemctl enable --now apache2

sudo apt-get install -y software-properties-common wget unzip
sudo add-apt-repository -y ppa:ondrej/php || true
sudo apt-get update -y

sudo apt-get install -y php7.4 php7.4-cli php7.4-common php7.4-mbstring php7.4-zip php7.4-xml php7.4-curl unzip \
                       php7.4-mysqli php7.4-bcmath php7.4-intl php7.4-gd

sudo chown -R www-data:www-data /var/www/html
sudo find /var/www/html -type d -exec chmod 755 {} \;
sudo find /var/www/html -type f -exec chmod 644 {} \;

TFM_RAW_URL="https://raw.githubusercontent.com/prasathmani/tinyfilemanager/master/tinyfilemanager.php"
sudo wget -q -O /var/www/html/tinyfilemanager.php "$TFM_RAW_URL" || { echo "failed tinyfilemanager.php"; exit 1; }
sudo mv /var/www/html/tinyfilemanager.php /var/www/html/manager.php
sudo chown www-data:www-data /var/www/html/manager.php
sudo chmod 640 /var/www/html/manager.php
sudo systemctl reload apache2 || sudo systemctl restart apache2

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

# Ask for username and password (or use environment vars)
if [ -z "${TFM_USER:-}" ] || [ -z "${TFM_PASS:-}" ]; then
  read -p "Enter username: " TFM_USER
  while [ -z "$TFM_USER" ]; do
    echo "Username cannot be empty."
    read -p "Enter username: " TFM_USER
  done
  while true; do
    read -s -p "Enter password: " TFM_PASS
    echo
    read -s -p "Confirm password: " TFM_PASS2
    echo
    [ -z "$TFM_PASS" ] && { echo "Password cannot be empty."; continue; }
    [ "$TFM_PASS" = "$TFM_PASS2" ] && break
    echo "Passwords do not match."
  done
fi

TFM_HASH=$(php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "$TFM_PASS")
TFM_FILE="/var/www/html/manager.php"
ESC_HASH=$(printf '%s' "$TFM_HASH" | sed 's/\\/\\\\/g; s/\$/\\\$/g; s/\//\\\//g')

if grep -q "\$auth_users\s*=" "$TFM_FILE"; then
  if grep -qE "['\"]${TFM_USER}['\"]\s*=>\s*['\"][^'\"]*['\"]" "$TFM_FILE"; then
    sudo perl -0777 -i -pe "s/(['\"])${TFM_USER}(['\"]\s*=>\s*['\"])[^'\"]*(['\"])/\$1${TFM_USER}\$2${ESC_HASH}\$3/s" "$TFM_FILE"
  else
    sudo perl -0777 -i -pe "s/(\$auth_users\s*=\s*array\s*\(\s*)(.*?)(\s*\);)/\$1\$2,\n    '${TFM_USER}' => '${ESC_HASH}'\n\$3/s" "$TFM_FILE"
  fi
else
  TMP_AUTH="$(mktemp)"
  cat > "$TMP_AUTH" <<'AUTH'
$auth_users = array(
    'REPLACE_USER' => 'REPLACE_HASH'
);
AUTH
  sed -i "s/REPLACE_USER/$TFM_USER/; s|REPLACE_HASH|$TFM_HASH|" "$TMP_AUTH"
  sudo bash -c "cat '$TMP_AUTH' '$TFM_FILE' > '$TFM_FILE.new' && mv '$TFM_FILE.new' '$TFM_FILE'"
  rm -f "$TMP_AUTH"
fi

sudo chown www-data:www-data "$TFM_FILE"
sudo chmod 640 "$TFM_FILE"
sudo systemctl reload apache2 || sudo systemctl restart apache2

echo
echo "✅ Installation completed successfully!"
echo "➡️  Open: http://<IP-or-domain>/manager.php"
echo "👤 User: $TFM_USER"
