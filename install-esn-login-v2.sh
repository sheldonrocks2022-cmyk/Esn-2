#!/usr/bin/env bash
set -Eeuo pipefail
cd /var/www/pterodactyl
test -f public/esn-theme/theme.css || { echo "Install theme v1 first"; exit 1; }
mkdir -p /var/backups/esn-theme
cp public/esn-theme/theme.css "/var/backups/esn-theme/theme-$(date +%Y%m%d-%H%M%S).css"
cat >> public/esn-theme/theme.css <<'CSS'

/* ESN Hosting v2: login page visual refresh only */
body:has(input[type="password"]) #app {
  background:radial-gradient(ellipse at 50% 0%,rgba(46,114,225,.24),transparent 55%),linear-gradient(155deg,#080d1c,#0b1630 58%,#080e1c) !important;
}
body:has(input[type="password"]) #app h1,
body:has(input[type="password"]) #app h2 {
  letter-spacing:-.035em;
  font-weight:800;
}
body:has(input[type="password"]) #app form {
  background:#111d33 !important;
  color:#e9f0ff !important;
  border:1px solid rgba(115,160,240,.2);
  border-radius:22px !important;
  box-shadow:0 24px 80px rgba(0,0,0,.35) !important;
}
body:has(input[type="password"]) #app form input {
  background:#0b1528 !important;
  color:#f5f8ff !important;
  border:1px solid #344762 !important;
  border-radius:12px !important;
  min-height:50px;
}
body:has(input[type="password"]) #app form input:focus {
  outline:2px solid #54a7ff !important;
  outline-offset:1px;
}
body:has(input[type="password"]) #app form label { color:#c5d6f0 !important; }
body:has(input[type="password"]) #app form button,
body:has(input[type="password"]) #app form a[class*="bg-"] {
  border-radius:12px !important;
  font-weight:700;
}
body:has(input[type="password"]) #app form img {
  max-height:125px !important;
  object-fit:contain;
}
@media(max-width:600px) {
  body:has(input[type="password"]) #app form { margin-inline:10px; padding:22px !important; }
}
CSS
php artisan view:clear
echo "ESN Hosting login theme v2 CSS installed; original login and OAuth logic unchanged."
