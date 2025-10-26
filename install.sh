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

read -p "Username to update in manager.php: " TARGET_USER
while [ -z "${TARGET_USER:-}" ]; do
  echo "Username cannot be empty."
  read -p "Username to update in manager.php: " TARGET_USER
done

while true; do
  read -s -p "New password for '$TARGET_USER': " NEW_PASS; echo
  read -s -p "Confirm password: " NEW_PASS2; echo
  [ -z "${NEW_PASS:-}" ] && { echo "Password cannot be empty."; continue; }
  [ "$NEW_PASS" = "$NEW_PASS2" ] && break
  echo "Passwords do not match. Try again."
done

# generate bcrypt hash with cost = 10 (will produce $2y$10$...)
NEW_HASH=$(php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT, ["cost" => 10]);' "$NEW_PASS")
echo "Generated hash: $NEW_HASH"

TFM_FILE="/var/www/html/manager.php"
if [ ! -f "$TFM_FILE" ]; then
  echo "ERROR: $TFM_FILE not found. Aborting."
  exit 1
fi

BACKUP="${TFM_FILE}.bak.$(date +%s)"
sudo cp "$TFM_FILE" "$BACKUP"
echo "Backup created at $BACKUP"

# Important: use printf + base64 to safely pass variables to PHP
SAFE_USER=$(printf '%s' "$TARGET_USER" | base64)
SAFE_HASH=$(printf '%s' "$NEW_HASH" | base64)

sudo php <<PHP
<?php
\$file = '/var/www/html/manager.php';
if (!file_exists(\$file)) { echo "manager.php not found\n"; exit(1); }

\$user = base64_decode('${SAFE_USER}');
\$hash = base64_decode('${SAFE_HASH}');
\$s = file_get_contents(\$file);

// Escape single quotes
\$u_esc = str_replace("'", "\\'", \$user);
\$h_esc = str_replace("'", "\\'", \$hash);

// 1) If user exists, replace it
\$pattern_user = "/(['\"])".preg_quote(\$user, '/')."\\1\\s*=>\\s*['\"][^'\"]*['\"]/s";
if (preg_match(\$pattern_user, \$s)) {
    \$s = preg_replace(\$pattern_user, "'".\$u_esc."' => '".\$h_esc."'", \$s, 1);
    file_put_contents(\$file, \$s);
    echo "Updated user '".\$user."' with new bcrypt hash.\\n";
    exit(0);
}

// 2) Replace placeholder
\$pattern_placeholder = "/['\"]userrrrrrrrrr['\"]\\s*=>\\s*['\"]passwordhash['\"]\\s*,?/s";
if (preg_match(\$pattern_placeholder, \$s)) {
    \$s = preg_replace(\$pattern_placeholder, "'".\$u_esc."' => '".\$h_esc."',", \$s, 1);
    file_put_contents(\$file, \$s);
    echo "Replaced placeholder with user '".\$user."'.\\n";
    exit(0);
}

// 3) Replace literal passwordhash
if (strpos(\$s, "passwordhash") !== false) {
    \$s = preg_replace("/passwordhash/", \$h_esc, \$s, 1);
    file_put_contents(\$file, \$s);
    echo "Replaced 'passwordhash' literal.\\n";
    exit(0);
}

// 4) Otherwise, prepend new auth block
\$new = "\$auth_users = array(\\n    '".\$u_esc."' => '".\$h_esc."',\\n);\\n\\n";
\$s = \$new . \$s;
file_put_contents(\$file, \$s);
echo "Prepended new auth block with user '".\$user."'.\\n";
PHP

sudo chown www-data:www-data "$TFM_FILE"
sudo chmod 640 "$TFM_FILE"
sudo systemctl reload apache2 || sudo systemctl restart apache2

echo
echo "✅ Installation completed successfully!"
echo "➡️  Open: http://<IP-or-domain>/manager.php"
echo "👤 User: $TARGET_USER"
