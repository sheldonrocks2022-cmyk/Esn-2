#!/usr/bin/env bash
set -euo pipefail

PANEL_DIR="/var/www/pterodactyl"
DISCORD_CLIENT_ID_DEFAULT="1544503232674664573"
DISCORD_REDIRECT_URI_DEFAULT="https://panel.esnoffical.com/auth/oauth/discord/callback"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ ${EUID} -eq 0 ]] || fail "Run this installer as root."
[[ -f "$PANEL_DIR/artisan" ]] || fail "Pterodactyl artisan not found at $PANEL_DIR."
[[ -f "$PANEL_DIR/.env" ]] || fail "Pterodactyl .env not found at $PANEL_DIR."

cd "$PANEL_DIR"

get_env_value() {
  local key="$1"
  local value
  value="$(grep -m1 "^${key}=" .env | cut -d= -f2- || true)"
  value="${value#\"}"
  value="${value%\"}"
  value="${value#\'}"
  value="${value%\'}"
  printf '%s' "$value"
}

DISCORD_CLIENT_ID="$(get_env_value DISCORD_CLIENT_ID)"
DISCORD_CLIENT_SECRET="$(get_env_value DISCORD_CLIENT_SECRET)"
DISCORD_REDIRECT_URI="$(get_env_value DISCORD_REDIRECT_URI)"

[[ -n "$DISCORD_CLIENT_ID" ]] || DISCORD_CLIENT_ID="$DISCORD_CLIENT_ID_DEFAULT"
[[ -n "$DISCORD_REDIRECT_URI" ]] || DISCORD_REDIRECT_URI="$DISCORD_REDIRECT_URI_DEFAULT"
[[ -n "$DISCORD_CLIENT_SECRET" ]] || fail "No DISCORD_CLIENT_SECRET is stored in the existing .env."

STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="/root/esn-panel-backups/discord-oauth-v2-$STAMP"
mkdir -p "$BACKUP"
chmod 700 /root/esn-panel-backups "$BACKUP"

for f in .env composer.json composer.lock config/services.php routes/auth.php app/Providers/AppServiceProvider.php resources/scripts/components/auth/LoginContainer.tsx; do
  if [[ -e "$f" ]]; then
    cp -a "$f" "$BACKUP/"
  fi
done

if command -v mariadb-dump >/dev/null 2>&1; then
  mariadb-dump --single-transaction panel | gzip > "$BACKUP/panel.sql.gz" || true
fi
chmod -R go-rwx "$BACKUP"

echo "[1/8] Checking Discord OAuth dependencies..."
if ! composer show laravel/socialite >/dev/null 2>&1 || ! composer show socialiteproviders/discord >/dev/null 2>&1; then
  COMPOSER_ALLOW_SUPERUSER=1 composer require laravel/socialite socialiteproviders/discord --no-interaction --update-with-all-dependencies
else
  echo "OAuth packages already installed."
fi

echo "[2/8] Normalizing Discord OAuth values in .env..."
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

def q(v: str) -> str:
    return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'

out = []
seen = set()
for line in lines:
    matched = False
    for key, value in values.items():
        if line.startswith(key + "="):
            out.append(f"{key}={q(value)}")
            seen.add(key)
            matched = True
            break
    if not matched:
        out.append(line)

for key, value in values.items():
    if key not in seen:
        out.append(f"{key}={q(value)}")

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

echo "[4/8] Registering the Discord provider..."
python3 <<'PY'
from pathlib import Path

p = Path("/var/www/pterodactyl/app/Providers/AppServiceProvider.php")
s = p.read_text()

if "extendSocialite('discord'" not in s:
    needle = "    public function boot(): void\n    {\n"
    replacement = """    public function boot(): void
    {
        // ESN Discord OAuth provider.
        \\Illuminate\\Support\\Facades\\Event::listen(function (\\SocialiteProviders\\Manager\\SocialiteWasCalled $event): void {
            $event->extendSocialite('discord', \\SocialiteProviders\\Discord\\Provider::class);
        });

"""
    if needle not in s:
        raise SystemExit("Could not patch AppServiceProvider.php")
    s = s.replace(needle, replacement, 1)
    p.write_text(s)
PY

echo "[5/8] Installing the Discord OAuth controller..."
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

        if ($email === '' || !(bool) ($raw['verified'] ?? false)) {
            return redirect('/auth/login?oauth=verified-email-required');
        }

        $user = User::query()
            ->whereRaw('LOWER(email) = ?', [$email])
            ->first();

        if ($user && $user->root_admin) {
            return redirect('/auth/login?oauth=admin-password-required');
        }

        if (!$user) {
            do {
                $username = 'discord_' . Str::lower(Str::random(12));
            } while (User::query()->where('username', $username)->exists());

            $display = trim((string) ($oauth->getName() ?: $oauth->getNickname() ?: 'Discord User'));
            $parts = preg_split('/\s+/', $display, 2);

            $first = mb_substr(trim((string) ($parts[0] ?? 'Discord')), 0, 191) ?: 'Discord';
            $last = mb_substr(trim((string) ($parts[1] ?? 'User')), 0, 191) ?: 'User';

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

if "auth.oauth.discord.callback" not in s:
    block = """
// ESN Discord OAuth.
Route::get('/oauth/discord', [Auth\\OAuthController::class, 'redirect'])
    ->name('auth.oauth.discord');

Route::get('/oauth/discord/callback', [Auth\\OAuthController::class, 'callback'])
    ->name('auth.oauth.discord.callback');

"""
    marker = "// Catch any other combinations of routes and pass them off to the React component."
    pos = s.find(marker)
    if pos < 0:
        raise SystemExit("Could not find auth fallback marker.")
    s = s[:pos] + block + s[pos:]
    p.write_text(s)
PY

echo "[7/8] Adding Continue with Discord to the login page..."
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
        raise SystemExit("Could not find LoginContainer insertion point.")
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
echo "Discord redirect must be:"
echo "https://panel.esnoffical.com/auth/oauth/discord/callback"
