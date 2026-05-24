#!/bin/bash
# =============================================================================
# Raketa v0.9.5 — macOS 12 compatibility fix
# One-line change: remove `nohup` from the core launch command.
#
# Root cause: on macOS 12 (Monterey), AppleScript's "do shell script" provides
# NO controlling terminal at all. nohup(1) on macOS 12 treats this as an error
# ("Inappropriate ioctl for device") and exits non-zero — killing the launch.
# macOS 10.13 was lenient about this; 12.x is strict.
#
# Fix: drop nohup. The shell `&` operator is sufficient — the backgrounded
# process is reparented to launchd when the parent shell exits, which is
# exactly the behaviour we need. No functionality change on 10.13.
#
# Run from repo root: bash patch_raketa_095.sh
# =============================================================================
set -e
G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; R='\033[0;31m'; N='\033[0m'

echo -e "${C}╔══════════════════════════════════════════╗"
echo -e "║   Raketa v0.9.5 — macOS 12 compat fix    ║"
echo -e "╚══════════════════════════════════════════╝${N}\n"

[ ! -f "ViewController.m" ] && echo -e "${R}✗ Run from repo root${N}" && exit 1

cp ViewController.m ViewController.m.bak095
cp Info.plist Info.plist.bak095
cp .github/workflows/build.yml .github/workflows/build.yml.bak095
echo -e "${G}✓ Backups created${N}\n"

# =============================================================================
# Fix 1: ViewController.m — remove nohup from startVPN shell command
# =============================================================================
echo -e "${Y}→ Patching ViewController.m (remove nohup)...${N}"
python3 - << 'PY'
with open('ViewController.m', 'r') as f:
    s = f.read()

# The exact line we need to change (present in v0.9.4):
OLD = "@\"nohup '%@' run -c '%@' > '%@' 2>&1 & echo $!\","
NEW = "@\"'%@' run -c '%@' > '%@' 2>&1 & echo $!\","

if OLD in s:
    s = s.replace(OLD, NEW)
    print("✓ nohup removed from launch command")
else:
    # Try without comma (in case formatting varies)
    OLD2 = "nohup '%@' run -c '%@' > '%@' 2>&1 & echo $!"
    NEW2 =       "'%@' run -c '%@' > '%@' 2>&1 & echo $!"
    if OLD2 in s:
        s = s.replace(OLD2, NEW2)
        print("✓ nohup removed (variant match)")
    else:
        print("WARNING: nohup pattern not found — check manually")

# Bump version string
s = s.replace('@"v0.9.4"', '@"v0.9.5"')
s = s.replace('"v0.9.4"', '"v0.9.5"')

with open('ViewController.m', 'w') as f:
    f.write(s)
print("✓ ViewController.m saved")
PY

# Verify the change landed correctly
echo -e "${Y}→ Verifying patch...${N}"
python3 - << 'PY'
with open('ViewController.m', 'r') as f:
    s = f.read()

if 'nohup' in s:
    print("ERROR: nohup still present in file!")
    import sys; sys.exit(1)
else:
    print("✓ nohup not present — clean")

# Confirm the replacement is there
if "'%@' run -c '%@' > '%@' 2>&1 & echo $!" in s:
    print("✓ launch command correct")
else:
    print("ERROR: expected launch command not found")
    import sys; sys.exit(1)
PY

# =============================================================================
# Fix 2: Info.plist — bump to v0.9.5
# =============================================================================
echo -e "${Y}→ Info.plist (v0.9.5)${N}"
python3 - << 'PY'
with open('Info.plist', 'r') as f:
    s = f.read()
s = s.replace('0.9.4', '0.9.5')
with open('Info.plist', 'w') as f:
    f.write(s)
print("✓ Info.plist bumped to v0.9.5")
PY

# =============================================================================
# Fix 3: build.yml — bump version in release notes
# =============================================================================
echo -e "${Y}→ build.yml (v0.9.5)${N}"
python3 - << 'PY'
with open('.github/workflows/build.yml', 'r') as f:
    s = f.read()

old_body = """        body: |
          ## 🚀 Raketa ${{ github.ref_name }}

          ### v0.9.4
          **Ключи**
          - «＋ Добавить ключи» — вставить из буфера обмена (переименована)
          - «↻ Обновить ключи» — повторная загрузка с того же URL/ссылки

          **Telegram**
          - Большая кнопка убрана
          - Маленькая кнопка ✈ в нижней панели (tooltip: «Настройка Telegram»)
          - Панель с MTProxy и SOCKS5 по-прежнему открывается, просто компактнее

          Все исправления v0.9.3 включены."""

new_body = """        body: |
          ## 🚀 Raketa ${{ github.ref_name }}

          ### v0.9.5 — macOS 10.13 + 12.x compatibility
          - ✅ Исправлен запуск ядра на macOS 12 (Monterey)
          - Причина: `nohup` на macOS 12 падает с «Inappropriate ioctl for device»
            когда нет управляющего терминала (AppleScript-окружение).
            На macOS 10.13 это молча игнорировалось. Решение: убрать nohup,
            фоновый запуск через `&` достаточен — процесс переходит под launchd.
          - Поведение на macOS 10.13 не изменилось.
          - Все исправления v0.9.4 включены."""

if old_body in s:
    s = s.replace(old_body, new_body)
    print("✓ release notes updated")
else:
    # Fallback: just replace version numbers
    s = s.replace('v0.9.4', 'v0.9.5')
    print("✓ version bumped in build.yml (fallback)")

with open('.github/workflows/build.yml', 'w') as f:
    f.write(s)
print("✓ build.yml saved")
PY

echo ""
echo -e "${G}Summary of changes:${N}"
echo -e "  ViewController.m: removed 'nohup' from sing-box launch command"
echo -e "  Info.plist:       version 0.9.4 → 0.9.5"
echo -e "  build.yml:        release notes updated"
echo ""
echo -e "${C}╔══════════════════════════════════════════════════════╗"
echo -e "║  Commands:                                           ║"
echo -e "╠══════════════════════════════════════════════════════╣"
echo -e "║  git add -A                                          ║"
echo -e "║  git commit -m 'v0.9.5: fix macOS 12 nohup error'   ║"
echo -e "║  git tag v0.9.5                                      ║"
echo -e "║  git push origin main --tags                         ║"
echo -e "╚══════════════════════════════════════════════════════╝${N}"
