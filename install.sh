#!/bin/bash
set -euo pipefail

# === 1. تهيئة النظام وإعداد needrestart ===

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# ضبط needrestart لتجنب المطالبات أثناء الترقية
sudo bash -c 'cat > /etc/needrestart/needrestart.conf <<CONF
$nrconf{restart} = "a";
CONF'

# تحديث النظام وترقيته
sudo apt-get update -y
sudo apt-get -y -o Dpkg::Options::="--force-confdef" \
               -o Dpkg::Options::="--force-confold" upgrade

# === 2. تثبيت Apache2 وإعداده ===

sudo apt-get install -y apache2
sudo systemctl enable --now apache2

# === 3. تثبيت PHP والملحقات (مع الإصلاح لوحدة Apache) ===

# تثبيت الأدوات المساعدة وإضافة مستودع PHP Ondrej
sudo apt-get install -y software-properties-common wget unzip
sudo add-apt-repository -y ppa:ondrej/php || true
sudo apt-get update -y

# تثبيت PHP 7.4 وملحقاته الأساسية، بالإضافة إلى الوحدة الضرورية لـ Apache2
sudo apt-get install -y php7.4 php7.4-cli php7.4-common php7.4-mbstring php7.4-zip php7.4-xml php7.4-curl unzip \
                       php7.4-mysqli php7.4-bcmath php7.4-intl php7.4-gd \
                       libapache2-mod-php7.4

# === 4. إعداد الصلاحيات وتنزيل Tiny File Manager ===

sudo chown -R www-data:www-data /var/www/html
sudo find /var/www/html -type d -exec chmod 755 {} \;
sudo find /var/www/html -type f -exec chmod 644 {} \;

TFM_RAW_URL="https://raw.githubusercontent.com/prasathmani/tinyfilemanager/master/tinyfilemanager.php"
sudo wget -q -O /var/www/html/tinyfilemanager.php "$TFM_RAW_URL" || { echo "❌ فشل تنزيل tinyfilemanager.php"; exit 1; }
sudo mv /var/www/html/tinyfilemanager.php /var/www/html/manager.php
sudo chown www-data:www-data /var/www/html/manager.php
sudo chmod 640 /var/www/html/manager.php
sudo systemctl reload apache2 || sudo systemctl restart apache2

clear
cat <<'BANNER'
  ______ _ _        __  __                                     
 |  ____(_) |      |  \/  |                                    
 | |__  _| | ___  | \  / | __ _ _ __   __ _  __ _ ___ _ __ 
 |  __| | | |/ _ \| |\/| |/ _` | '_ \ / _` |/ _` |/ _ \ '__|
 | |    | | |  __/ | |  | | (_| | | | | (_| | (_| |  __/ |  
 |_|    |_|_|\___|_|  |_|\__,_|_| |_|\__,|\__, |\___|_|  
                                           __/ |          
                                          |___/           
BANNER

# === 5. طلب بيانات الاعتماد ===

if [ -z "${TFM_USER:-}" ] || [ -z "${TFM_PASS:-}" ]; then
  read -p "أدخل اسم المستخدم: " TFM_USER
  while [ -z "$TFM_USER" ]; do
    echo "اسم المستخدم لا يمكن أن يكون فارغًا."
    read -p "أدخل اسم المستخدم: " TFM_USER
  done
  while true; do
    read -s -p "أدخل كلمة المرور: " TFM_PASS
    echo
    read -s -p "تأكيد كلمة المرور: " TFM_PASS2
    echo
    [ -z "$TFM_PASS" ] && { echo "كلمة المرور لا يمكن أن تكون فارغة."; continue; }
    [ "$TFM_PASS" = "$TFM_PASS2" ] && break
    echo "كلمات المرور غير متطابقة."
  done
fi

# === 6. تشفير كلمة المرور وتحديث الملف (الإصلاح الحقيقي هنا) ===

# توليد تجزئة bcrypt
TFM_HASH=$(php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "$TFM_PASS")
TFM_FILE="/var/www/html/manager.php"

if [ ! -f "$TFM_FILE" ]; then
  echo "❌ لم يتم العثور على manager.php في $TFM_FILE. خروج."
  exit 1
fi

# إنشاء ملف مؤقت لتنفيذ كود PHP
TFM_PHP_SCRIPT=$(mktemp)
cat <<'PHP_CODE' > "$TFM_PHP_SCRIPT"
<?php
// جلب المسار واسم المستخدم والهاش من متغيرات البيئة
$file = getenv('TFM_FILE'); 
$u = getenv('TFM_USER');
$h = getenv('TFM_HASH');

if (!file_exists($file)) { echo "manager.php not found\n"; exit(1); }
$s = file_get_contents($file);

// **البحث عن الكتلة الحالية لـ $auth_users بالكامل**
// نمط التعبير العادي الأكثر مرونة لالتقاط كل ما بداخل array() بما في ذلك التعليقات والمسافات
$regex = '/(\$auth_users\s*=\s*array\s*\()([\s\S]*?)(\);)/i';

// بناء كتلة المصادقة الجديدة (تتضمن المستخدم الجديد فقط)
// يتم إنشاء الكتلة فقط للمستخدم الذي أدخله المستخدم، مع إمكانية إضافة مستخدمين آخرين لاحقًا.
$new_auth_entries = "";
// هروب لاسم المستخدم والهاش
$k_esc = str_replace("'", "\\'", $u);
$v_esc = str_replace("'", "\\'", $h);
$new_auth_entries .= "\n    '".$k_esc."' => '".$v_esc."', // <--- المستخدم الجديد\n";

// بناء الكتلة البديلة
$new_block = "\$auth_users = array(" . $new_auth_entries . ");";

// استبدال كتلة $auth_users القديمة بالكامل بالكتلة الجديدة (هذا يحل مشكلة البيانات القديمة)
if (preg_match($regex, $s)) {
    // تم العثور على الكتلة، استبدلها
    $s = preg_replace($regex, $new_block, $s, 1);
} else {
    // إذا لم يتم العثور على الكتلة، قم بإضافتها في الأعلى.
    // هذه حالة نادرة ويجب أن تكون موجودة دائمًا في tinyfilemanager.php
    $s = $new_block . "\n" . $s;
}

file_put_contents($file, $s);
echo "ok\n";
PHP_CODE

# تنفيذ السكريبت المؤقت باستخدام sudo وتمرير المتغيرات كبيئة
sudo TFM_USER="$TFM_USER" TFM_HASH="$TFM_HASH" TFM_FILE="$TFM_FILE" php "$TFM_PHP_SCRIPT"

# حذف الملف المؤقت
rm -f "$TFM_PHP_SCRIPT"

# === 7. إعادة تعيين الصلاحيات وإعادة تشغيل Apache ===

sudo chown www-data:www-data "$TFM_FILE"
sudo chmod 640 "$TFM_FILE"
sudo systemctl reload apache2 || sudo systemctl restart apache2

echo
echo "✅ اكتمل التثبيت بنجاح!"
echo "➡️  افتح: http://<IP-أو-نطاق>/manager.php"
echo "👤 المستخدم: $TFM_USER"
