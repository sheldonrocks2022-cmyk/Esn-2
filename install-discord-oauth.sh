#!/usr/bin/env bash
set -euo pipefail

PANEL_DIR="/var/www/pterodactyl"
DISCORD_CLIENT_ID="${DISCORD_CLIENT_ID:-1544503232674664573}"
DISCORD_REDIRECT_URI="${DISCORD_REDIRECT_URI:-https://panel.esnoffical.com/auth/oauth/discord/callback}"

if [[ ${EUID} -ne 0 ]]; then
  echo "ERROR: Run this installer as root."
  exit 1
fi

if [[ ! -f "$PANEL_DIR/artisan" || ! -f "$PANEL_DIR/.env" ]]; then
  echo "ERROR: Pterodactyl was not found at $PANEL_DIR."
  exit 1
fi

if [[ -z "${DISCORD_CLIENT_SECRET:-}" ]]; then
  # Reuse the secret already stored on the VPS from the earlier OAuth setup.
  DISCORD_CLIENT_SECRET="$(grep -m1 '^DISCORD_CLIENT_SECRET=' "$PANEL_DIR/.env" | cut -d= -f2- || true)"
  DISCORD_CLIENT_SECRET="${DISCORD_CLIENT_SECRET%
cd "$PANEL_DIR"

STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="/root/esn-panel-backups/discord-oauth-$STAMP"
mkdir -p "$BACKUP"
chmod 700 /root/esn-panel-backups "$BACKUP"

for f in .env composer.json composer.lock config/services.php routes/auth.php app/Providers/AppServiceProvider.php resources/scripts/components/auth/LoginContainer.tsx; do
  [[ -e "$f" ]] && cp -a "$f" "$BACKUP/"
done
if command -v mariadb-dump >/dev/null 2>&1; then
  mariadb-dump --single-transaction panel | gzip > "$BACKUP/panel.sql.gz" || true
fi
chmod -R go-rwx "$BACKUP"

echo "[1/8] Installing Discord OAuth dependencies..."
COMPOSER_ALLOW_SUPERUSER=1 composer require laravel/socialite socialiteproviders/discord --no-interaction --update-with-all-dependencies

echo "[2/8] Writing Discord OAuth environment values..."
export DISCORD_CLIENT_ID DISCORD_CLIENT_SECRET DISCORD_REDIRECT_URI
python3 <<'PY'
from pathlib import Path
import os

path = Path("/var/www/pterodactyl/.env")
lines = path.read_text().splitlines()

values = {
    "DISCORD_CLIENT_ID": os.environ["DISCORD_CLIENT_ID"],
    "DISCORD_CLIENT_SECRET": os.environ["DISCORD_CLIENT_SECRET"],
    "DISCORD_REDIRECT_URI": os.environ["DISCORD_REDIRECT_URI"],
}

def quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

out = []
seen = set()
for line in lines:
    replaced = False
    for key, value in values.items():
        if line.startswith(key + "="):
            out.append(f"{key}={quote(value)}")
            seen.add(key)
            replaced = True
            break
    if not replaced:
        out.append(line)

if not all(k in seen for k in values):
    out.extend(["", "# ESN Discord OAuth"])
    for key, value in values.items():
        if key not in seen:
            out.append(f"{key}={quote(value)}")

path.write_text("\n".join(out) + "\n")
PY

echo "[3/8] Configuring Laravel Socialite..."
python3 <<'PY'
from pathlib import Path

p = Path("/var/www/pterodactyl/config/services.php")
s = p.read_text()

if "'discord' => [" not in s:
    block = """
    'discord' => [
        'client_id' => env('DISCORD_CLIENT_ID'),
        'client_secret' => env('DISCORD_CLIENT_SECRET'),
        'redirect' => env('DISCORD_REDIRECT_URI'),
    ],

"""
    pos = s.rfind("];")
    if pos < 0:
        raise SystemExit("Could not patch config/services.php")
    s = s[:pos] + block + s[pos:]
    p.write_text(s)
PY

echo "[4/8] Registering the Discord Socialite provider..."
python3 <<'PY'
from pathlib import Path

p = Path("/var/www/pterodactyl/app/Providers/AppServiceProvider.php")
s = p.read_text()

needle = "    public function boot(): void\n    {\n"
replacement = """    public function boot(): void
    {
        // ESN Discord OAuth provider.
        \\Illuminate\\Support\\Facades\\Event::listen(function (\\SocialiteProviders\\Manager\\SocialiteWasCalled $event): void {
            $event->extendSocialite('discord', \\SocialiteProviders\\Discord\\Provider::class);
        });

"""

if "extendSocialite('discord'" not in s:
    if needle not in s:
        raise SystemExit("Could not patch AppServiceProvider.php")
    s = s.replace(needle, replacement, 1)
    p.write_text(s)
PY

echo "[5/8] Creating the Discord OAuth controller..."
cat > app/Http/Controllers/Auth/OAuthController.php <<'PHP'
<?php

namespace Pterodactyl\Http\Controllers\Auth;

use Throwable;
use Illuminate\Support\Str;
use Illuminate\Http\RedirectResponse;
use Illuminate\Support\Facades\Auth;
use Laravel\Socialite\Facades\Socialite;
use Pterodactyl\Models\User;
use Pterodactyl\Http\Controllers\Controller;
use Pterodactyl\Services\Users\UserCreationService;

class OAuthController extends Controller
{
    public function redirect(): RedirectResponse
    {
        return Socialite::driver('discord')
            ->scopes(['identify', 'email'])
            ->redirect();
    }

    public function callback(UserCreationService $creationService): RedirectResponse
    {
        try {
            $oauth = Socialite::driver('discord')->user();
        } catch (Throwable $exception) {
            report($exception);

            return redirect('/auth/login?oauth=discord-failed');
        }

        $raw = is_array($oauth->user ?? null) ? $oauth->user : [];
        $email = Str::lower(trim((string) $oauth->getEmail()));
        $verified = (bool) ($raw['verified'] ?? false);

        if ($email === '' || !$verified) {
            return redirect('/auth/login?oauth=verified-email-required');
        }

        $user = User::query()
            ->whereRaw('LOWER(email) = ?', [$email])
            ->first();

        // Never let social login bypass the stronger login path for root admins.
        if ($user && $user->root_admin) {
            return redirect('/auth/login?oauth=admin-password-required');
        }

        if (!$user) {
            $base = 'discord_' . Str::lower(Str::random(10));
            $username = $base;

            while (User::query()->where('username', $username)->exists()) {
                $username = 'discord_' . Str::lower(Str::random(12));
            }

            $display = trim((string) ($oauth->getName() ?: $oauth->getNickname() ?: 'Discord User'));
            $parts = preg_split('/\s+/', $display, 2);

            $first = mb_substr(trim((string) ($parts[0] ?? 'Discord')), 0, 191);
            $last = mb_substr(trim((string) ($parts[1] ?? 'User')), 0, 191);

            if ($first === '') {
                $first = 'Discord';
            }

            if ($last === '') {
                $last = 'User';
            }

            try {
                $user = $creationService->handle([
                    'email' => $email,
                    'username' => $username,
                    'name_first' => $first,
                    'name_last' => $last,
                    'password' => Str::random(64),
                    'root_admin' => false,
                ]);
            } catch (Throwable $exception) {
                // Account creation can commit successfully before a mail transport error.
                $user = User::query()
                    ->whereRaw('LOWER(email) = ?', [$email])
                    ->first();

                if (!$user) {
                    throw $exception;
                }
            }
        }

        Auth::guard()->login($user, true);
        request()->session()->regenerate();

        return redirect('/');
    }
}
PHP

echo "[6/8] Adding Discord OAuth routes..."
python3 <<'PY'
from pathlib import Path

p = Path("/var/www/pterodactyl/routes/auth.php")
s = p.read_text()

block = """
// ESN Discord OAuth.
Route::get('/oauth/discord', [Auth\\OAuthController::class, 'redirect'])
    ->name('auth.oauth.discord');

Route::get('/oauth/discord/callback', [Auth\\OAuthController::class, 'callback'])
    ->name('auth.oauth.discord.callback');

"""

if "auth.oauth.discord.callback" not in s:
    marker = "// Catch any other combinations of routes and pass them off to the React component."
    pos = s.find(marker)
    if pos < 0:
        raise SystemExit("Could not find auth route fallback marker.")
    s = s[:pos] + block + s[pos:]
    p.write_text(s)
PY

echo "[7/8] Adding the Discord button to the login screen..."
python3 <<'PY'
from pathlib import Path

p = Path("/var/www/pterodactyl/resources/scripts/components/auth/LoginContainer.tsx")
s = p.read_text()

if "/auth/oauth/discord" not in s:
    block = r"""
                    <div css={tw`mt-4`}>
                        <a
                            href={'/auth/oauth/discord'}
                            css={tw`block w-full text-center py-3 px-4 rounded bg-indigo-600 hover:bg-indigo-500 text-white font-semibold no-underline transition-colors duration-150`}
                        >
                            Continue with Discord
                        </a>
                    </div>
"""
    marker = "                    {recaptchaEnabled && ("
    pos = s.find(marker)
    if pos < 0:
        raise SystemExit("Could not find login form insertion point.")
    s = s[:pos] + block + s[pos:]
    p.write_text(s)
PY

echo "[8/8] Building and restarting Pterodactyl..."
yarn build:production

chown -R www-data:www-data "$PANEL_DIR"
chmod -R 755 storage bootstrap/cache

php artisan optimize:clear
systemctl restart php8.3-fpm
systemctl restart pteroq.service || true
systemctl reload nginx

unset DISCORD_CLIENT_SECRET

echo
echo "==============================================="
echo " ESN DISCORD LOGIN INSTALL COMPLETE"
echo "==============================================="
php artisan route:list --path=auth/oauth/discord || true
echo
echo "Login page: https://panel.esnoffical.com/auth/login"
echo "Backup: $BACKUP"
echo
echo "IMPORTANT: The Discord app must have this exact redirect:"
echo "https://panel.esnoffical.com/auth/oauth/discord/callback"
\\r'}"
  if [[ "$DISCORD_CLIENT_SECRET" == \"*\" && "$DISCORD_CLIENT_SECRET" == *\" ]]; then
    DISCORD_CLIENT_SECRET="${DISCORD_CLIENT_SECRET:1:${#DISCORD_CLIENT_SECRET}-2}"
  fi
fi

if [[ -z "${DISCORD_CLIENT_SECRET:-}" ]]; then
  echo "ERROR: No Discord client secret was found in the existing Pterodactyl .env."
  exit 1
fi

cd "$PANEL_DIR"

STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="/root/esn-panel-backups/discord-oauth-$STAMP"
mkdir -p "$BACKUP"
chmod 700 /root/esn-panel-backups "$BACKUP"

for f in .env composer.json composer.lock config/services.php routes/auth.php app/Providers/AppServiceProvider.php resources/scripts/components/auth/LoginContainer.tsx; do
  [[ -e "$f" ]] && cp -a "$f" "$BACKUP/"
done
if command -v mariadb-dump >/dev/null 2>&1; then
  mariadb-dump --single-transaction panel | gzip > "$BACKUP/panel.sql.gz" || true
fi
chmod -R go-rwx "$BACKUP"

echo "[1/8] Installing Discord OAuth dependencies..."
COMPOSER_ALLOW_SUPERUSER=1 composer require laravel/socialite socialiteproviders/discord --no-interaction --update-with-all-dependencies

echo "[2/8] Writing Discord OAuth environment values..."
export DISCORD_CLIENT_ID DISCORD_CLIENT_SECRET DISCORD_REDIRECT_URI
python3 <<'PY'
from pathlib import Path
import os

path = Path("/var/www/pterodactyl/.env")
lines = path.read_text().splitlines()

values = {
    "DISCORD_CLIENT_ID": os.environ["DISCORD_CLIENT_ID"],
    "DISCORD_CLIENT_SECRET": os.environ["DISCORD_CLIENT_SECRET"],
    "DISCORD_REDIRECT_URI": os.environ["DISCORD_REDIRECT_URI"],
}

def quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

out = []
seen = set()
for line in lines:
    replaced = False
    for key, value in values.items():
        if line.startswith(key + "="):
            out.append(f"{key}={quote(value)}")
            seen.add(key)
            replaced = True
            break
    if not replaced:
        out.append(line)

if not all(k in seen for k in values):
    out.extend(["", "# ESN Discord OAuth"])
    for key, value in values.items():
        if key not in seen:
            out.append(f"{key}={quote(value)}")

path.write_text("\n".join(out) + "\n")
PY

echo "[3/8] Configuring Laravel Socialite..."
python3 <<'PY'
from pathlib import Path

p = Path("/var/www/pterodactyl/config/services.php")
s = p.read_text()

if "'discord' => [" not in s:
    block = """
    'discord' => [
        'client_id' => env('DISCORD_CLIENT_ID'),
        'client_secret' => env('DISCORD_CLIENT_SECRET'),
        'redirect' => env('DISCORD_REDIRECT_URI'),
    ],

"""
    pos = s.rfind("];")
    if pos < 0:
        raise SystemExit("Could not patch config/services.php")
    s = s[:pos] + block + s[pos:]
    p.write_text(s)
PY

echo "[4/8] Registering the Discord Socialite provider..."
python3 <<'PY'
from pathlib import Path

p = Path("/var/www/pterodactyl/app/Providers/AppServiceProvider.php")
s = p.read_text()

needle = "    public function boot(): void\n    {\n"
replacement = """    public function boot(): void
    {
        // ESN Discord OAuth provider.
        \\Illuminate\\Support\\Facades\\Event::listen(function (\\SocialiteProviders\\Manager\\SocialiteWasCalled $event): void {
            $event->extendSocialite('discord', \\SocialiteProviders\\Discord\\Provider::class);
        });

"""

if "extendSocialite('discord'" not in s:
    if needle not in s:
        raise SystemExit("Could not patch AppServiceProvider.php")
    s = s.replace(needle, replacement, 1)
    p.write_text(s)
PY

echo "[5/8] Creating the Discord OAuth controller..."
cat > app/Http/Controllers/Auth/OAuthController.php <<'PHP'
<?php

namespace Pterodactyl\Http\Controllers\Auth;

use Throwable;
use Illuminate\Support\Str;
use Illuminate\Http\RedirectResponse;
use Illuminate\Support\Facades\Auth;
use Laravel\Socialite\Facades\Socialite;
use Pterodactyl\Models\User;
use Pterodactyl\Http\Controllers\Controller;
use Pterodactyl\Services\Users\UserCreationService;

class OAuthController extends Controller
{
    public function redirect(): RedirectResponse
    {
        return Socialite::driver('discord')
            ->scopes(['identify', 'email'])
            ->redirect();
    }

    public function callback(UserCreationService $creationService): RedirectResponse
    {
        try {
            $oauth = Socialite::driver('discord')->user();
        } catch (Throwable $exception) {
            report($exception);

            return redirect('/auth/login?oauth=discord-failed');
        }

        $raw = is_array($oauth->user ?? null) ? $oauth->user : [];
        $email = Str::lower(trim((string) $oauth->getEmail()));
        $verified = (bool) ($raw['verified'] ?? false);

        if ($email === '' || !$verified) {
            return redirect('/auth/login?oauth=verified-email-required');
        }

        $user = User::query()
            ->whereRaw('LOWER(email) = ?', [$email])
            ->first();

        // Never let social login bypass the stronger login path for root admins.
        if ($user && $user->root_admin) {
            return redirect('/auth/login?oauth=admin-password-required');
        }

        if (!$user) {
            $base = 'discord_' . Str::lower(Str::random(10));
            $username = $base;

            while (User::query()->where('username', $username)->exists()) {
                $username = 'discord_' . Str::lower(Str::random(12));
            }

            $display = trim((string) ($oauth->getName() ?: $oauth->getNickname() ?: 'Discord User'));
            $parts = preg_split('/\s+/', $display, 2);

            $first = mb_substr(trim((string) ($parts[0] ?? 'Discord')), 0, 191);
            $last = mb_substr(trim((string) ($parts[1] ?? 'User')), 0, 191);

            if ($first === '') {
                $first = 'Discord';
            }

            if ($last === '') {
                $last = 'User';
            }

            try {
                $user = $creationService->handle([
                    'email' => $email,
                    'username' => $username,
                    'name_first' => $first,
                    'name_last' => $last,
                    'password' => Str::random(64),
                    'root_admin' => false,
                ]);
            } catch (Throwable $exception) {
                // Account creation can commit successfully before a mail transport error.
                $user = User::query()
                    ->whereRaw('LOWER(email) = ?', [$email])
                    ->first();

                if (!$user) {
                    throw $exception;
                }
            }
        }

        Auth::guard()->login($user, true);
        request()->session()->regenerate();

        return redirect('/');
    }
}
PHP

echo "[6/8] Adding Discord OAuth routes..."
python3 <<'PY'
from pathlib import Path

p = Path("/var/www/pterodactyl/routes/auth.php")
s = p.read_text()

block = """
// ESN Discord OAuth.
Route::get('/oauth/discord', [Auth\\OAuthController::class, 'redirect'])
    ->name('auth.oauth.discord');

Route::get('/oauth/discord/callback', [Auth\\OAuthController::class, 'callback'])
    ->name('auth.oauth.discord.callback');

"""

if "auth.oauth.discord.callback" not in s:
    marker = "// Catch any other combinations of routes and pass them off to the React component."
    pos = s.find(marker)
    if pos < 0:
        raise SystemExit("Could not find auth route fallback marker.")
    s = s[:pos] + block + s[pos:]
    p.write_text(s)
PY

echo "[7/8] Adding the Discord button to the login screen..."
python3 <<'PY'
from pathlib import Path

p = Path("/var/www/pterodactyl/resources/scripts/components/auth/LoginContainer.tsx")
s = p.read_text()

if "/auth/oauth/discord" not in s:
    block = r"""
                    <div css={tw`mt-4`}>
                        <a
                            href={'/auth/oauth/discord'}
                            css={tw`block w-full text-center py-3 px-4 rounded bg-indigo-600 hover:bg-indigo-500 text-white font-semibold no-underline transition-colors duration-150`}
                        >
                            Continue with Discord
                        </a>
                    </div>
"""
    marker = "                    {recaptchaEnabled && ("
    pos = s.find(marker)
    if pos < 0:
        raise SystemExit("Could not find login form insertion point.")
    s = s[:pos] + block + s[pos:]
    p.write_text(s)
PY

echo "[8/8] Building and restarting Pterodactyl..."
yarn build:production

chown -R www-data:www-data "$PANEL_DIR"
chmod -R 755 storage bootstrap/cache

php artisan optimize:clear
systemctl restart php8.3-fpm
systemctl restart pteroq.service || true
systemctl reload nginx

unset DISCORD_CLIENT_SECRET

echo
echo "==============================================="
echo " ESN DISCORD LOGIN INSTALL COMPLETE"
echo "==============================================="
php artisan route:list --path=auth/oauth/discord || true
echo
echo "Login page: https://panel.esnoffical.com/auth/login"
echo "Backup: $BACKUP"
echo
echo "IMPORTANT: The Discord app must have this exact redirect:"
echo "https://panel.esnoffical.com/auth/oauth/discord/callback"
