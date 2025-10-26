cat <<'EOF' > /tmp/setup_webserver.sh
#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# Ensure needrestart config
sudo sed -i 's/\$nrconf{restart}.*/$nrconf{restart} = "a";/' /etc/needrestart/needrestart.conf \
  || echo '$nrconf{restart} = "a";' | sudo tee -a /etc/needrestart/needrestart.conf

sudo apt-get update -y
sudo apt-get -y -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" upgrade

sudo apt-get install -y apache2
sudo systemctl enable --now apache2

# utilities and php ppa
sudo apt-get install -y software-properties-common wget unzip
sudo add-apt-repository -y ppa:ondrej/php || true
sudo apt-get update -y

# include php cli to generate bcrypt hashes
sudo apt-get install -y php7.4 php7.4-cli php7.4-common php7.4-mbstring php7.4-zip php7.4-xml php7.4-curl unzip \
                       php7.4-mysqli php7.4-bcmath php7.4-intl php7.4-gd

# set permissions for web root
sudo chown -R www-data:www-data /var/www/html
sudo find /var/www/html -type d -exec chmod 755 {} \;
sudo find /var/www/html -type f -exec chmod 644 {} \;

# download tinyfilemanager raw and rename to manager.php
TFM_RAW_URL="https://raw.githubusercontent.com/prasathmani/tinyfilemanager/master/tinyfilemanager.php"
sudo wget -q -O /var/www/html/tinyfilemanager.php "$TFM_RAW_URL" || { echo "failed tinyfilemanager.php"; exit 1; }

sudo mv /var/www/html/tinyfilemanager.php /var/www/html/manager.php
sudo chown www-data:www-data /var/www/html/manager.php
sudo chmod 640 /var/www/html/manager.php

# reload apache to pick up files
sudo systemctl reload apache2 || sudo systemctl restart apache2

# clear screen and show banner
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

# ------- prompt user for username/password (single place) -------
read -p "Enter username to add/update in manager.php: " TFM_USER_RAW
while [ -z "${TFM_USER_RAW:-}" ]; do
  echo "Username cannot be empty. Try again."
  read -p "Enter username to add/update in manager.php: " TFM_USER_RAW
done

# sanitize username: allow only letters, digits, dot, underscore, hyphen
TFM_USER=$(printf '%s' "$TFM_USER_RAW" | sed 's/[^A-Za-z0-9._-]//g')
if [ -z "$TFM_USER" ]; then
  echo "After sanitization username is empty. Exiting."
  exit 1
fi
if [ "$TFM_USER" != "$TFM_USER_RAW" ]; then
  echo "Note: using sanitized username: $TFM_USER"
fi

# password prompt (hidden) and confirmation
while true; do
  read -s -p "Enter password for user '$TFM_USER': " TFM_PASS
  echo
  read -s -p "Confirm password: " TFM_PASS2
  echo
  if [ -z "${TFM_PASS:-}" ]; then
    echo "Password cannot be empty. Try again."
    continue
  fi
  if [ "$TFM_PASS" = "$TFM_PASS2" ]; then
    break
  fi
  echo "Passwords do not match — try again."
done

# generate bcrypt hash using php
TFM_HASH=$(php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "$TFM_PASS")
if [ -z "$TFM_HASH" ]; then
  echo "Failed to generate password hash. Exiting."
  exit 1
fi

# target manager.php
TFM_FILE="/var/www/html/manager.php"
if [ ! -f "$TFM_FILE" ]; then
  echo "manager.php not found at $TFM_FILE. Exiting."
  exit 1
fi

# escape backslashes and dollar signs for use in perl replacement
ESC_HASH=$(printf '%s' "$TFM_HASH" | sed 's/\\/\\\\/g; s/\$/\\\$/g')

# insert or update user in $auth_users array
if grep -q "\$auth_users\s*=" "$TFM_FILE"; then
  if grep -qE "['\"]${TFM_USER}['\"]\s*=>\s*['\"][^'\"]*['\"]" "$TFM_FILE"; then
    echo "User '$TFM_USER' exists — updating hash."
    sudo perl -0777 -i -pe "s/(['\"])${TFM_USER}(['\"]\s*=>\s*['\"])[^'\"]*(['\"])/\$1${TFM_USER}\$2${ESC_HASH}\$3/s" "$TFM_FILE"
  else
    echo "User '$TFM_USER' not found — inserting new entry into \$auth_users array."
    sudo perl -0777 -i -pe "s/(\$auth_users\s*=\s*array\s*\(\s*)(.*?)(\s*\);)/\$1\$2,\n    '${TFM_USER}' => '${ESC_HASH}'\n\$3/s" "$TFM_FILE"
  fi
else
  echo "No \$auth_users array found — prepending a new block."
  TMP_AUTH="$(mktemp)"
  cat > "$TMP_AUTH" <<EOF
\$auth_users = array(
    '${TFM_USER}' => '${TFM_HASH}'
);
EOF
  sudo bash -c "cat '$TMP_AUTH' '$TFM_FILE' > '$TFM_FILE.new' && mv '$TFM_FILE.new' '$TFM_FILE'"
  rm -f "$TMP_AUTH"
fi

# fix ownership and permissions
sudo chown www-data:www-data "$TFM_FILE" || true
sudo chmod 640 "$TFM_FILE" || true

echo "Done: user '$TFM_USER' added/updated in $TFM_FILE"

echo ""
echo "Installation completed successfully!"
echo "Now open : http://<IP-or-domain>/manager.php"
EOF

chmod +x /tmp/setup_webserver.sh

# Note: next line intentionally not auto-run; run manually when ready:
# sudo /tmp/setup_webserver.sh
