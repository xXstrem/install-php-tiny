<?php
declare(strict_types=1);
session_start();

// ===== Configuration =====
$CONFIG = [
    'app_title' => 'لوحة إدارة الملفات',
    'welcome'   => 'أهلاً بك! تحكم بملفات السيرفر بسهولة.'
];
if (is_file(__DIR__ . '/config.php')) {
    $loaded = include __DIR__ . '/config.php';
    if (is_array($loaded)) {
        if (isset($loaded['username'])) $CONFIG['username'] = (string)$loaded['username'];
        if (isset($loaded['password'])) $CONFIG['password'] = (string)$loaded['password'];
    }
}

define('ROOT_DIR', realpath(__DIR__));
define('MANAGED_DIR', ROOT_DIR . DIRECTORY_SEPARATOR . 'public_html');
define('TRASH_DIR', ROOT_DIR . DIRECTORY_SEPARATOR . 'delete_files');
@is_dir(MANAGED_DIR) || @mkdir(MANAGED_DIR, 0775, true);
@is_dir(TRASH_DIR) || @mkdir(TRASH_DIR, 0775, true);

function redirect(string $url): void { header("Location: $url"); exit; }
function is_authed(): bool { return !empty($_SESSION['auth']); }
function ensure_auth(): void { if (!is_authed()) redirect('index.php?view=login'); }

if (!isset($_SESSION['csrf'])) {
    $_SESSION['csrf'] = bin2hex(random_bytes(16));
}
function require_csrf(): void {
    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        if (!isset($_POST['csrf']) || !hash_equals($_SESSION['csrf'], (string)$_POST['csrf'])) {
            http_response_code(400);
            exit('CSRF token invalid');
        }
    }
}

// Flash notifications
function flash_set(string $msg, string $type = 'success'): void {
    $_SESSION['flash'] = ['msg' => $msg, 'type' => $type];
}
function flash_get(): ?array {
    if (!isset($_SESSION['flash'])) return null;
    $f = $_SESSION['flash'];
    unset($_SESSION['flash']);
    return $f;
}

function clean_rel(string $rel): string {
    $rel = str_replace(['\\'], '/', $rel);
    $rel = preg_replace('#/+#', '/', $rel);
    $parts = [];
    foreach (explode('/', $rel) as $p) {
        if ($p === '' || $p === '.') continue;
        if ($p === '..') { array_pop($parts); continue; }
        $parts[] = $p;
    }
    return implode('/', $parts);
}

function resolve_path(?string $rel): string {
    $rel = $rel ? clean_rel($rel) : '';
    $full = rtrim(MANAGED_DIR . '/' . $rel, '/');
    $real = realpath($full) ?: $full;
    if (strpos($real, MANAGED_DIR) !== 0) {
        return MANAGED_DIR; 
    }
    return $real;
}

function human_size(int $bytes): string {
    $units = ['B','KB','MB','GB','TB'];
    $i = 0; $size = (float)$bytes;
    while ($size >= 1024 && $i < count($units)-1) { $size /= 1024; $i++; }
    return number_format($size, $i === 0 ? 0 : 2) . ' ' . $units[$i];
}

function list_dir(string $dir): array {
    $items = @scandir($dir) ?: [];
    $out = [];
    foreach ($items as $name) {
        if ($name === '.' || $name === '..') continue;
        $path = $dir . DIRECTORY_SEPARATOR . $name;
        $isDir = is_dir($path);
        $out[] = [
            'name' => $name,
            'is_dir' => $isDir,
            'size' => $isDir ? 0 : (int)@filesize($path),
            'mtime' => (int)@filemtime($path),
        ];
    }
    usort($out, function($a, $b){
        if ($a['is_dir'] !== $b['is_dir']) return $a['is_dir'] ? -1 : 1;
        return strnatcasecmp($a['name'], $b['name']);
    });
    return $out;
}
// URL for serving a managed file directly via web server
function url_for_path(string $rel): string {
    $rel = clean_rel($rel);
    $rel = implode('/', array_map('rawurlencode', array_filter(explode('/', $rel), fn($s)=>$s!=='')));
    $base = str_replace('\\','/', ROOT_DIR);
    $managed = str_replace('\\','/', MANAGED_DIR);
    $prefix = '';
    if (strpos($managed, $base) === 0) {
        $sub = trim(substr($managed, strlen($base)), '/');
        $prefix = $sub === '' ? '' : $sub . '/';
    }
    return ($prefix . $rel);
}
function compute_stats(string $dir): array {
    $files = 0; $folders = 0; $size = 0;
    if (!is_dir($dir)) return ['files'=>0,'folders'=>0,'size'=>0];
    $it = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS),
        RecursiveIteratorIterator::SELF_FIRST
    );
    foreach ($it as $f) {
        if ($f->isDir()) { $folders++; } else { $files++; $size += (int)$f->getSize(); }
    }
    return ['files'=>$files,'folders'=>$folders,'size'=>$size];
}

function file_icon_svg(string $name, bool $isDir): string {
    if ($isDir) {
        return '<svg class="file-icon text-indigo-400" viewBox="0 0 24 24" fill="currentColor"><path d="M10 4H6a2 2 0 00-2 2v12a2 2 0 002 2h12a2 2 0 002-2V8h-6l-2-4z"/></svg>';
    }
    $ext = strtolower(pathinfo($name, PATHINFO_EXTENSION));
    $kind = 'file'; $color = 'text-gray-400';
    if (in_array($ext, ['jpg','jpeg','png','gif','webp','svg'])) { $kind='image'; $color='text-pink-400'; }
    elseif (in_array($ext, ['pdf'])) { $kind='pdf'; $color='text-red-400'; }
    elseif (in_array($ext, ['zip','rar','7z','tar','gz','tar.gz'])) { $kind='archive'; $color='text-yellow-400'; }
    elseif (in_array($ext, ['mp4','mkv','avi','mov'])) { $kind='video'; $color='text-purple-400'; }
    elseif (in_array($ext, ['mp3','wav','ogg'])) { $kind='audio'; $color='text-green-400'; }
    elseif (in_array($ext, ['html','htm'])) { $kind='html'; $color='text-orange-400'; }
    elseif (in_array($ext, ['css'])) { $kind='css'; $color='text-blue-400'; }
    elseif (in_array($ext, ['js','ts','jsx','tsx'])) { $kind='js'; $color='text-yellow-400'; }
    elseif (in_array($ext, ['php','py','rb','go','java','c','cpp','cs','sh','md','txt','json','xml','yml','yaml','ini','conf','sql'])) { $kind='code'; $color='text-sky-400'; }

    switch ($kind) {
        case 'image':
            return '<svg class="file-icon '.$color.'" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="5" width="18" height="14" rx="2"/><circle cx="8" cy="10" r="1.5"/><path d="M3 17l5-5 4 4 3-3 3 3"/></svg>';
        case 'pdf':
            return '<svg class="file-icon '.$color.'" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 3H6a2 2 0 00-2 2v14a2 2 0 002 2h12a2 2 0 002-2V9z"/><path d="M14 3v6h6"/><path d="M8 15h2M10 15v4M8 19h2M14 19v-4h3"/></svg>';
        case 'archive':
            return '<svg class="file-icon '.$color.'" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="4" width="18" height="6" rx="1"/><path d="M7 4v6M11 4v6M15 4v6M3 10v8a2 2 0 002 2h14a2 2 0 002-2v-8z"/></svg>';
        case 'video':
            return '<svg class="file-icon '.$color.'" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="6" width="14" height="12" rx="2"/><path d="M17 8l4 2v4l-4 2z"/></svg>';
        case 'audio':
            return '<svg class="file-icon '.$color.'" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M9 18V6l8-2v12"/><circle cx="7" cy="18" r="2"/><circle cx="17" cy="16" r="2"/></svg>';
        case 'html':
            return '<svg class="file-icon '.$color.'" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 3H6a2 2 0 00-2 2v14a2 2 0 002 2h12a2 2 0 002-2V9z"/><path d="M14 3v6h6"/><path d="M9.5 15l-2.5-2.5L9.5 10M14.5 10l2.5 2.5-2.5 2.5"/></svg>';
        case 'css':
            return '<svg class="file-icon '.$color.'" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 3H6a2 2 0 00-2 2v14a2 2 0 002 2h12a2 2 0 002-2V9z"/><path d="M14 3v6h6"/><path d="M8 16h8M8 12h8"/></svg>';
        case 'js':
            return '<svg class="file-icon '.$color.'" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 3H6a2 2 0 00-2 2v14a2 2 0 002 2h12a2 2 0 002-2V9z"/><path d="M14 3v6h6"/><path d="M9 16c0 1.1.9 2 2 2s2-.9 2-2m-6-4h6"/></svg>';
        case 'code':
            return '<svg class="file-icon '.$color.'" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 3H6a2 2 0 00-2 2v14a2 2 0 002 2h12a2 2 0 002-2V9z"/><path d="M14 3v6h6"/><path d="M10 14l-2 2 2 2M14 14l2 2-2 2"/></svg>';
        case 'sheet':
            return '<svg class="file-icon '.$color.'" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 3H6a2 2 0 00-2 2v14a2 2 0 002 2h12a2 2 0 002-2V9z"/><path d="M14 3v6h6"/><path d="M8 12h8M8 16h8"/></svg>';
        default:
            return '<svg class="file-icon '.$color.'" viewBox="0 0 24 24" fill="currentColor"><path d="M14 3H6a2 2 0 00-2 2v14a2 2 0 002 2h12a2 2 0 002-2V9z"/><path d="M14 3v6h6" fill="currentColor"/></svg>';
    }
}

function code_lang_badge(string $name): string {
    $ext = strtolower(pathinfo($name, PATHINFO_EXTENSION));
    $map = [
        'php' => ['PHP', 'bg-indigo-100 text-indigo-700'],
        'html'=> ['HTML','bg-orange-100 text-orange-700'],
        'htm' => ['HTML','bg-orange-100 text-orange-700'],
        'css' => ['CSS','bg-blue-100 text-blue-700'],
        'js'  => ['JS','bg-yellow-100 text-yellow-700'],
        'ts'  => ['TS','bg-sky-100 text-sky-700'],
        'py'  => ['PY','bg-green-100 text-green-700'],
        'json'=> ['JSON','bg-gray-100 text-gray-700'],
        'xml' => ['XML','bg-purple-100 text-purple-700'],
        'rb'  => ['RB','bg-red-100 text-red-700'],
        'go'  => ['GO','bg-cyan-100 text-cyan-700'],
        'java'=> ['JAVA','bg-amber-100 text-amber-700'],
        'c'   => ['C','bg-teal-100 text-teal-700'],
        'cpp' => ['C++','bg-teal-100 text-teal-700'],
        'cs'  => ['C#','bg-violet-100 text-violet-700'],
        'sh'  => ['SH','bg-zinc-100 text-zinc-700'],
        'md'  => ['MD','bg-stone-100 text-stone-700'],
        'txt' => ['TXT','bg-stone-100 text-stone-700'],
    ];
    if (!isset($map[$ext])) return '';
    [$label,$classes] = $map[$ext];
    return '<span class="ml-2 px-2 py-0.5 rounded text-xs '.$classes.'">'.$label.'</span>';
}

function detect_mime(string $path): string {
    if (function_exists('finfo_open')) {
        $f = finfo_open(FILEINFO_MIME_TYPE);
        if ($f) { $m = finfo_file($f, $path) ?: 'application/octet-stream'; finfo_close($f); return $m; }
    }
    $ext = strtolower(pathinfo($path, PATHINFO_EXTENSION));
    $map = [
        'html'=>'text/html; charset=utf-8','htm'=>'text/html; charset=utf-8','txt'=>'text/plain; charset=utf-8','md'=>'text/plain; charset=utf-8',
        'css'=>'text/css; charset=utf-8','js'=>'application/javascript; charset=utf-8','json'=>'application/json; charset=utf-8','xml'=>'application/xml; charset=utf-8',
        'jpg'=>'image/jpeg','jpeg'=>'image/jpeg','png'=>'image/png','gif'=>'image/gif','webp'=>'image/webp','svg'=>'image/svg+xml; charset=utf-8','pdf'=>'application/pdf',
        'mp3'=>'audio/mpeg','wav'=>'audio/wav','ogg'=>'audio/ogg','mp4'=>'video/mp4','mkv'=>'video/x-matroska'
    ];
    return $map[$ext] ?? 'application/octet-stream';
}

function is_code_file(string $name): bool {
    $ext = strtolower(pathinfo($name, PATHINFO_EXTENSION));
    $code = ['php','html','htm','css','js','ts','jsx','tsx','py','rb','go','java','c','cpp','cs','sh','md','txt','json','xml','yml','yaml','ini','conf','sql'];
    return in_array($ext, $code, true);
}

function perms_octal(string $path): string {
    $p = @fileperms($path);
    if ($p === false) return '----';
    return substr(sprintf('%o', $p), -4);
}

// ===== Routing & Actions =====
$view = $_GET['view'] ?? '';
$dirRel = $_GET['dir'] ?? '';
$dirAbs = resolve_path($dirRel);
$tab = $_GET['tab'] ?? 'dashboard';

$action = $_REQUEST['action'] ?? '';

// Login
if ($action === 'login' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    require_csrf();
    $u = $_POST['username'] ?? '';
    $p = $_POST['password'] ?? '';
    if (hash_equals($CONFIG['username'], $u) && hash_equals($CONFIG['password'], $p)) {
        $_SESSION['auth'] = true;
        redirect('index.php');
    } else {
        $login_error = 'بيانات الدخول غير صحيحة';
        $view = 'login';
    }
}

$configFile = ROOT_DIR . DIRECTORY_SEPARATOR . 'config.php';

// Logout
if ($action === 'logout') {
    session_unset();
    session_destroy();
    session_start();
    $_SESSION['csrf'] = bin2hex(random_bytes(16));
    redirect('index.php?view=login');
}

// Download
if ($action === 'download') {
    ensure_auth();
    $fileRel = $_GET['file'] ?? '';
    $fileAbs = resolve_path(($dirRel ? $dirRel.'/' : '') . $fileRel);
    if (!is_file($fileAbs)) { http_response_code(404); exit('File not found'); }
    $name = basename($fileAbs);
    header('Content-Description: File Transfer');
    header('Content-Type: application/octet-stream');
    header('Content-Disposition: attachment; filename="' . rawurlencode($name) . '"');
    header('Content-Length: ' . (string)filesize($fileAbs));
    header('Cache-Control: no-store');
    readfile($fileAbs);
    exit;
}

// View inline
if ($action === 'view') {
    ensure_auth();
    $fileRel = $_GET['file'] ?? '';
    $fileAbs = resolve_path(($dirRel ? $dirRel.'/' : '') . $fileRel);
    if (!is_file($fileAbs)) { http_response_code(404); exit('File not found'); }
    $name = basename($fileAbs);
    $mime = detect_mime($fileAbs);
    header('Content-Type: ' . $mime);
    header('Content-Disposition: inline; filename="' . rawurlencode($name) . '"');
    header('Cache-Control: no-store');
    readfile($fileAbs);
    exit;
}

// Preview in UI
$preview = null;
if ($action === 'preview') {
    ensure_auth();
    $fileRel = $_GET['file'] ?? '';
    $fileAbs = resolve_path(($dirRel ? $dirRel.'/' : '') . $fileRel);
    if (is_file($fileAbs)) {
        $mime = detect_mime($fileAbs);
        $name = basename($fileAbs);
        $content = '';
        $isText = preg_match('/^(text\/|application\/(json|xml|javascript))/', $mime) || is_code_file($name) || in_array(strtolower(pathinfo($name, PATHINFO_EXTENSION)), ['md','txt','html','css','js','php','py','rb','json','xml']);
        if ($isText) {
            $raw = @file_get_contents($fileAbs);
            $content = $raw === false ? '' : $raw;
        }
        $preview = [
            'rel' => $fileRel,
            'abs' => $fileAbs,
            'name'=> $name,
            'mime'=> $mime,
            'is_text' => $isText,
            'content' => $isText ? $content : '',
            'size' => @filesize($fileAbs) ?: 0,
            'mtime'=> @filemtime($fileAbs) ?: time(),
        ];
    }
}

// Auth-only actions
if (in_array($action, ['create_folder','create_file','delete','rename','upload','save_edit'], true)) {
    ensure_auth();
    require_csrf();
}

// Update account (settings)
if ($action === 'update_account' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    ensure_auth();
    require_csrf();
    $newUser = trim($_POST['username'] ?? '');
    $newPass = (string)($_POST['password'] ?? '');
    if ($newUser !== '') $CONFIG['username'] = $newUser;
    if ($newPass !== '') $CONFIG['password'] = $newPass;
    $php = "<?php\nreturn [\n    'username' => '" . addslashes($CONFIG['username']) . "',\n    'password' => '" . addslashes($CONFIG['password']) . "',\n];\n";
    @file_put_contents($configFile, $php);
    flash_set('تم حفظ الإعدادات بنجاح', 'success');
    redirect('index.php?tab=settings');
}

// Create folder
if ($action === 'create_folder' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    $name = trim($_POST['name'] ?? '');
    if ($name !== '') {
        $target = resolve_path(($dirRel ? $dirRel.'/' : '') . $name);
        if (!file_exists($target)) @mkdir($target, 0775, false);
    }
    flash_set('تم إنشاء المجلد', 'success');
    redirect('index.php?tab=' . rawurlencode($tab) . '&dir=' . rawurlencode($dirRel));
}

// Create file
if ($action === 'create_file' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    $name = trim($_POST['name'] ?? '');
    if ($name !== '') {
        $target = resolve_path(($dirRel ? $dirRel.'/' : '') . $name);
        if (!file_exists($target)) {
            @file_put_contents($target, "");
        }
    }
    flash_set('تم إنشاء الملف', 'success');
    redirect('index.php?tab=' . rawurlencode($tab) . '&dir=' . rawurlencode($dirRel));
}

// Delete file/folder
if ($action === 'delete' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    $name = $_POST['name'] ?? '';
    $target = resolve_path(($dirRel ? $dirRel.'/' : '') . $name);
    if (file_exists($target)) {
        $base = basename($target);
        $stamp = date('Ymd_His');
        $dest = TRASH_DIR . DIRECTORY_SEPARATOR . $base . '__' . $stamp;
        @rename($target, $dest);
    }
    flash_set('تم النقل إلى سلة المحذوفات', 'success');
    redirect('index.php?tab=' . rawurlencode($tab) . '&dir=' . rawurlencode($dirRel));
}

// Restore from trash
if ($action === 'restore' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    $name = $_POST['name'] ?? '';
    $trashItem = TRASH_DIR . DIRECTORY_SEPARATOR . basename($name);
    if (file_exists($trashItem)) {
        $originalBase = preg_replace('/__\d{8}_\d{6}$/', '', basename($trashItem));
        $dest = MANAGED_DIR . DIRECTORY_SEPARATOR . $originalBase;
        $i = 1; $baseName = pathinfo($originalBase, PATHINFO_FILENAME); $ext = pathinfo($originalBase, PATHINFO_EXTENSION);
        while (file_exists($dest)) {
            $suffix = ' (' . $i++ . ')';
            $dest = MANAGED_DIR . DIRECTORY_SEPARATOR . ($ext ? $baseName.$suffix.'.'.$ext : $baseName.$suffix);
        }
        @rename($trashItem, $dest);
    }
    flash_set('تم الاسترجاع بنجاح', 'success');
    redirect('index.php?tab=trash');
}

// Rename
if ($action === 'rename' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    $old = $_POST['old'] ?? '';
    $new = $_POST['new'] ?? '';
    if ($old !== '' && $new !== '') {
        $oldPath = resolve_path(($dirRel ? $dirRel.'/' : '') . $old);
        $newPath = resolve_path(($dirRel ? $dirRel.'/' : '') . $new);
        if ($oldPath !== $newPath && file_exists($oldPath) && !file_exists($newPath)) {
            @rename($oldPath, $newPath);
        }
    }
    flash_set('تمت إعادة التسمية', 'success');
    redirect('index.php?tab=' . rawurlencode($tab) . '&dir=' . rawurlencode($dirRel));
}

// Upload
if ($action === 'upload' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    if (!empty($_FILES['files'])) {
        $files = $_FILES['files'];
        $count = is_array($files['name']) ? count($files['name']) : 0;
        for ($i = 0; $i < $count; $i++) {
            if ($files['error'][$i] === UPLOAD_ERR_OK) {
                $name = basename($files['name'][$i]);
                $dest = resolve_path(($dirRel ? $dirRel.'/' : '') . $name);
                @move_uploaded_file($files['tmp_name'][$i], $dest);
            }
        }
    }
    flash_set('تم رفع الملف(ات)', 'success');
    redirect('index.php?tab=' . rawurlencode($tab) . '&dir=' . rawurlencode($dirRel));
}

// Prepare editor (GET)
$editor = null;
if ($action === 'edit') {
    ensure_auth();
    $fileRel = $_GET['file'] ?? '';
    $fileAbs = resolve_path(($dirRel ? $dirRel.'/' : '') . $fileRel);
    if (is_file($fileAbs) && is_code_file($fileAbs)) {
        $content = @file_get_contents($fileAbs);
        if ($content === false) $content = '';
        $editor = [
            'rel' => $fileRel,
            'name'=> basename($fileAbs),
            'content' => $content,
        ];
    } else {
        redirect('index.php?tab=' . rawurlencode($tab) . '&dir=' . rawurlencode($dirRel));
    }
}

// Save editor (POST)
if ($action === 'save_edit' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    $fileRel = $_POST['file'] ?? '';
    $fileAbs = resolve_path(($dirRel ? $dirRel.'/' : '') . $fileRel);
    if (is_file($fileAbs) && is_code_file($fileAbs)) {
        $content = $_POST['content'] ?? '';
        @file_put_contents($fileAbs, $content, LOCK_EX);
    }
    redirect('index.php?tab=' . rawurlencode($tab) . '&dir=' . rawurlencode($dirRel));
}

// ===== View selection =====
if (!is_authed()) {
    $view = 'login';
}

// Prepare breadcrumbs
function breadcrumbs(string $rel): array {
    $rel = clean_rel($rel);
    if ($rel === '') return [];
    $parts = explode('/', $rel);
    $crumbs = [];
    for ($i=0;$i<count($parts);$i++) {
        $crumbs[] = [
            'name' => $parts[$i],
            'dir'  => implode('/', array_slice($parts, 0, $i+1))
        ];
    }
    return $crumbs;
}

// Fetch listing if authed
$items = [];
$trashItems = [];
if ($view !== 'login' && $editor === null) {
    $items = list_dir($dirAbs);
    if ($tab === 'trash') { $trashItems = list_dir(TRASH_DIR); }
}
?>
<!doctype html>
<html lang="ar" dir="rtl">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title><?= htmlspecialchars($CONFIG['app_title']) ?></title>
  <script src="https://cdn.tailwindcss.com"></script>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Cairo:wght@300;400;600;700&display=swap" rel="stylesheet">
  <style>
    body { box-sizing: border-box; }
    * { font-family: 'Cairo', sans-serif; }
    .gradient-bg { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); }
    .glass-effect { background: rgba(255,255,255,0.1); backdrop-filter: blur(10px); border: 1px solid rgba(255,255,255,0.2); }
    .file-card { background: rgba(255,255,255,0.95); box-shadow: 0 8px 24px rgba(0,0,0,.05); }
    /* إلغاء أي انيميشن أو تحريك عند التحويم */
    .file-card:hover { transform: none; box-shadow: 0 8px 24px rgba(0,0,0,.08); }
    .file-card.menu-open,
    .file-card.menu-open:hover { transform: none !important; box-shadow: 0 8px 24px rgba(0,0,0,.12); }
    .upload-zone { border: 2px dashed #cbd5e0; transition: all .3s ease; }
    .upload-zone:hover { border-color: #667eea; background: rgba(102,126,234,0.05); }
    .sidebar-item { transition: all .2s ease; }
    .sidebar-item:hover { background: rgba(255,255,255,0.1); transform: translateX(-5px); }
    .sidebar-item.active { background: rgba(255,255,255,0.2); border-right: 4px solid #fff; }
    .file-icon { width: 18px; height: 18px; }
    @media (min-width: 1024px) { .file-icon { width: 20px; height: 20px; } }
  </style>
</head>
<body class="gradient-bg min-h-screen">

<?php $FLASH = flash_get(); if ($FLASH): ?>
<script>
  window.__FLASH__ = { msg: <?= json_encode($FLASH['msg'], JSON_UNESCAPED_UNICODE) ?>, type: <?= json_encode($FLASH['type']) ?> };
  delete window.sessionStorage.__dummy;
</script>
<?php endif; ?>
<?php
  $__base = str_replace('\\','/', ROOT_DIR);
  $__managed = str_replace('\\','/', MANAGED_DIR);
  $__prefix = '';
  if (strpos($__managed, $__base) === 0) {
      $__sub = trim(substr($__managed, strlen($__base)), '/');
      $__prefix = $__sub === '' ? '' : ($__sub . '/');
  }
?>
<script>
  window.__MANAGED_PREFIX__ = <?= json_encode($__prefix) ?>;
  // Rewrite any action=view links and media to direct file path
  function toDirectPath(url) {
    try {
      const u = new URL(url, window.location.href);
      const dir = (u.searchParams.get('dir') || '').replace(/\\\\/g,'/').replace(/^\/+|\/+$/g,'');
      const file = u.searchParams.get('file') || '';
      const rel = (dir ? dir + '/' : '') + file;
      return (window.__MANAGED_PREFIX__ || '') + rel;
    } catch (e) { return url; }
  }
  window.addEventListener('DOMContentLoaded', () => {
    document.querySelectorAll('a[href*="action=view"]').forEach(a => {
      a.removeAttribute('target');
      a.setAttribute('href', toDirectPath(a.getAttribute('href')));
    });
    document.querySelectorAll('img[src*="action=view"]').forEach(img => {
      img.setAttribute('src', toDirectPath(img.getAttribute('src')));
    });
    document.querySelectorAll('iframe[src*="action=view"]').forEach(el => {
      el.setAttribute('src', toDirectPath(el.getAttribute('src')));
    });
  });
</script>

<?php if ($view === 'login'): ?>
  <div class="min-h-screen flex items-center justify-center p-6">
    <div class="max-w-md w-full">
      <div class="glass-effect rounded-2xl p-8 border border-white/20">
        <div class="text-center mb-8">
          <div class="bg-white/20 w-16 h-16 rounded-full flex items-center justify-center mx-auto mb-4">
            <svg class="w-8 h-8 text-white" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-6-3a2 2 0 11-4 0 2 2 0 014 0zm-2 4a5 5 0 00-4.546 2.916A5.986 5.986 0 0010 16a5.986 5.986 0 004.546-2.084A5 5 0 0010 11z"/></svg>
          </div>
          <h2 class="text-2xl font-bold text-white mb-2">تسجيل الدخول</h2>
          <p class="text-white/80">أدخل بياناتك للوصول إلى لوحة إدارة الملفات</p>
        </div>
        <?php if (!empty($login_error)): ?>
          <div class="mb-4 bg-red-500/20 text-white px-4 py-2 rounded-lg border border-white/20"><?= htmlspecialchars($login_error) ?></div>
        <?php endif; ?>
        <form method="post" action="index.php?action=login" class="space-y-6">
          <input type="hidden" name="csrf" value="<?= htmlspecialchars($_SESSION['csrf']) ?>">
          <div>
            <label for="username" class="block text-white text-sm font-medium mb-2">اسم المستخدم</label>
            <input type="text" id="username" name="username" required class="w-full px-4 py-3 bg-white/10 border border-white/20 rounded-lg text-white placeholder-white/60 focus:outline-none focus:ring-2 focus:ring-white/50 focus:border-transparent" placeholder="أدخل اسم المستخدم">
          </div>
          <div>
            <label for="password" class="block text-white text-sm font-medium mb-2">كلمة المرور</label>
            <input type="password" id="password" name="password" required class="w-full px-4 py-3 bg-white/10 border border-white/20 rounded-lg text-white placeholder-white/60 focus:outline-none focus:ring-2 focus:ring-white/50 focus:border-transparent" placeholder="أدخل كلمة المرور">
          </div>
          <button type="submit" class="w-full bg-white/20 text-white px-6 py-3 rounded-lg hover:bg-white/30 transition-colors">دخول</button>
        </form>
      </div>
    </div>
  </div>
<?php else: ?>

  <div class="min-h-screen p-4 lg:p-8 relative">
    <div id="sidebar-overlay" class="fixed inset-0 bg-black/50 backdrop-blur-sm hidden lg:hidden z-30"></div>
    <div class="max-w-7xl mx-auto grid grid-cols-1 lg:grid-cols-4 gap-6">
      <aside id="sidebar" class="glass-effect rounded-2xl p-6 h-max border border-white/20 transform lg:transform-none translate-x-full lg:translate-x-0 transition-transform duration-200 fixed lg:static top-0 right-0 h-full w-72 lg:w-auto z-40 lg:z-auto">
        <div class="mb-8">
          <h2 class="text-2xl font-bold text-white mb-1">لوحة إدارة الملفات</h2>
          <p class="text-white/80 text-sm">مرحباً بك في لوحة إدارة الملفات</p>
        </div>
        <nav class="space-y-2">
          <a class="flex items-center justify-between px-4 py-3 rounded-xl <?= $tab==='dashboard' ? 'bg-white/20 text-white shadow-inner border border-white/30' : 'sidebar-item text-white/90 hover:bg-white/10' ?>" href="index.php?tab=dashboard&amp;dir=<?= rawurlencode($dirRel) ?>">
            <span>لوحة التحكم</span>
            <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 20 20"><path d="M3 3h6v6H3V3zm0 8h6v6H3v-6zm8-8h6v6h-6V3zm0 8h6v6h-6v-6z"/></svg>
          </a>
          <a class="flex items-center justify-between px-4 py-3 rounded-xl <?= $tab==='all' ? 'bg-white/20 text-white shadow-inner border border-white/30' : 'sidebar-item text-white/90 hover:bg-white/10' ?>" href="index.php?tab=all&amp;dir=<?= rawurlencode($dirRel) ?>">
            <span>جميع الملفات</span>
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><rect x="6" y="8" width="12" height="8" rx="1" stroke-width="2"/></svg>
          </a>
          <a class="flex items-center justify-between px-4 py-3 rounded-xl <?= $tab==='folders' ? 'bg-white/20 text-white shadow-inner border border-white/30' : 'sidebar-item text-white/90 hover:bg-white/10' ?>" href="index.php?tab=folders&amp;dir=<?= rawurlencode($dirRel) ?>">
            <span>المجلدات</span>
            <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 20 20"><path d="M2 6a2 2 0 012-2h4l2 2h6a2 2 0 012 2v6a2 2 0 01-2 2H4a2 2 0 01-2-2V6z"/></svg>
          </a>
          <a class="flex items-center justify-between px-4 py-3 rounded-xl <?= $tab==='downloads' ? 'bg-white/20 text-white shadow-inner border border-white/30' : 'sidebar-item text-white/90 hover:bg-white/10' ?>" href="index.php?tab=downloads&amp;dir=<?= rawurlencode($dirRel) ?>">
            <span>التحميلات</span>
            <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M3 14a1 1 0 011-1h3V3a1 1 0 112 0v10h3a1 1 0 011 1v2a1 1 0 11-2 0v-1H6v1a1 1 0 11-2 0v-2z"/></svg>
          </a>
          <a class="flex items-center justify-between px-4 py-3 rounded-xl <?= $tab==='trash' ? 'bg-white/20 text-white shadow-inner border border-white/30' : 'sidebar-item text-white/90 hover:bg-white/10' ?>" href="index.php?tab=trash&amp;dir=<?= rawurlencode($dirRel) ?>">
            <span>سلة المحذوفات</span>
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-width="2" d="M6 7h12m-9 3v7m6-7v7M7 7l1 12a2 2 0 002 2h4a2 2 0 002-2l1-12M9 7l1-2h4l1 2"/></svg>
          </a>
          <a class="flex items-center justify-between px-4 py-3 rounded-xl <?= $tab==='settings' ? 'bg-white/20 text-white shadow-inner border border-white/30' : 'sidebar-item text-white/90 hover:bg-white/10' ?>" href="index.php?tab=settings&amp;dir=<?= rawurlencode($dirRel) ?>">
            <span>الإعدادات</span>
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-width="2" d="M12 15a3 3 0 100-6 3 3 0 000 6zm7.4-3a5.4 5.4 0 00-.1-1l2.1-1.6-2-3.5-2.5 1a5.5 5.5 0 00-1.7-1L14.8 2h-3.6l-.4 2.9a5.5 5.5 0 00-1.7 1l-2.5-1-2 3.5 2.1 1.6a5.4 5.4 0 000 2l-2.1 1.6 2 3.5 2.5-1a5.5 5.5 0 001.7 1l.4 2.9h3.6l.4-2.9a5.5 5.5 0 001.7-1l2.5 1 2-3.5-2.1-1.6c.1-.3.1-.7.1-1z"/></svg>
          </a>
        </nav>
        <hr class="my-6 border-t border-white/20">
        <a href="index.php?action=logout" class="flex items-center justify-between px-4 py-2 text-white/80 hover:text-white">
          <span>تسجيل الخروج</span>
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-width="2" d="M13 7l5 5-5 5m-6-5h11"/></svg>
        </a>
      </aside>

      <main class="lg:col-span-3 space-y-6">
        <?php if ($editor !== null): ?>
        <!-- Editor View -->
        <?php if ($preview===null): ?>
        <div class="glass-effect rounded-xl p-4 border border-white/20">
          <div class="flex items-center justify-between mb-4">
            <div class="text-white text-lg font-semibold">تعديل: <?= htmlspecialchars($editor['name']) ?></div>
            <a class="bg-white/10 text-white px-3 py-1 rounded hover:bg-white/20" href="index.php?dir=<?= rawurlencode($dirRel) ?>">رجوع</a>
          </div>
            <form method="post" action="index.php?action=save_edit&amp;tab=<?= htmlspecialchars($tab) ?>&amp;dir=<?= rawurlencode($dirRel) ?>" class="space-y-3">
            <input type="hidden" name="csrf" value="<?= htmlspecialchars($_SESSION['csrf']) ?>">
            <input type="hidden" name="file" value="<?= htmlspecialchars($editor['rel']) ?>">
            <textarea name="content" class="w-full h-[60vh] p-3 rounded bg-white/90 text-gray-900 font-mono text-sm" spellcheck="false"><?= htmlspecialchars($editor['content']) ?></textarea>
              <div class="hidden lg:flex gap-2">
              <button class="bg-green-500 text-white px-4 py-2 rounded hover:bg-green-600">حفظ</button>
              <a class="bg-gray-100 text-gray-800 px-4 py-2 rounded hover:bg-gray-200" href="index.php?dir=<?= rawurlencode($dirRel) ?>">إلغاء</a>
            </div>
          </form>
        </div>
        <?php endif; ?>
        <?php else: ?>
        <?php if ($preview===null): ?>
        <div class="glass-effect rounded-xl p-4 lg:p-6 border border-white/20 flex flex-col lg:flex-row lg:items-center items-start justify-between gap-3 lg:gap-0">
          <button id="mobile-menu-btn" class="lg:hidden text-white/90 bg-white/10 rounded-lg p-2">
            <svg class="w-6 h-6" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M3 5h14a1 1 0 010 2H3a1 1 0 010-2zm0 4h14a1 1 0 010 2H3a1 1 0 010-2zm0 4h14a1 1 0 010 2H3a1 1 0 010-2z"/></svg>
          </button>
          <div class="text-right">
            <h1 class="text-2xl lg:text-3xl font-bold text-white">لوحة التحكم الرئيسية</h1>
            <p class="text-white/80">إدارة وتنظيم ملفاتك بسهولة</p>
            <div class="flex gap-2 mt-3 lg:hidden">
              <button id="open-upload-actions-m" class="bg-white text-indigo-700 font-medium px-4 py-2 rounded-xl hover:bg-indigo-50 flex items-center gap-2">
                <span>رفع ملف جديد</span>
                <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 20 20"><path d="M3 16a1 1 0 011-1h12a1 1 0 110 2H4a1 1 0 01-1-1zm6-4V4a1 1 0 112 0v8h3l-4 4-4-4h3z"/></svg>
              </button>
              <button id="open-create-m" class="bg-white/10 text-white font-medium px-4 py-2 rounded-xl hover:bg-white/20">إنشاء</button>
            </div>
          </div>
          <div class="flex-1"></div>
          <div>
              <div class="hidden lg:flex gap-2">
              <button id="open-upload-actions" class="bg-white text-indigo-700 font-medium px-4 lg:px-6 py-2 rounded-xl hover:bg-indigo-50 flex items-center gap-2">
                <span>رفع ملف جديد</span>
                <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 20 20"><path d="M3 16a1 1 0 011-1h12a1 1 0 110 2H4a1 1 0 01-1-1zm6-4V4a1 1 0 112 0v8h3l-4 4-4-4h3z"/></svg>
              </button>
              <button id="open-create" class="bg-white/10 text-white font-medium px-4 lg:px-6 py-2 rounded-xl hover:bg-white/20">إنشاء</button>
            </div>
          </div>
        </div>
        <?php endif; ?>

        <?php if ($preview !== null): ?>
        <!-- File preview page -->
        <div class="glass-effect rounded-xl p-4 lg:p-6 border border-white/20 fade-in-up">
          <div class="flex items-center justify-between mb-4">
            <div class="text-white text-lg lg:text-xl font-semibold">ملف: <?= htmlspecialchars($preview['name']) ?></div>
            <a class="bg-white/10 text-white px-3 py-1 rounded hover:bg-white/20" href="index.php?tab=<?= htmlspecialchars($tab) ?>&amp;dir=<?= rawurlencode($dirRel) ?>">رجوع</a>
          </div>
          <div class="flex flex-wrap gap-2 mb-4">
            <a class="px-3 py-1 rounded-lg bg-blue-100 text-blue-700" target="_blank" href="index.php?action=view&amp;dir=<?= rawurlencode($dirRel) ?>&amp;file=<?= rawurlencode($preview['name']) ?>">عرض</a>
            <a class="px-3 py-1 rounded-lg bg-green-100 text-green-700" href="index.php?action=download&amp;dir=<?= rawurlencode($dirRel) ?>&amp;file=<?= rawurlencode($preview['name']) ?>">تحميل</a>
            <?php if (is_code_file($preview['name'])): ?>
              <a class="px-3 py-1 rounded-lg bg-amber-100 text-amber-700" href="index.php?action=edit&amp;dir=<?= rawurlencode($dirRel) ?>&amp;file=<?= rawurlencode($preview['name']) ?>">تعديل</a>
            <?php endif; ?>
            <button class="px-3 py-1 rounded-lg bg-yellow-100 text-yellow-700" onclick="renameItem('<?= htmlspecialchars($preview['name']) ?>')">إعادة تسمية</button>
            <button class="px-3 py-1 rounded-lg bg-red-100 text-red-700" onclick="deleteItem('<?= htmlspecialchars($preview['name']) ?>')">حذف</button>
          </div>
          <div class="bg-white rounded-lg p-4 overflow-auto max-h-[70vh]">
            <?php
              $ext = strtolower(pathinfo($preview['name'], PATHINFO_EXTENSION));
              if (!$preview['is_text']) {
                  if (preg_match('/^image\//', $preview['mime'])) {
                      echo '<img src="index.php?action=view&amp;dir=' . rawurlencode($dirRel) . '&amp;file=' . rawurlencode($preview['name']) . '" class="max-w-full h-auto" />';
                  } elseif ($preview['mime'] === 'application/pdf') {
                      echo '<iframe class="w-full h-[70vh]" src="index.php?action=view&amp;dir=' . rawurlencode($dirRel) . '&amp;file=' . rawurlencode($preview['name']) . '"></iframe>';
                  } else {
                      echo '<div class="text-gray-700">لا يمكن عرض هذا النوع مباشرة. استخدم زر عرض أو تحميل.</div>';
                  }
              } else {
                  echo '<pre class="whitespace-pre-wrap text-sm text-gray-900">' . htmlspecialchars($preview['content']) . '</pre>';
              }
            ?>
          </div>
        </div>
        <?php endif; ?>

        <?php if ($preview===null): ?>
        <div class="glass-effect rounded-xl p-4 border border-white/20">
          <div class="flex flex-wrap items-center gap-2 text-white">
            <a class="hover:underline" href="index.php">الجذر</a>
            <?php foreach (breadcrumbs($dirRel) as $i => $c): ?>
              <span class="opacity-60">/</span>
              <a class="hover:underline" href="index.php?dir=<?= rawurlencode($c['dir']) ?>"><?= htmlspecialchars($c['name']) ?></a>
            <?php endforeach; ?>
            <?php if ($dirRel !== ''): ?>
              <?php
                $parentRel = '';
                $relClean = clean_rel($dirRel);
                if ($relClean !== '') {
                    $parts = explode('/', $relClean);
                    array_pop($parts);
                    $parentRel = implode('/', $parts);
                }
              ?>
              <span class="flex-1"></span>
              <a class="bg-white/10 text-white px-3 py-1 rounded hover:bg-white/20" href="index.php?dir=<?= rawurlencode($parentRel) ?>">رجوع</a>
            <?php endif; ?>
          </div>
        </div>
        <?php endif; ?>

        <?php $stats = compute_stats($dirAbs); ?>
        <?php if ($preview===null && $tab === 'dashboard'): ?>
        <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div class="stats-card p-4 rounded-xl border border-white/20 flex items-center justify-between">
            <div>
              <p class="text-white/80 text-sm">إجمالي الحجم</p>
              <p class="text-2xl font-bold text-white"><?= human_size($stats['size']) ?></p>
            </div>
            <div class="bg-blue-500/20 p-3 rounded-lg">
              <svg class="w-6 h-6 text-blue-400" fill="currentColor" viewBox="0 0 20 20"><path d="M4 3a2 2 0 00-2 2v3h16V5a2 2 0 00-2-2H4z"/><path d="M18 9H2v6a2 2 0 002 2h12a2 2 0 002-2V9z"/></svg>
            </div>
          </div>
          <div class="stats-card p-4 rounded-xl border border-white/20 flex items-center justify-between">
            <div>
              <p class="text-white/80 text-sm">عدد الملفات</p>
              <p class="text-2xl font-bold text-white"><?= (int)$stats['files'] ?></p>
            </div>
            <div class="bg-green-500/20 p-3 rounded-lg">
              <svg class="w-6 h-6 text-green-400" fill="currentColor" viewBox="0 0 20 20"><path d="M3 4a1 1 0 011-1h12a1 1 0 011 1v2a1 1 0 01-1 1H4a1 1 0 01-1-1V4zM3 10a1 1 0 011-1h6a1 1 0 011 1v6a1 1 0 01-1 1H4a1 1 0 01-1-1v-6zM14 9a1 1 0 00-1 1v6a1 1 0 001 1h2a1 1 0 001-1v-6a1 1 0 00-1-1h-2z"/></svg>
            </div>
          </div>
          <div class="stats-card p-4 rounded-xl border border-white/20 flex items-center justify-between">
            <div>
              <p class="text-white/80 text-sm">عدد المجلدات</p>
              <p class="text-2xl font-bold text-white"><?= (int)$stats['folders'] ?></p>
            </div>
            <div class="bg-purple-500/20 p-3 rounded-lg">
              <svg class="w-6 h-6 text-purple-400" fill="currentColor" viewBox="0 0 20 20"><path d="M2 6a2 2 0 012-2h3l2 2h7a2 2 0 012 2v6a2 2 0 01-2 2H4a2 2 0 01-2-2V6z"/></svg>
            </div>
          </div>
        </div>
        <?php endif; ?>

        <?php if ($preview===null && $tab === 'dashboard'): ?>
        <?php if ($preview===null): ?>
        <?php if ($preview===null): ?>
        <div class="glass-effect rounded-xl p-4 lg:p-6 border border-white/20">
            <form id="upload-inline" method="post" action="index.php?action=upload&amp;tab=<?= htmlspecialchars($tab) ?>&amp;dir=<?= rawurlencode($dirRel) ?>" enctype="multipart/form-data" class="upload-zone rounded-xl border-2 border-dashed border-white/30 p-8 lg:p-16 text-center">
            <input type="hidden" name="csrf" value="<?= htmlspecialchars($_SESSION['csrf']) ?>">
            <input id="file-input-inline" type="file" name="files[]" multiple class="hidden" />
            <svg class="w-16 h-16 text-white/70 mx-auto mb-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M15 13l-3-3m0 0l-3 3m3-3v12"/></svg>
            <h3 class="text-white text-xl font-semibold mb-2">اسحب الملفات هنا أو انقر للتحديد</h3>
            <p class="text-white/70 mb-4">يدعم جميع أنواع الملفات حتى 100 ميجابايت</p>
            <button id="pick-files-inline" type="button" class="bg-white/20 text-white px-6 py-2 rounded-lg hover:bg-white/30">اختر الملفات</button>
          </form>
        </div>
        <?php endif; ?>
        <?php endif; ?>

        <div class="glass-effect rounded-xl p-4 lg:p-6 border border-white/20">
          <div class="flex items-center justify-between mb-4">
            <?php
              $title = 'الملفات الحديثة';
              if ($tab === 'all') $title = 'جميع الملفات';
              elseif ($tab === 'folders') $title = 'المجلدات';
              elseif ($tab === 'downloads') $title = 'الملفات';
              elseif ($tab === 'trash') $title = 'سلة المحذوفات';
              elseif ($tab === 'settings') $title = 'الإعدادات';
            ?>
            <h3 class="text-white text-lg lg:text-xl font-semibold"><?= $title ?></h3>
            <?php if ($tab==='dashboard'): ?><a class="text-white/80 hover:text-white text-sm" href="index.php?tab=all&amp;dir=<?= rawurlencode($dirRel) ?>">عرض الكل</a><?php endif; ?>
          </div>
          <?php if ($tab==='settings'): ?>
            <form method="post" action="index.php?action=update_account" class="max-w-md">
              <input type="hidden" name="csrf" value="<?= htmlspecialchars($_SESSION['csrf']) ?>">
              <label class="block text-white/90 mb-2">اسم المستخدم</label>
              <input name="username" value="<?= htmlspecialchars($CONFIG['username']) ?>" class="w-full mb-4 px-4 py-2 rounded bg-white/10 border border-white/20 text-white" />
              <label class="block text-white/90 mb-2">كلمة المرور</label>
              <input type="password" name="password" placeholder="اتركها فارغة دون تغيير" class="w-full mb-4 px-4 py-2 rounded bg-white/10 border border-white/20 text-white" />
              <button class="bg-white/20 text-white px-4 py-2 rounded-lg hover:bg-white/30">حفظ الإعدادات</button>
            </form>
          <?php else: ?>
          <?php
            if ($tab==='trash') {
                $filtered = $trashItems;
            } else {
                $filtered = $items;
                if ($tab==='folders') { $filtered = array_values(array_filter($items, fn($it) => $it['is_dir'])); }
                elseif ($tab==='downloads') { $filtered = array_values(array_filter($items, fn($it) => !$it['is_dir'])); }
            }
          ?>
          <?php if (empty($filtered)): ?>
            <div class="text-white/80">لا توجد عناصر</div>
          <?php else: ?>
          <?php $gridItems = ($tab==='dashboard') ? array_slice($filtered, 0, 3) : $filtered; ?>
          <div id="files-grid" class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4">
            <?php foreach ($gridItems as $it): $menuId = 'm_' . md5($it['name']); ?>
              <div class="file-card rounded-xl p-4 relative" data-name="<?= htmlspecialchars(mb_strtolower($it['name'])) ?>">
                <button class="absolute top-3 left-3 bg-gray-100 text-gray-700 rounded-md p-1 more-btn" data-menu="<?= $menuId ?>" aria-label="المزيد">
                  <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 20 20"><path d="M6 10a2 2 0 11-4 0 2 2 0 014 0zm6 0a2 2 0 11-4 0 2 2 0 014 0zm6 0a2 2 0 11-4 0 2 2 0 014 0z"/></svg>
                </button>
                <div id="<?= $menuId ?>" class="more-menu hidden absolute top-10 left-3 bg-white rounded-lg shadow-lg z-50 min-w-[180px] py-1">
                  <?php if ($it['is_dir']): ?>
                    <?php if ($tab==='trash'): ?>
                      <form method="post" action="index.php?action=restore" class="block">
                        <input type="hidden" name="csrf" value="<?= htmlspecialchars($_SESSION['csrf']) ?>">
                        <input type="hidden" name="name" value="<?= htmlspecialchars($it['name']) ?>">
                        <button class="w-full text-right px-3 py-2 hover:bg-gray-100" type="submit">استرجاع</button>
                      </form>
                    <?php else: ?>
                      <a class="block px-3 py-2 hover:bg-gray-100" href="index.php?tab=<?= htmlspecialchars($tab) ?>&amp;dir=<?= rawurlencode(trim($dirRel,'/')) . ($dirRel ? '%2F' : '') . rawurlencode($it['name']) ?>">فتح</a>
                      <button class="w-full text-right px-3 py-2 hover:bg-gray-100" onclick="renameItem('<?= htmlspecialchars($it['name']) ?>')">إعادة تسمية</button>
                      <button class="w-full text-right px-3 py-2 text-red-600 hover:bg-gray-100" onclick="deleteItem('<?= htmlspecialchars($it['name']) ?>')">حذف</button>
                    <?php endif; ?>
                  <?php else: ?>
                    <?php if ($tab==='trash'): ?>
                      <form method="post" action="index.php?action=restore" class="block">
                        <input type="hidden" name="csrf" value="<?= htmlspecialchars($_SESSION['csrf']) ?>">
                        <input type="hidden" name="name" value="<?= htmlspecialchars($it['name']) ?>">
                        <button class="w-full text-right px-3 py-2 hover:bg-gray-100" type="submit">استرجاع</button>
                      </form>
                    <?php else: ?>
                      <a class="block px-3 py-2 hover:bg-gray-100" target="_blank" href="index.php?action=view&amp;dir=<?= rawurlencode($dirRel) ?>&amp;file=<?= rawurlencode($it['name']) ?>">عرض</a>
                      <a class="block px-3 py-2 hover:bg-gray-100" href="index.php?action=download&amp;dir=<?= rawurlencode($dirRel) ?>&amp;file=<?= rawurlencode($it['name']) ?>">تحميل</a>
                      <?php if (is_code_file($it['name'])): ?>
                        <a class="block px-3 py-2 hover:bg-gray-100" href="index.php?action=edit&amp;tab=<?= htmlspecialchars($tab) ?>&amp;dir=<?= rawurlencode($dirRel) ?>&amp;file=<?= rawurlencode($it['name']) ?>">تعديل</a>
                      <?php endif; ?>
                      <button class="w-full text-right px-3 py-2" onclick="renameItem('<?= htmlspecialchars($it['name']) ?>')">إعادة تسمية</button>
                      <button class="w-full text-right px-3 py-2 text-red-600 hover:bg-gray-100" onclick="deleteItem('<?= htmlspecialchars($it['name']) ?>')">حذف</button>
                    <?php endif; ?>
                  <?php endif; ?>
                </div>
                <?php
                  $href = $it['is_dir']
                    ? 'index.php?tab=' . htmlspecialchars($tab) . '&dir=' . rawurlencode(trim($dirRel,'/')) . ($dirRel ? '%2F' : '') . rawurlencode($it['name'])
                    : 'index.php?action=preview&tab=' . htmlspecialchars($tab) . '&dir=' . rawurlencode($dirRel) . '&file=' . rawurlencode($it['name']);
                ?>
                <a class="flex items-center gap-3 pr-8 cursor-pointer" href="<?= $href ?>">
                  <?= file_icon_svg($it['name'], $it['is_dir']) ?>
                  <div class="min-w-0">
                    <div class="text-gray-800 font-semibold truncate" title="<?= htmlspecialchars($it['name']) ?>"><?= htmlspecialchars($it['name']) ?></div>
                    <div class="text-gray-500 text-sm mt-1">
                      <?= $it['is_dir'] ? 'مجلد' : human_size($it['size']) ?> • <?= date('Y-m-d H:i', $it['mtime']) ?>
                    </div>
                  </div>
                </a>
              </div>
            <?php endforeach; ?>
          </div>
          <?php endif; ?>
          <?php endif; ?>
        </div>
        <?php endif; ?>
        <?php endif; // end editor switch ?>
      </main>
    </div>
  </div>

<?php endif; ?>

<!-- Upload Modal -->
<div id="upload-modal" class="fixed inset-0 bg-black/50 backdrop-blur-sm hidden items-center justify-center z-50 p-4">
  <div class="bg-white rounded-xl p-8 max-w-2xl w-full">
    <div class="flex items-center justify-between mb-4">
      <h3 class="text-lg font-semibold">رفع الملفات</h3>
      <button id="close-upload" class="text-gray-500 hover:text-gray-700">إغلاق</button>
    </div>
      <form id="upload-form" method="post" action="index.php?action=upload&amp;tab=<?= htmlspecialchars($tab) ?>&amp;dir=<?= rawurlencode($dirRel) ?>" enctype="multipart/form-data">
      <input type="hidden" name="csrf" value="<?= htmlspecialchars($_SESSION['csrf']) ?>">
      <div class="upload-zone rounded-xl p-10 text-center border-2 border-dashed border-gray-300">
        <svg class="w-16 h-16 text-gray-500 mx-auto mb-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M15 13l-3-3m0 0l-3 3m3-3v12"/></svg>
        <h4 class="text-gray-800 font-medium mb-3">اسحب وأفلت الملفات هنا أو اخترها</h4>
        <input id="file-input" type="file" name="files[]" multiple class="hidden" />
        <button type="button" id="pick-files" class="mt-2 bg-gray-100 text-gray-800 px-5 py-2 rounded-lg hover:bg-gray-200">اختيار ملفات</button>
      </div>
    </form>
  </div>
  
</div>

<!-- Create Modal -->
<div id="create-modal" class="fixed inset-0 bg-black/50 backdrop-blur-sm hidden items-center justify-center z-50 p-4">
  <div class="bg-white rounded-xl p-8 max-w-md w-full">
    <div class="flex items-center justify-between mb-4">
      <h3 class="text-lg font-semibold">إنشاء عنصر</h3>
      <button id="close-create" class="text-gray-500 hover:text-gray-700">إغلاق</button>
    </div>
    <div class="space-y-4">
      <div class="grid grid-cols-2 gap-3">
        <button id="choose-file" class="border rounded-lg p-4 hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-indigo-500">ملف</button>
        <button id="choose-folder" class="border rounded-lg p-4 hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-indigo-500">مجلد</button>
      </div>
      <div>
        <label class="block text-gray-700 text-sm mb-2">الاسم</label>
        <input id="create-name" type="text" class="w-full border rounded-lg px-3 py-2" placeholder="اكتب اسم الملف أو المجلد" />
      </div>
      <div class="flex gap-2 justify-end">
        <button id="submit-create" class="bg-indigo-600 text-white px-5 py-2 rounded-lg hover:bg-indigo-700">إنشاء</button>
        <button id="cancel-create" class="bg-gray-100 text-gray-800 px-5 py-2 rounded-lg hover:bg-gray-200">إلغاء</button>
      </div>
    </div>
  </div>
</div>
<script>
  const sidebar = document.getElementById('sidebar');
  const overlay = document.getElementById('sidebar-overlay');
  const mobileBtn = document.getElementById('mobile-menu-btn');
  if (mobileBtn && sidebar && overlay) {
    mobileBtn.addEventListener('click', () => {
      sidebar.classList.remove('translate-x-full');
      sidebar.classList.add('translate-x-0');
      overlay.classList.remove('hidden');
      document.body.style.overflow = 'hidden';
    });
    overlay.addEventListener('click', () => {
      sidebar.classList.add('translate-x-full');
      sidebar.classList.remove('translate-x-0');
      overlay.classList.add('hidden');
      document.body.style.overflow = '';
    });
  }

  const uploadZone = document.querySelector('.upload-zone');
  // Toast notifications
  function showToast(message, type = 'success') {
    const t = document.createElement('div');
    t.className = `fixed top-4 right-4 z-50 px-4 py-3 rounded-lg shadow-lg transform translate-x-full transition-transform duration-300 fade-in-up ${
      type === 'success' ? 'bg-green-500 text-white' : type === 'error' ? 'bg-red-500 text-white' : 'bg-blue-500 text-white'
    }`;
    t.innerHTML = `<div class="flex items-center gap-2"><span>${message}</span></div>`;
    document.body.appendChild(t);
    setTimeout(() => { t.classList.remove('translate-x-full'); }, 50);
    setTimeout(() => { t.classList.add('translate-x-full'); setTimeout(() => t.remove(), 300); }, 2800);
  }
  if (window.__FLASH__) { showToast(window.__FLASH__.msg, window.__FLASH__.type); }
  // Inline upload zone
  const uploadInline = document.getElementById('upload-inline');
  const fileInputInline = document.getElementById('file-input-inline');
  const pickFilesInline = document.getElementById('pick-files-inline');
  if (pickFilesInline && fileInputInline) pickFilesInline.addEventListener('click', () => fileInputInline.click());
  function autoSubmitInline(){ if (uploadInline && fileInputInline && fileInputInline.files.length) uploadInline.submit(); }
  if (fileInputInline) fileInputInline.addEventListener('change', autoSubmitInline);
  if (uploadInline) {
    ['dragenter','dragover'].forEach(evt => uploadInline.addEventListener(evt, e => { e.preventDefault(); uploadInline.classList.add('dragover'); }));
    ['dragleave','drop'].forEach(evt => uploadInline.addEventListener(evt, e => { e.preventDefault(); uploadInline.classList.remove('dragover'); }));
    uploadInline.addEventListener('drop', e => { fileInputInline.files = e.dataTransfer.files; autoSubmitInline(); });
  }
  // Upload modal
  const uploadModal = document.getElementById('upload-modal');
  const openUpload = null; // removed from header
  const openUploadActions = document.getElementById('open-upload-actions');
  const closeUpload = document.getElementById('close-upload');
  const uploadForm = document.getElementById('upload-form');
  const fileInput = document.getElementById('file-input');
  const pickBtn = document.getElementById('pick-files');

  function openUploadModal() {
    if (!uploadModal) return;
    uploadModal.classList.remove('hidden');
    uploadModal.classList.add('flex');
    document.body.style.overflow = 'hidden';
  }
  if (openUploadActions) openUploadActions.addEventListener('click', openUploadModal);
  const openUploadActionsM = document.getElementById('open-upload-actions-m');
  if (openUploadActionsM) openUploadActionsM.addEventListener('click', openUploadModal);
  if (closeUpload && uploadModal) {
    closeUpload.addEventListener('click', () => {
      uploadModal.classList.add('hidden');
      uploadModal.classList.remove('flex');
      document.body.style.overflow = '';
    });
  }
  function autoSubmit() { if (uploadForm && fileInput && fileInput.files.length) uploadForm.submit(); }
  if (pickBtn && fileInput) pickBtn.addEventListener('click', () => fileInput.click());
  if (fileInput) fileInput.addEventListener('change', autoSubmit);
  if (uploadZone && fileInput) {
    ['dragenter','dragover'].forEach(evt => uploadZone.addEventListener(evt, e => { e.preventDefault(); uploadZone.classList.add('dragover'); }));
    ['dragleave','drop'].forEach(evt => uploadZone.addEventListener(evt, e => { e.preventDefault(); uploadZone.classList.remove('dragover'); }));
    uploadZone.addEventListener('drop', e => { fileInput.files = e.dataTransfer.files; autoSubmit(); });
  }

  const searchInput = document.getElementById('search-input');
  const grid = document.getElementById('files-grid');
  if (searchInput && grid) {
    searchInput.addEventListener('input', () => {
      const q = searchInput.value.trim().toLowerCase();
      grid.querySelectorAll('[data-name]').forEach(row => {
        const name = row.getAttribute('data-name') || '';
        row.style.display = name.includes(q) ? '' : 'none';
      });
    });
  }

  // 3-dots menus on cards
  document.addEventListener('click', (e) => {
    const btn = e.target.closest('.more-btn');
    document.querySelectorAll('.more-menu').forEach(m => m.classList.add('hidden'));
    document.querySelectorAll('.file-card.menu-open').forEach(c => c.classList.remove('menu-open'));

    if (btn) {
      const id = btn.getAttribute('data-menu');
      const menu = id && document.getElementById(id);
      if (menu) {
        menu.classList.toggle('hidden');
        const card = btn.closest('.file-card');
        if (card) card.classList.add('menu-open');
        e.stopPropagation();
      }
    }
  });

  // Rename and delete helpers
  function getDir() {
    const params = new URLSearchParams(window.location.search);
    return params.get('dir') || '';
  }
  function getTab() {
    const params = new URLSearchParams(window.location.search);
    return params.get('tab') || 'dashboard';
  }
  window.renameItem = function(oldName) {
    const newName = prompt('ادخل الاسم الجديد:', oldName);
    if (!newName || newName === oldName) return;
    const form = document.createElement('form');
    form.method = 'POST';
    form.action = 'index.php?action=rename&tab=' + encodeURIComponent(getTab()) + '&dir=' + encodeURIComponent(getDir());
    form.innerHTML = `
      <input type="hidden" name="csrf" value="<?= htmlspecialchars($_SESSION['csrf']) ?>">
      <input type="hidden" name="old" value="${oldName.replaceAll('"','&quot;')}">
      <input type="hidden" name="new" value="${newName.replaceAll('"','&quot;')}">
    `;
    document.body.appendChild(form); form.submit();
  }
  window.deleteItem = function(name) {
    if (!confirm('هل تريد الحذف؟')) return;
    const form = document.createElement('form');
    form.method = 'POST';
    form.action = 'index.php?action=delete&tab=' + encodeURIComponent(getTab()) + '&dir=' + encodeURIComponent(getDir());
    form.innerHTML = `
      <input type="hidden" name="csrf" value="<?= htmlspecialchars($_SESSION['csrf']) ?>">
      <input type="hidden" name="name" value="${name.replaceAll('"','&quot;')}">
    `;
    document.body.appendChild(form); form.submit();
  }
  // Create menu handling
  // Create modal logic
  const createModal = document.getElementById('create-modal');
  const openCreate = document.getElementById('open-create');
  const openCreateM = document.getElementById('open-create-m');
  const closeCreate = document.getElementById('close-create');
  const cancelCreate = document.getElementById('cancel-create');
  const submitCreate = document.getElementById('submit-create');
  const chooseFile = document.getElementById('choose-file');
  const chooseFolder = document.getElementById('choose-folder');
  const createName = document.getElementById('create-name');
  let createKind = 'file';

  function openCreateModal() {
    if (!createModal) return;
    createModal.classList.remove('hidden');
    createModal.classList.add('flex');
    document.body.style.overflow = 'hidden';
    createName && (createName.value = '');
    createKind = 'file';
    chooseFile && chooseFile.classList.add('ring','ring-indigo-500');
    chooseFolder && chooseFolder.classList.remove('ring','ring-indigo-500');
  }
  function closeCreateModal() {
    if (!createModal) return;
    createModal.classList.add('hidden');
    createModal.classList.remove('flex');
    document.body.style.overflow = '';
  }
  if (openCreate) openCreate.addEventListener('click', openCreateModal);
  if (openCreateM) openCreateM.addEventListener('click', openCreateModal);
  if (closeCreate) closeCreate.addEventListener('click', closeCreateModal);
  if (cancelCreate) cancelCreate.addEventListener('click', (e) => { e.preventDefault(); closeCreateModal(); });
  if (chooseFile) chooseFile.addEventListener('click', (e) => { e.preventDefault(); createKind='file'; chooseFile.classList.add('ring','ring-indigo-500'); chooseFolder.classList.remove('ring','ring-indigo-500'); });
  if (chooseFolder) chooseFolder.addEventListener('click', (e) => { e.preventDefault(); createKind='folder'; chooseFolder.classList.add('ring','ring-indigo-500'); chooseFile.classList.remove('ring','ring-indigo-500'); });
  if (submitCreate) submitCreate.addEventListener('click', (e) => {
    e.preventDefault();
    const name = (createName && createName.value.trim()) || '';
    if (!name) { createName && createName.focus(); return; }
    const form = document.createElement('form');
    form.method = 'POST';
    form.action = 'index.php?action=' + (createKind === 'folder' ? 'create_folder' : 'create_file') + '&tab=' + encodeURIComponent(getTab()) + '&dir=' + encodeURIComponent(getDir());
    form.innerHTML = `
      <input type="hidden" name="csrf" value="<?= htmlspecialchars($_SESSION['csrf']) ?>">
      <input type="hidden" name="name" value="${name.replaceAll('"','&quot;')}">
    `;
    document.body.appendChild(form); form.submit();
  });
</script>
</body>
</html>
