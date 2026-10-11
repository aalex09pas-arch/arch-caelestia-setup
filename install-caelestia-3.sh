#!/usr/bin/env bash
# Установка Caelestia Shell (стабильный пакет) для Arch Linux.
# Запускать обычным пользователем с настроенным sudo, НЕ от root.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

C_RESET='\033[0m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[1;31m'; C_BLUE='\033[1;34m'
log_info(){ echo -e "${C_BLUE}[INFO]${C_RESET} $*"; }
log_ok(){ echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
log_warn(){ echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
log_error(){ echo -e "${C_RED}[ERROR]${C_RESET} $*"; }
LOG_FILE="$HOME/caelestia-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1
WORKDIR=''
cleanup(){ [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf -- "$WORKDIR"; }
on_interrupt(){ log_warn 'Операция прервана. Установленные пакеты автоматически не удаляются.'; exit 130; }
on_error(){ local code="$2"; log_error "Ошибка на строке $1 (код $code). Подробности: $LOG_FILE"; exit "$code"; }
trap cleanup EXIT
trap on_interrupt INT TERM
trap 'on_error "$LINENO" "$?"' ERR

backup(){
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    local dest="${path}.bak.$(date +%Y%m%d-%H%M%S).$$"
    cp -a -- "$path" "$dest"
    log_ok "Резервная копия: $dest"
  fi
}
require_arch(){
  [[ -r /etc/os-release ]] || { log_error 'Не найден /etc/os-release.'; exit 1; }
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == arch || " ${ID_LIKE:-} " == *" arch "* ]] || { log_error 'Требуется Arch Linux или совместимая система.'; exit 1; }
}
require_user(){
  [[ "$EUID" -ne 0 ]] || { log_error 'Не запускайте скрипт через sudo; запустите от обычного пользователя.'; exit 1; }
  command -v sudo >/dev/null 2>&1 || { log_error 'Не найден sudo.'; exit 1; }
  sudo -v
}
require_net(){
  command -v curl >/dev/null 2>&1 || { log_error 'curl не найден. Установите: sudo pacman -S curl'; exit 1; }
  curl -fsSI --connect-timeout 8 --max-time 15 https://archlinux.org/ >/dev/null || { log_error 'Нет доступа к archlinux.org; проверьте интернет.'; exit 1; }
}
is_installed(){ pacman -Qq "$1" >/dev/null 2>&1; }
rollback(){
  log_warn 'Откат конфигов: текущие каталоги будут переименованы; пакеты не удаляются.'
  local p
  for p in "$HOME/.config/caelestia" "$HOME/.config/hypr"; do
    if [[ -e "$p" || -L "$p" ]]; then
      mv -- "$p" "${p}.rollback.$(date +%Y%m%d-%H%M%S).$$"
      log_ok "Сохранён каталог: $p.rollback.*"
    fi
  done
}

require_arch
require_user
if [[ "${1:-}" == '--rollback' ]]; then rollback; exit 0; fi
[[ $# -eq 0 ]] || { log_error 'Допустимый аргумент: --rollback'; exit 2; }
require_net
log_info 'Установка стабильной Caelestia Shell.'

# Обновляем систему и устанавливаем инструменты сборки.
sudo pacman -Syu --needed git base-devel curl jq
if ! command -v yay >/dev/null 2>&1; then
  log_info 'Устанавливаем yay из AUR.'
  WORKDIR="$(mktemp -d -t caelestia-yay.XXXXXXXX)"
  git clone --depth 1 https://aur.archlinux.org/yay.git "$WORKDIR/yay"
  (cd "$WORKDIR/yay" && makepkg -si --needed)
  command -v yay >/dev/null 2>&1 || { log_error 'yay не найден после установки. Перезапустите терминал и повторите.'; exit 1; }
fi

# Удаляем только конфликтующий git-вариант, а не все пакеты/зависимости.
if is_installed caelestia-shell-git; then
  log_warn 'Обнаружена caelestia-shell-git. Сохраняем конфиги перед переключением на stable.'
  backup "$HOME/.config/caelestia"
  backup "$HOME/.config/hypr"
  sudo pacman -R caelestia-shell-git || { log_error 'Не удалось удалить caelestia-shell-git. Не используйте -Rdd; проверьте зависимости.'; exit 1; }
fi
if is_installed caelestia-shell-git; then
  log_error 'caelestia-shell-git всё ещё установлен; остановка во избежание конфликта.'
  exit 1
fi

PACMAN_PACKAGES=(
  hyprland xdg-desktop-portal-hyprland qt6-wayland qt5-wayland
  polkit-kde-agent gnome-keyring networkmanager bluez bluez-utils
  pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber
  sddm kitty fish starship fastfetch btop micro thunar firefox
  ttf-jetbrains-mono-nerd noto-fonts noto-fonts-cjk noto-fonts-emoji
  papirus-icon-theme adw-gtk-theme wl-clipboard cliphist curl git jq
  lazygit bat ripgrep ydotool hyprpicker xdg-user-dirs trash-cli
  eza zoxide direnv foot
)
for pkg in "${PACMAN_PACKAGES[@]}"; do
  if is_installed "$pkg"; then log_ok "$pkg уже установлен"; else log_info "Установка системного пакета: $pkg"; sudo pacman -S --needed "$pkg"; fi
done

# Здесь принципиально используется стабильный caelestia-shell, НЕ caelestia-shell-git.
AUR_PACKAGES=(caelestia-shell caelestia-cli darkly-bin papirus-folders qtengine pwwcontrol)
for pkg in "${AUR_PACKAGES[@]}"; do
  if is_installed "$pkg"; then log_ok "$pkg уже установлен"; continue; fi
  if ! yay -Si "$pkg" >/dev/null 2>&1; then
    if [[ "$pkg" == caelestia-shell || "$pkg" == caelestia-cli ]]; then log_error "Обязательный пакет $pkg не найден в AUR."; exit 1; fi
    log_warn "Пакет $pkg не найден в AUR; пропускаем."
    continue
  fi
  log_info "Установка AUR-пакета: $pkg"
  yay -S --needed "$pkg"
done

if ! is_installed caelestia-shell; then log_error 'Стабильный пакет caelestia-shell не установлен.'; exit 1; fi
if is_installed caelestia-shell-git; then log_error 'caelestia-shell-git всё ещё установлен; требуется ручная проверка.'; exit 1; fi
command -v caelestia >/dev/null 2>&1 || { log_error 'Команда caelestia не найдена; проверьте caelestia-cli.'; exit 1; }
log_ok 'Стабильная Caelestia Shell установлена.'

mkdir -p "$HOME/.config/caelestia" "$HOME/.config/hypr" "$HOME/.local/bin" "$HOME/.config/autostart"
# Не вызываем caelestia install автоматически: это может повторно запускать установку и вызвать конфликт.
[[ -f "$HOME/.config/caelestia/config.json" ]] || log_warn 'config.json отсутствует; настройте оболочку штатными средствами после первого входа.'

WEATHER_CONF="$HOME/.config/caelestia/config.json"
CITY='Черкесск'
if [[ -t 0 ]]; then read -r -p 'Город для погоды [Черкесск]: ' answer || true; CITY="${answer:-Черкесск}"; fi
if [[ -f "$WEATHER_CONF" ]] && jq -e '.services.weather.location? != null' "$WEATHER_CONF" >/dev/null 2>&1; then
  backup "$WEATHER_CONF"
  tmp="$(mktemp "$HOME/.config/caelestia/.weather.XXXXXXXX")"
  jq --arg city "$CITY" '.services.weather.location = $city' "$WEATHER_CONF" > "$tmp"
  chmod --reference="$WEATHER_CONF" "$tmp"
  mv -- "$tmp" "$WEATHER_CONF"
  log_ok "Город погоды: $CITY"
else
  log_warn 'Поле services.weather.location не найдено; настройте погоду через интерфейс Caelestia.'
fi

HYPR_CONF="$HOME/.config/hypr/hyprland.conf"
if [[ ! -f "$HYPR_CONF" ]]; then
  if [[ -f /usr/share/hypr/hyprland.conf ]]; then cp /usr/share/hypr/hyprland.conf "$HYPR_CONF"; else
    cat > "$HYPR_CONF" <<'HYPR'
monitor = , preferred, auto, 1
input {
    kb_layout = us
}
$terminal = kitty
bind = SUPER, RETURN, exec, $terminal
bind = SUPER, Q, killactive,
HYPR
  fi
else
  backup "$HYPR_CONF"
fi
if ! grep -Fq '# BEGIN CAELESTIA SETUP' "$HYPR_CONF"; then
  cat >> "$HYPR_CONF" <<'HYPR'

# BEGIN CAELESTIA SETUP
exec-once = caelestia shell -d
# END CAELESTIA SETUP
HYPR
fi

DESKTOP="$HOME/.config/autostart/caelestia.desktop"
[[ ! -e "$DESKTOP" ]] || backup "$DESKTOP"
cat > "$DESKTOP" <<'DESKTOPFILE'
[Desktop Entry]
Type=Application
Name=Caelestia Shell
Exec=caelestia shell -d
OnlyShowIn=Hyprland;
Hidden=false
X-GNOME-Autostart-enabled=true
DESKTOPFILE

RESTART="$HOME/.local/bin/restart-caelestia.sh"
[[ ! -e "$RESTART" ]] || backup "$RESTART"
cat > "$RESTART" <<'RESTARTFILE'
#!/usr/bin/env bash
set -euo pipefail
command -v caelestia >/dev/null 2>&1 || { echo 'Caelestia CLI не найден' >&2; exit 1; }
caelestia shell -k || true
sleep 2
caelestia shell -d
RESTARTFILE
chmod +x "$RESTART"

for service in NetworkManager bluetooth; do
  if systemctl list-unit-files "${service}.service" >/dev/null 2>&1; then sudo systemctl enable "${service}.service"; fi
done
if systemctl is-enabled --quiet display-manager.service 2>/dev/null; then
  current_dm="$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)"
  if [[ "$current_dm" == *sddm.service ]]; then sudo systemctl enable sddm.service; else log_warn 'Другой display manager уже выбран; не переключаем его автоматически.'; fi
else
  sudo systemctl enable sddm.service
fi
if [[ -d /usr/share/sddm/themes/caelestia ]]; then
  sudo mkdir -p /etc/sddm.conf.d
  if [[ -f /etc/sddm.conf.d/caelestia.conf ]]; then sudo cp -a /etc/sddm.conf.d/caelestia.conf "/etc/sddm.conf.d/caelestia.conf.bak.$(date +%Y%m%d-%H%M%S)"; fi
  printf '[Theme]\nCurrent=caelestia\n' | sudo tee /etc/sddm.conf.d/caelestia.conf >/dev/null
  log_ok 'Тема SDDM Caelestia применена.'
else
  log_warn 'Тема SDDM Caelestia не найдена; текущая тема сохранена.'
fi

cat <<'END'
==================================================
 НАСТРОЙКА CAELESTIA ЗАВЕРШЕНА
==================================================
Установщик проверил наличие стабильного caelestia-shell.
Он НЕ удалял все системные пакеты и НЕ удалял их зависимости.
Резервные копии конфигов имеют суффикс .bak.*
1. Перезагрузитесь: sudo reboot
2. На экране входа выберите Hyprland.
3. Лог: ~/caelestia-setup.log
Перезапуск: ~/.local/bin/restart-caelestia.sh
Откат конфигов: bash install-caelestia.sh --rollback
==================================================
END
