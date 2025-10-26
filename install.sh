#!/bin/bash
set -euo pipefail

# -----------------------------------------
# install_manager.sh
# كامل: تنزيل tinyfilemanager (manager.php)، طلب يوزر/كلمة، توليد bcrypt، وتحديث manager.php بأمان
# شغّل: sudo bash install_manager.sh
# -----------------------------------------

TFM_RAW_URL="https://raw.githubusercontent.com/xXstrem/install-php-tiny/refs/heads/main/tinyfilemanager.php"
TFM_FILE="/var/www/html/manager.php"
WWW_USER="www-data"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# ---- تحديث النظام وتثبيت المتطلبات الأساسية ----
echo ">>> تحديث الحزم وتثبيت Apache و PHP 7.4 (قد يأخذ بعض الوقت)..."
sudo bash -c 'cat > /etc/needrestart/needrestart.conf <<CONF
$nrconf{restart} = "a";
CONF' || true

sudo apt-get update -y
sudo -y -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" upgrade || true

sudo apt-get install -y apache2 || { echo "Failed to install apache2"; exit 1; }
sudo systemctl enable --now apache2 || true

sudo apt-get install -y software-properties-common wget unzip || true
# ppa ondrej for php7.4 (if available); ignore error if already exists
sudo add-apt-repository -y ppa:ondrej/php || true
sudo apt-get update -y

sudo apt-get install -y php7.4 php7.4-cli php7.4-common php7.4-mbstring php7.4-zip php7.4-xml php7.4-curl unzip \
                       php7.4-mysqli php7.4-bcmath php7.4-intl php7.4-gd libapache2-mod-php7.4 || true

sudo chown -R $WWW_USER:$WWW_USER /var/www/html || true
sudo find /var/www/html -type d -exec chmod 755 {} \; || true
sudo find /var/www/html -type f -exec chmod 644 {} \; || true

# ---- تنزيل tinyfilemanager إلى manager.php إذا غير موجود ----
if [ ! -f "$TFM_FILE" ]; then
  echo ">>> تحميل tinyfilemanager إلى $TFM_FILE"
  sudo wget -q -O /var/www/html/tinyfilemanager.php "$TFM_RAW_URL" || { echo "Failed to download tinyfilemanager.php. Exiting."; exit 1; }
  sudo mv /var/www/html/tinyfilemanager.php "$TFM_FILE"
  sudo chown $WWW_USER:$WWW_USER "$TFM_FILE"
  sudo chmod 640 "$TFM_FILE"
  sudo systemctl reload apache2 || sudo systemctl restart apache2 || true
fi

clear

# ---- طلب اليوزر وكلمة المرور تفاعلياً ----
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

# ---- توليد هاش bcrypt (cost=10) باستخدام PHP CLI ----
# نمرر كلمة السر كوسيط آمن لـ php -r باستخدام -- لتجنب تفسيرها كخيار
NEW_HASH=$(php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT, ["cost" => 10]);' -- "$NEW_PASS")
if [ -z "$NEW_HASH" ]; then
  echo "Failed to generate hash. Aborting."
  exit 1
fi
echo "Generated hash: $NEW_HASH"

# ---- تأكد من وجود ملف manager.php ----
if [ ! -f "$TFM_FILE" ]; then
  echo "ERROR: $TFM_FILE not found. Aborting."
  exit 1
fi

# ---- باك أب من الملف الأصلي ----
BACKUP="${TFM_FILE}.bak.$(date +%s)"
sudo cp "$TFM_FILE" "$BACKUP"
echo "Backup created at $BACKUP"

# ---- هروب علامات الاقتباس لوضعها بأمان داخل سكربت PHP مؤقت ----
escape_for_php_single_quote() {
  # يحول ' إلى '\'' ليتناسب داخل single-quoted string في شل
  printf "%s" "$1" | sed "s/'/'\\\\''/g"
}
U_ESC=$(escape_for_php_single_quote "$TARGET_USER")
H_ESC=$(escape_for_php_single_quote "$NEW_HASH")

# ---- انشاء سكربت PHP مؤقت يقوم بالتعديل (سيُشغّل تحت sudo) ----
TMP_PHP="/tmp/update_manager_$$.php"
cat > "$TMP_PHP" <<PHP
<?php
// تحديث آمن لملف manager.php
\$file = '$TFM_FILE';
\$s = @file_get_contents(\$file);
if (\$s === false) {
    fwrite(STDERR, "Cannot read \$file\\n");
    exit(1);
}
\$u = '$U_ESC';
\$h = '$H_ESC';

// 1) استبدال المستخدم إذا كان موجوداً
\$pattern_user = "/(['\"])".preg_quote(\$u, '/')."\\\\1\\\\s*=>\\\\s*['\"][^'\"]*['\"]/s";
if (preg_match(\$pattern_user, \$s)) {
    \$s = preg_replace(\$pattern_user, \"'\".\$u.\"' => '\".\$h.\"'\", \$s, 1);
    file_put_contents(\$file, \$s);
    echo \"Updated user '\$u' with new bcrypt hash.\\n\";
    exit(0);
}

// 2) استبدال placeholder شائع: 'userrrrrrrrrr' => 'passwordhash'
\$pattern_placeholder = \"/['\"]userrrrrrrrrr['\"]\\\\s*=>\\\\s*['\"]passwordhash['\"]\\\\s*,?/s\";
if (preg_match(\$pattern_placeholder, \$s)) {
    \$s = preg_replace(\$pattern_placeholder, \"'\".\$u.\"' => '\".\$h.\"',\", \$s, 1);
    file_put_contents(\$file, \$s);
    echo \"Replaced placeholder with user '\$u' and new hash.\\n\";
    exit(0);
}

// 3) استبدال أول ظهور لـ 'passwordhash' إن وجد
if (strpos(\$s, 'passwordhash') !== false) {
    \$s = preg_replace(\"/passwordhash/\", \$h, \$s, 1);
    file_put_contents(\$file, \$s);
    echo \"Replaced first 'passwordhash' occurrence with new hash.\\n\";
    exit(0);
}

// 4) خلاف ذلك: أضف بلوك \$auth_users في أعلى الملف
\$new = \"\$auth_users = array(\\n    '\".\$u.\"' => '\".\$h.\"',\\n);\\n\\n\";
\$s = \$new . \$s;
file_put_contents(\$file, \$s);
echo \"Prepended new \$auth_users block with user '\$u'.\\n\";
exit(0);
PHP

# ---- نفّذ سكربت PHP بصلاحيات sudo ليتمكن من كتابة الملف ----
sudo php "$TMP_PHP"

# ---- ضبط المالك والتصاريح ----
sudo chown "$WWW_USER":"$WWW_USER" "$TFM_FILE" || true
sudo chmod 640 "$TFM_FILE" || true

# ---- نظف الملف المؤقت ----
rm -f "$TMP_PHP"

# ---- تحقق سريع من وجود اليوزر داخل الملف ----
echo
echo "Search result (grep):"
sudo grep -n --color=never -m 5 -E "'$TARGET_USER'\\s*=>" "$TFM_FILE" || true

echo
echo "تم التعديل بنجاح. نسخ احتياطية: $BACKUP"
echo "يُفترض أن ترى سطر مثل: '$TARGET_USER' => '\$2y\$10\$...'"
echo
echo "➡️ افتح: http://<IP-or-domain>/manager.php"
echo "✅ انتهى."
