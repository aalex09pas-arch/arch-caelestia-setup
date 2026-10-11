#!/usr/bin/env bash
# Универсальная установка Caelestia Shell на Arch Linux.
# Запускать обычным пользователем с sudo, НЕ от root.
set -Eeuo pipefail
IFS=$'\n\t'
C_RESET='\033[0m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'; C_BLUE='\033[1;34m'
log_info(){ echo -e "${C_BLUE}[INFO]${C_RESET} $*"; }
log_ok(){ echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
log_warn(){ echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
log_error(){ echo -e "${C_RED}[ERROR]${C_RESET} $*"; }
exec > >(tee -a "$HOME/caelestia-setup.log") 2>&1
WORKDIR=''; SCRIPT_SOURCE=''
cleanup(){ if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then rm -rf -- "$WORKDIR"; fi; }
on_interrupt(){ log_warn 'Прервано пользователем. Установленные пакеты не удаляются; резервные копии сохранены.'; exit 130; }
on_error(){ log_error "Сбой на строке $1 (код $2). Проверьте ~/caelestia-setup.log"; }
trap cleanup EXIT
trap on_interrupt INT TERM
trap 'on_error "$LINENO" "$?"' ERR
backup(){ local path="$1"; if [[ -e "$path" || -L "$path" ]]; then local dest="${path}.bak.$(date +%Y%m%d-%H%M%S).$$"; cp -a -- "$path" "$dest"; log_info "Резервная копия: $dest"; fi; }
require_arch(){ [[ -r /etc/os-release ]] && grep -q 'Arch Linux' /etc/os-release || { log_error 'Требуется Arch Linux.'; exit 1; }; }
require_user(){ [[ "$EUID" -ne 0 ]] && command -v sudo >/dev/null && sudo -v || { log_error 'Запустите от обычного пользователя с настроенным sudo.'; exit 1; }; }
require_net(){ ping -c 1 -W 3 archlinux.org >/dev/null 2>&1 || { log_error 'Нет ответа ping от archlinux.org (возможно, ICMP заблокирован).'; exit 1; }; }
rollback(){
  log_warn 'Откат пользовательских конфигураций (установленные пакеты останутся).'
  local p
  for p in "$HOME/.config/caelestia" "$HOME/.config/hypr"; do
    if [[ -e "$p" ]]; then mv -- "$p" "${p}.bak.$(date +%s).$$"; fi
  done
  log_ok 'Конфиги сохранены как .bak; пакеты и системные службы не изменены.'
}
require_arch
require_user
if [[ "${1:-}" == '--rollback' ]]; then rollback; exit 0; fi
if [[ "${1:-}" == '--clean-reinstall' ]]; then
  log_warn 'Режим чистой переустановки: будут сохранены резервные копии конфигов Caelestia/Hyprland.'
  read -r -p 'Продолжить? (y/N): ' confirm
  [[ "${confirm:-}" =~ ^[YyДд]$ ]] || { log_info 'Отменено.'; exit 0; }
  for p in "$HOME/.config/caelestia" "$HOME/.config/hypr"; do
    if [[ -e "$p" || -L "$p" ]]; then
      backup "$p"
      mv -- "$p" "${p}.clean-backup.$(date +%Y%m%d-%H%M%S).$$"
    fi
  done
  log_ok 'Пользовательские конфиги сохранены и убраны из активных путей.'
  shift
fi
[[ $# -eq 0 ]] || { log_error 'Допустимые аргументы: --rollback, --clean-reinstall'; exit 1; }
require_net
log_info 'Начинаем установку Caelestia Shell.'
# Базовые утилиты нужны до установки yay.
sudo pacman -Syu --needed --noconfirm git base-devel curl jq
if ! command -v yay >/dev/null 2>&1; then
  WORKDIR="$(mktemp -d -t caelestia-yay.XXXXXXXX)"
  git clone --depth 1 https://aur.archlinux.org/yay.git "$WORKDIR/yay"
  (cd "$WORKDIR/yay" && makepkg -si --noconfirm --needed)
  log_ok 'yay установлен.'
fi
# Устанавливаем по одному: так в логе видно конкретный проблемный пакет.
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
  if pacman -Qi "$pkg" >/dev/null 2>&1; then log_ok "$pkg уже установлен"; continue; fi
  log_info "Установка $pkg"
  sudo pacman -S --needed --noconfirm "$pkg"
done
# Проверяем доступность AUR и устраняем только явный конфликт Caelestia stable.
AUR_PACKAGES=(caelestia-shell-git caelestia-cli quickshell-git darkly-bin papirus-folders qtengine pwwcontrol)
# Точное сравнение имени пакета: pacman -Qq caelestia-shell может принять
# похожее имя caelestia-shell-git за совпадение в некоторых вариантах вызова.
if pacman -Qq | grep -Fxq 'caelestia-shell'; then
  log_error 'Установлен именно пакет stable caelestia-shell. Автоматически удалять его небезопасно; проверьте зависимости командой: pacman -Qi caelestia-shell'
  exit 1
fi
for pkg in "${AUR_PACKAGES[@]}"; do
  if pacman -Qi "$pkg" >/dev/null 2>&1; then log_ok "$pkg уже установлен"; continue; fi
  if ! yay -Si "$pkg" >/dev/null 2>&1; then
    log_warn "Пакет $pkg не найден в AUR; пропускаем (возможно, переименован)."
    [[ "$pkg" == caelestia-shell-git || "$pkg" == quickshell-git ]] && { log_error "Обязательный пакет $pkg недоступен."; exit 1; }
    continue
  fi
  log_info "Сборка и установка $pkg"
  yay -S --needed --noconfirm "$pkg"
done
# Создаём конфиги официальным CLI, если он поддерживает команду install.
mkdir -p "$HOME/.config/caelestia" "$HOME/.config/hypr" "$HOME/.local/bin" "$HOME/.config/autostart"
if command -v caelestia >/dev/null 2>&1; then
  if [[ ! -f "$HOME/.config/caelestia/config.json" ]]; then
    log_info 'Попытка инициализации конфигурации через Caelestia CLI.'
    if caelestia --help 2>&1 | grep -Eq '(^|[[:space:]])install([[:space:]]|$)'; then
      caelestia install || log_warn 'CLI install завершился с ошибкой; проверьте документацию установленной версии.'
    fi
  fi
else
  log_error 'Команда caelestia отсутствует после установки.'; exit 1
fi
# Не копируем наугад /usr/share/caelestia/*: структура может отличаться.
# Настройка погоды только для известных JSON-полей, без опасной замены sed.
WEATHER_CONF="$HOME/.config/caelestia/config.json"
CITY='Черкесск'
if [[ -t 0 ]]; then
  read -r -p 'Город для погоды [Черкесск]: ' answer || true
  CITY="${answer:-Черкесск}"
fi
if [[ -f "$WEATHER_CONF" ]]; then
  if jq -e '.services.weather.location? != null' "$WEATHER_CONF" >/dev/null 2>&1; then
    backup "$WEATHER_CONF"
    tmp="$(mktemp "$HOME/.config/caelestia/.weather.XXXXXXXX")"
    jq --arg city "$CITY" '.services.weather.location = $city' "$WEATHER_CONF" > "$tmp"
    chmod --reference="$WEATHER_CONF" "$tmp"
    mv -- "$tmp" "$WEATHER_CONF"
    log_ok "Город погоды: $CITY"
  else
    log_warn 'Поле services.weather.location не найдено; конфиг погоды не изменён.'
  fi
else
  log_warn 'config.json отсутствует; настройте погоду через интерфейс Caelestia.'
fi
# Hyprland исполняет exec-once; XDG autostart сам по себе ненадёжен.
HYPR_CONF="$HOME/.config/hypr/hyprland.conf"
if [[ ! -f "$HYPR_CONF" ]]; then
  # Штатный пример Hyprland, если он есть.
  if [[ -f /usr/share/hypr/hyprland.conf ]]; then
    cp /usr/share/hypr/hyprland.conf "$HYPR_CONF"
  else
    printf '%s\n' 'monitor = , preferred, auto, 1' 'input { kb_layout = us }' 'bind = SUPER, RETURN, exec, kitty' 'bind = SUPER, Q, killactive,' > "$HYPR_CONF"
  fi
else
  backup "$HYPR_CONF"
fi
# Удаляем только наш собственный ранее добавленный блок.
if ! grep -Fq '# BEGIN CAELESTIA SETUP' "$HYPR_CONF"; then
  cat >> "$HYPR_CONF" <<'HYPR'

# BEGIN CAELESTIA SETUP
exec-once = caelestia shell -d
# END CAELESTIA SETUP
HYPR
fi
# Совместимость с окружениями, которые поддерживают XDG autostart.
DESKTOP="$HOME/.config/autostart/caelestia.desktop"
if [[ -e "$DESKTOP" ]]; then backup "$DESKTOP"; fi
cat > "$DESKTOP" <<'DESKTOPFILE'
[Desktop Entry]
Type=Application
Name=Caelestia Shell
Exec=caelestia shell -d
OnlyShowIn=Hyprland;
Hidden=false
X-GNOME-Autostart-enabled=true
DESKTOPFILE
# Перезапуск: не убиваем произвольные процессы по широкому pkill -f.
RESTART="$HOME/.local/bin/restart-caelestia.sh"
if [[ -e "$RESTART" ]]; then backup "$RESTART"; fi
cat > "$RESTART" <<'RESTARTFILE'
#!/usr/bin/env bash
set -euo pipefail
if ! command -v caelestia >/dev/null 2>&1; then echo 'Caelestia CLI не найден' >&2; exit 1; fi
caelestia shell -k || true
sleep 2
caelestia shell -d
RESTARTFILE
chmod +x "$RESTART"
# Включаем сервисы, не отключая автоматически чужой display manager.
for service in NetworkManager bluetooth; do
  sudo systemctl enable "$service.service"
done
if systemctl is-enabled --quiet display-manager.service 2>/dev/null; then
  if [[ "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)" != *sddm.service ]]; then
    log_warn 'Уже выбран другой display manager: SDDM автоматически не включён.'
  else
    sudo systemctl enable sddm.service
  fi
else
  sudo systemctl enable sddm.service
fi
if [[ -d /usr/share/sddm/themes/caelestia ]]; then
  sudo mkdir -p /etc/sddm.conf.d
  if [[ -f /etc/sddm.conf.d/caelestia.conf ]]; then
    sudo cp -a /etc/sddm.conf.d/caelestia.conf "/etc/sddm.conf.d/caelestia.conf.bak.$(date +%s)"
  fi
  printf '[Theme]\nCurrent=caelestia\n' | sudo tee /etc/sddm.conf.d/caelestia.conf >/dev/null
  log_ok 'Тема SDDM Caelestia применена.'
else
  log_warn 'Тема SDDM Caelestia не установлена; оставлена штатная тема SDDM.'
fi
# Предложение публикации: безопаснее использовать gh auth login, чем пароль/token в URL.
if [[ -t 0 ]]; then
  read -r -p 'Загрузить скрипт на GitHub? (y/N): ' UPLOAD || true
  if [[ "${UPLOAD:-}" =~ ^[YyДд]$ ]]; then
    if ! command -v gh >/dev/null 2>&1; then sudo pacman -S --needed --noconfirm github-cli; fi
    if ! gh auth status >/dev/null 2>&1; then gh auth login; fi
    read -r -p 'Название нового репозитория [arch-caelestia-setup]: ' GH_REPO
    GH_REPO="${GH_REPO:-arch-caelestia-setup}"
    if [[ ! "$GH_REPO" =~ ^[a-zA-Z0-9._-]+$ ]]; then
      log_warn 'Некорректное имя репозитория; публикация пропущена.'
    elif [[ ! -f "${BASH_SOURCE[0]}" ]]; then
      log_warn 'Скрипт запущен через process substitution; исходный файл недоступен для копирования. Сохраните его локально для публикации.'
    else
      REPO_DIR="$HOME/$GH_REPO"
      if [[ -e "$REPO_DIR" ]]; then
        log_warn "$REPO_DIR уже существует; публикация пропущена во избежание перезаписи."
      else
        mkdir -p "$REPO_DIR"
        cp -- "${BASH_SOURCE[0]}" "$REPO_DIR/install-caelestia.sh"
        (cd "$REPO_DIR" && git init && git add install-caelestia.sh && git -c user.name="$(gh api user --jq .login)" -c user.email="$(gh api user --jq .id)+$(gh api user --jq .login)@users.noreply.github.com" commit -m 'Add universal Caelestia setup script' && git branch -M main && gh repo create "$GH_REPO" --public --source=. --remote=origin --push)
        log_ok 'Публикация завершена.'
      fi
    fi
  fi
fi
cat <<'END'
=====================================
 УСТАНОВКА CAELESTIA ЗАВЕРШЕНА!
=====================================
1. Перезагрузитесь: sudo reboot
2. На экране SDDM выберите Hyprland.
3. Caelestia запустится через exec-once.
Перезапуск: ~/.local/bin/restart-caelestia.sh
Откат конфигов: bash install-caelestia.sh --rollback
Чистая переустановка конфигов: bash install-caelestia.sh --clean-reinstall
Лог: ~/caelestia-setup.log
=====================================
END
