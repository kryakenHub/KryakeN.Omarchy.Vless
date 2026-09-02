# Правка плагина VLESS — исправление автозагрузки (режим System не применялся)

**Session ID:** ses_f9e08812affedyQI33tF4Qdpm4
**Created:** 9/2/2026
**Плагин:** `kryaken.omarchy.vless` (VLESS VPN, Xray) — Omarchy/Quickshell
**Рабочая директория плагина:** `/home/poseydon/.config/omarchy/plugins/kryaken.omarchy.vless/`

---

## Описание проблемы

Плагин VLESS имеет два режима работы:
- **Proxy** (по умолчанию) — локальный SOCKS 127.0.0.1:1080 / HTTP 1081.
- **System** — прозрачный VPN: iptables REDIRECT исходящего TCP 80/443 в Xray :1082.

В интерфейсе плагина был выбран режим **System** (полный ВПН). Однако после **перезагрузки** системы плагин и служба `xray-vpn` были активны, но:
- IP-адрес отображался **локальный** (`178.49.57.9`), а не ВПН-туннеля (`144.31.1.40`);
- приходилось вручную указывать прокси (SOCKS 1080) в браузере — работал только proxy-режим, прозрачный VPN не применялся.
- Т.е. плагин при автозагрузке **не учитывал выбранный режим System**.

---

## Диагностика

### 1. Проверка туннеля напрямую
```bash
curl -sS -m 8 -x socks5h://127.0.0.1:1080 https://api.ipify.org   # -> 144.31.1.40 (ВПН)
curl -sS -m 8 https://api.ipify.org                               # -> 178.49.57.9 (локальный)
```
SOCKS туннель работал, но прямой (прозрачный) трафик шёл мимо туннеля.

### 2. Журнал службы showed, что итоговый маршрут только через SOCKS
```
journalctl -u xray-vpn
... from tcp:127.0.0.1:35934 accepted tcp:api.ipify.org:443 [socks-inbound -> proxy]
```
В хray проходили только `[socks-inbound -> proxy]`; записей `[transparent-inbound -> proxy]` не было → iptables-redirect не применяется.

### 3. iptables-цепочка отсутствовала
```bash
sudo iptables -t nat -S XRAYVPN
# iptables: No chain/target/match by that name.
```

### 4. При этом ExecStartPost=rules-on возвращал SUCCESS
```bash
systemctl status xray-vpn
# Process: 1147 ExecStartPost=.../backend.sh rules-on (code=exited, status=0/SUCCESS)
```
Скрипт завершался с кодом 0, но правила не создавались — значит код до `apply_system_rules()` не доходил.

---

## Причина

Команда `rules-on` (вызывается из `ExecStartPost` юнита при загрузке) шла через `refresh_rules()`, который начинался с проверки `unit_active()`:

```bash
refresh_rules() {
  if unit_active; then
    if [ "$(get_mode)" = "system" ]; then apply_system_rules "${1:-}"; else remove_system_rules; fi
  fi
}
```

В момент выполнения `ExecStartPost` при загрузке `systemctl is-active` ещё не возвращает `active`, поэтому:
- `apply_system_rules()` **пропускался**;
- цепочка `XRAYVPN` не создавалась;
- прозрачного перенаправления не происходило — оставался только локальный SOCKS/прокси;
- служба при этом оставалась `active`, что соответствовало симптомам.

---

## Исправление

Файл: `/home/poseydon/.config/omarchy/plugins/kryaken.omarchy.vless/backend.sh`

Команда `rules-on` теперь применяет правила **напрямую по выбранному режиму**, не завися от `unit_active()` — с предварительной очисткой возможной устаревшей цепочки:

```bash
rules-on)
  # ExecStartPost hook: apply transparent redirect based on the chosen mode.
  remove_system_rules
  if [ "$(get_mode)" = "system" ]; then
    apply_system_rules
  fi
  ;;
```

Изменённый блок размещён около строки **694** (см. `case "$cmd" in ... rules-on)`).

---

## Проверка исправления (выполнено вручную)

```bash
sudo bash backend.sh rules-on
sudo iptables -t nat -S XRAYVPN
```
Вывод — цепочка создана корректно:
```
-N XRAYVPN
-A XRAYVPN -d 127.0.0.0/8 -j RETURN
-A XRAYVPN -d 10.0.0.0/8 -j RETURN
-A XRAYVPN -d 172.16.0.0/12 -j RETURN
-A XRAYVPN -d 192.168.0.0/16 -j RETURN
-A XRAYVPN -d 169.254.0.0/16 -j RETURN
-A XRAYVPN -d 224.0.0.0/4 -j RETURN
-A XRAYVPN -p udp -m udp --dport 53 -j RETURN
-A XRAYVPN -d 144.31.1.40/32 -j RETURN
-A XRAYVPN -p tcp -m multiport --dports 80,443 -j REDIRECT --to-ports 1082
```

После этого прямой `curl https://api.ipify.org` вернул **144.31.1.40** (IP туннеля) — прозрачный ВПН заработал.

---

## Как проверить автозагрузку после перезагрузки

Перезагрузить машину и выполнить:
```bash
curl https://api.ipify.org      # должен показать IP туннеля 144.31.1.40, не локальный 178.49.57.9
sudo iptables -t nat -S XRAYVPN # цепочка должна существовать
```

Либо без перезагрузки:
```bash
sudo systemctl restart xray-vpn
curl https://api.ipify.org
```

---

## Затронутые файлы / пути

| Что | Путь |
|---|---|
| Плагин (backend-скрипт, отредактирован) | `/home/poseydon/.config/omarchy/plugins/kryaken.omarchy.vless/backend.sh` |
| Юнит systemd (согласован, не менялся) | `/etc/systemd/system/xray-vpn.service` |
| Конфиг Xray (runtime) | `/etc/xray-vpn/config.json` |
| Активный профиль | `/etc/xray-vpn/profiles/default.json` |
| Файл режима | `/etc/xray-vpn/mode` (значение: `system`) |
| Файл активного профиля | `/etc/xray-vpn/active` (значение: `default`) |

Резервные копии backend.sh (для отката правки):
- `/home/poseydon/.config/omarchy/plugins/kryaken.omarchy.vless/.backup-20260831-193021/`
- `/home/poseydon/.config/omarchy/plugins/kryaken.omarchy.vless/.backup-20260901-131228/`

---

## История правок backend.sh (по бэкапам)

1. **20260831-193021** — добавлены `ExecStartPost=rules-on` / `ExecStopPost=rules-off` в юнит; переписан `ensure_install()` для синхронизации on-disk юнита; добавлены `server_ips_retry()` и `fast`-аргумент для ручных операций.
2. **20260901-131228** — идентичен текущей (зафиксирован состояние перед данной правкой).
3. **20260902 (данная)** — `rules-on` больше не зависит от `unit_active()`.
4. **20260902 (security)** — security hardening для plugins.omarchy.org: root-owned backend, chmod 600, iptables trap.

---

## Security hardening для plugins.omarchy.org

**Дата:** 2026-09-02

Ревьюер plugins.omarchy.org обнаружил критические проблемы:
- pkexec повторно выполняет user-writable `backend.sh` как root → root code execution
- Профили (UUID/ключи) с правами 0644 → world-readable
- Нет rollback iptables при ошибке
- `curl | bash` в install_hint

### Исправления

| Что | Было | Стало |
|---|---|---|
| pkexec target | `~/.config/.../backend.sh` (user-writable) | `/etc/xray-vpn/backend.sh` (root:root 0755) |
| systemd ExecStartPost | plugin-path | `/etc/xray-vpn/backend.sh` |
| serve() subprocess | `"$0"` (plugin path) | `"$INSTALLED_BACKEND"` |
| Panel.qml pkexec | `daemonScriptPath` | `privilegedScriptPath` |
| Профили `*.json` | `chmod 644` | `chmod 600` |
| `profiles/` dir | `chmod 755` | `chmod 700` |
| `config.json` | `chmod 644` | `chmod 600` |
| `active` file | `chmod 644` | `chmod 600` |
| iptables | нет cleanup | `trap 'remove_system_rules' ERR` |
| install_hint xray | `curl \| bash` | `paru/yay/apt` или docs URL |

### Цепочка защиты

```
Panel.qml → pkexec /etc/xray-vpn/backend.sh serve
                ↓ (root)
           serve() → python3 → subprocess.run(["/etc/xray-vpn/backend.sh"] + args)
                ↓ (root, но root-owned файл)
           ensure_install() → cp plugin→/etc/xray-vpn/backend.sh (при каждом запуске)
```

Пользователь НЕ МОЖЕТ подменить скрипт, который выполняется как root.

---

## Локальная копия плагина (для сравнения с GitHub-версией)

### Зачем

Проверить, отличается ли скорость включения/выключения VPN между текущей (с патчем автозагрузки) и «честной» версией из GitHub.

### Где хранится локальная копия

```
~/Work/kryaken.omarchy.vless.local/
```

### Команды

```bash
# 1. Создать локальную копию (без .git/ и .backup-*)
mkdir -p ~/Work/kryaken.omarchy.vless.local
rsync -a --exclude='.git' --exclude='.backup-*' \
  ~/.config/omarchy/plugins/kryaken.omarchy.vless/ \
  ~/Work/kryaken.omarchy.vless.local/

# 2. Инициализировать git-репо (нужно для omarchy plugin add file://...)
cd ~/Work/kryaken.omarchy.vless.local
git init && git add -A && git commit -m "local patched version with autoload fix"

# 3. Удалить текущий плагин
omarchy plugin remove kryaken.omarchy.vless

# 4. Установить версию с GitHub
omarchy plugin add https://github.com/kryakenHub/KryakeN.Omarchy.Vless.git --enable --yes

# ...тестирование...

# 5. Вернуть локальную версию
omarchy plugin remove kryaken.omarchy.vless
omarchy plugin add file:///home/poseydon/Work/kryaken.omarchy.vless.local --enable --yes
```
