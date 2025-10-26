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
                       php7.4-mysqli php7.4-bcmath php7.4-intl php7.4-gd \
                       libapache2-mod-php7.4

sudo chown -R www-data:www-data /var/www/html
sudo find /var/www/html -type d -exec chmod 755 {} \;
sudo find /var/www/html -type f -exec chmod 644 {} \;

TFM_RAW_URL="https://raw.githubusercontent.com/xXstrem/install-php-tiny/refs/heads/main/tinyfilemanager.php"
sudo wget -q -O /var/www/html/tinyfilemanager.php "$TFM_RAW_URL" || { echo "Failed to download tinyfilemanager.php. Exiting."; exit 1; }
sudo mv /var/www/html/tinyfilemanager.php /var/www/html/manager.php
sudo chown www-data:www-data /var/www/html/manager.php
sudo chmod 640 /var/www/html/manager.php
sudo systemctl reload apache2 || sudo systemctl restart apache2

clear

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

if [ ! -f "$TFM_FILE" ]; then
  echo "manager.php not found at $TFM_FILE. Exiting."
  exit 1
fi

# Escape quotes in Bash variables for safe injection into PHP string literals
TFM_USER_ESC=$(printf '%s' "$TFM_USER" | sed "s/'/\\\'/g")
TFM_HASH_ESC=$(printf '%s' "$TFM_HASH" | sed "s/'/\\\'/g")

TFM_PHP_SCRIPT=$(mktemp)
# Use unquoted heredoc (<<PHP_CODE) to allow Bash variable substitution
cat <<PHP_CODE > "$TFM_PHP_SCRIPT"
<?php
// Define path, user, and hash directly from Bash injection
\$file = getenv('TFM_FILE'); 
\$u = '$TFM_USER_ESC';
\$h = '$TFM_HASH_ESC';

if (!file_exists(\$file)) { echo "manager.php not found\n"; exit(1); }
\$s = file_get_contents(\$file);

// Regex to capture the entire \$auth_users = array(...) block
\$regex = '/(\$auth_users\s*=\s*array\s*\()([\s\S]*?)(\);)/i';

// Build the new auth entry
\$new_auth_entries = "";
\$new_auth_entries .= "\n    '".\$u."' => '".\$h."',\n";

// Build the replacement block (containing ONLY the new user)
\$new_block = "\$auth_users = array(" . \$new_auth_entries . ");";

// Replace the old \$auth_users block entirely with the new one
if (preg_match(\$regex, \$s)) {
    \$s = preg_replace(\$regex, \$new_block, \$s, 1);
} else {
    \$s = \$new_block . "\n" . \$s;
}

file_put_contents(\$file, \$s);
echo "ok\n";
PHP_CODE

# Execute the temporary script using sudo
sudo TFM_FILE="$TFM_FILE" php "$TFM_PHP_SCRIPT"

rm -f "$TFM_PHP_SCRIPT"

sudo chown www-data:www-data "$TFM_FILE"
sudo chmod 640 "$TFM_FILE"
sudo systemctl reload apache2 || sudo systemctl restart apache2

echo
echo "✅ Installation completed successfully!"
echo "➡️  Open: http://<IP-or-domain>/manager.php"
echo "👤 User: $TFM_USER"
