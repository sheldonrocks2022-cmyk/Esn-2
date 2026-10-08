#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=/var/www/pterodactyl
cd "$ROOT"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="$ROOT/.esn-theme-backup-$STAMP"
mkdir -p "$BACKUP"
TARGET=""
for f in resources/views/templates/wrapper.blade.php resources/views/layouts/app.blade.php; do
  if [ -f "$f" ] && grep -q '</head>' "$f"; then TARGET="$f"; break; fi
done
if [ -z "$TARGET" ]; then
  echo "No compatible Pterodactyl Blade HTML head found; nothing changed."
  exit 1
fi
cp -a "$TARGET" "$BACKUP/$(basename "$TARGET")"
mkdir -p public/esn-theme
if [ -f public/esn-theme/theme.css ]; then cp -a public/esn-theme/theme.css "$BACKUP/theme.css"; fi
cat > public/esn-theme/theme.css <<'CSS'
/* ESN Hosting: reversible cosmetic layer. Does not change auth, routes or APIs. */
:root { color-scheme:dark; }
body { background:#090e1c !important; }
#app { background:linear-gradient(145deg,#0a1022,#101b32 58%,#090e1c) !important; min-height:100vh; }
#app [class*="bg-neutral-900"],#app [class*="bg-gray-800"],#app [class*="bg-neutral-800"] { background-color:#121d32 !important; }
#app [class*="rounded"],#app button,#app input { border-radius:12px; }
#app button { transition:filter .18s ease,transform .18s ease; }
#app button:hover { filter:brightness(1.12); }
#app [class*="shadow"] { box-shadow:0 8px 26px rgba(0,0,0,.18); }
#app a:focus-visible,#app button:focus-visible { outline:2px solid #38bdf8;outline-offset:2px; }
@media(max-width:768px){#app {overflow-x:hidden;}#app button {min-height:36px;}}
@media(prefers-reduced-motion:reduce){#app *{transition:none !important;animation:none !important;}}
CSS
if ! grep -q '/esn-theme/theme.css' "$TARGET"; then
  export ESN_TARGET="$TARGET"
  python3 - <<'PY'
import os
p=os.environ['ESN_TARGET']
s=open(p).read()
s=s.replace('</head>', '<link rel="stylesheet" href="/esn-theme/theme.css?v=1">\n</head>', 1)
open(p,'w').write(s)
PY
fi
php artisan view:clear
echo "ESN theme installed. Backup: $BACKUP"
echo "Rollback: restore the backed-up Blade file and remove public/esn-theme/theme.css, then run php artisan view:clear."
