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

# Interactive: ask which user to update and the new password
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

# backup
BACKUP="${TFM_FILE}.bak.$(date +%s)"
sudo cp "$TFM_FILE" "$BACKUP"
echo "Backup created at $BACKUP"

# Use PHP to safely update the specified user entry (or add if missing)
sudo TARGET_USER="$TARGET_USER" NEW_HASH="$NEW_HASH" php <<'PHP'
<?php
$file = '/var/www/html/manager.php';
$s = file_get_contents($file);
$u = getenv('TARGET_USER');
$h = getenv('NEW_HASH');
if ($u === false || $h === false) { echo "Missing env vars\n"; exit(1); }

// escape single quotes
$u_esc = str_replace("'", "\\'", $u);
$h_esc = str_replace("'", "\\'", $h);

// 1) If user exists, replace its value
$pattern_user = "/(['\"])".preg_quote($u, '/')."\\1\\s*=>\\s*['\"][^'\"]*['\"]/s";
if (preg_match($pattern_user, $s)) {
    $s = preg_replace($pattern_user, "'".$u_esc."' => '".$h_esc."'", $s, 1);
    file_put_contents($file, $s);
    echo "Updated user '$u' with new bcrypt hash.\n";
    exit(0);
}

// 2) Otherwise, try to replace the placeholder 'userrrrrrrrrr' => 'passwordhash'
$pattern_placeholder = "/['\"]userrrrrrrrrr['\"]\\s*=>\\s*['\"]passwordhash['\"]\\s*,?/s";
if (preg_match($pattern_placeholder, $s)) {
    $s = preg_replace($pattern_placeholder, "'".$u_esc."' => '".$h_esc."',", $s, 1);
    file_put_contents($file, $s);
    echo "Replaced placeholder with user '$u' and new hash.\n";
    exit(0);
}

// 3) Otherwise, if 'passwordhash' literal exists, replace first occurrence
if (strpos($s, "passwordhash") !== false) {
    $s = preg_replace("/passwordhash/", $h_esc, $s, 1);
    file_put_contents($file, $s);
    echo "Replaced first 'passwordhash' occurrence with new hash.\n";
    exit(0);
}

// 4) Otherwise, prepend a new $auth_users block
$new = "\$auth_users = array(\n    '".$u_esc."' => '".$h_esc."',\n);\n\n";
$s = $new . $s;
file_put_contents($file, $s);
echo "Prepended new \$auth_users block with user '$u'.\n";
exit(0);
PHP

# fix permissions
sudo chown www-data:www-data "$TFM_FILE" || true
sudo chmod 640 "$TFM_FILE" || true

echo "Done. Backup: $BACKUP"
echo "You should now see entry like: '$TARGET_USER' => '\$2y\$10\$...'"
sudo systemctl reload apache2 || sudo systemctl restart apache2

echo
echo "✅ Installation completed successfully!"
echo "➡️  Open: http://<IP-or-domain>/manager.php"
echo "👤 User: $NEW_USER"
