# PHP Tiny Manager Installer / مُثبت Tiny File Manager (PHP)

## IMPORTANT — Read before running
**English**
1. Always review the installer script before running it on any server.  
2. Download the script, inspect its contents, verify its checksum (SHA256) from a trusted source or repository commit, and only then run it if you trust the code.  
3. Prefer testing on a disposable VM or staging server before running in production.

**العربي**
1. دائماً افحص سكربت التثبيت قبل تشغيله على أي سيرفر.  
2. حمِّل الملف، اطلع على محتواه، تحقّق من قيمة الـ SHA256 من مصدر موثوق (أو من commit في الـ repo)، ولا تنفّذ إلا إذا ثقت بالمصدر.  
3. من الأفضل تجربة السكربت أولاً على جهاز افتراضي (VM) أو سيرفر اختبار قبل الإنتاج.

---

## How to safely install / كيف تثبّت بأمان

**Step-by-step (recommended) — English**

1. Download the installer to `/tmp` (do NOT pipe to `bash` directly):
```bash
curl -fsSL -o /tmp/setup_webserver.sh https://raw.githubusercontent.com/xXstrem/install-php-tiny/main/setup_webserver.sh
