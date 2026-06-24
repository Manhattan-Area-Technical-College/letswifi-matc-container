<?php
if (($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https') {
    $_SERVER['HTTPS'] = 'on';
    $_SERVER['SERVER_PORT'] = '443';
    // Drop any :port the proxy left on the Host header so it can't leak into URLs.
    if (isset($_SERVER['HTTP_HOST'])) {
        $_SERVER['HTTP_HOST'] = preg_replace('/:\d+$/', '', $_SERVER['HTTP_HOST']);
    }
}
