#!/bin/bash
# Edits config.txt and cmdline.txt in the given boot directory for FXBox.
# Idempotent: the FXBox block is replaced on every run; backups are made once.
#     boot-config.sh /boot/firmware                        apply (auto-detect Pi model)
#     boot-config.sh /boot/firmware --model pi4|pi5        apply for a specific Pi model
#     boot-config.sh /boot/firmware --restore              restore the backups
set -euo pipefail
BOOT="${1:?boot directory}"
shift || true
CFG="$BOOT/config.txt"
CMD="$BOOT/cmdline.txt"

MODEL_ARG="auto"
RESTORE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --restore) RESTORE=1; shift ;;
        --model) MODEL_ARG="${2:-auto}"; shift 2 ;;
        --model=*) MODEL_ARG="${1#--model=}"; shift ;;
        *) echo "Onbekende optie: $1" >&2; exit 2 ;;
    esac
done

if [ "$RESTORE" = 1 ]; then
    [ -f "$CFG.fxbox-backup" ] && cp "$CFG.fxbox-backup" "$CFG"
    [ -f "$CMD.fxbox-backup" ] && cp "$CMD.fxbox-backup" "$CMD"
    exit 0
fi

detect_model() {
    local m="${FXBOX_TARGET_MODEL:-}"
    [ -n "$m" ] || m="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)"
    case "$m" in
        *"Raspberry Pi 5"*|pi5|Pi5|PI5) echo "pi5" ;;
        *"Raspberry Pi 4"*|pi4|Pi4|PI4) echo "pi4" ;;
        *) echo "pi4" ;;   # backward-compatible default
    esac
}

case "$MODEL_ARG" in
    pi4|pi5) TARGET="$MODEL_ARG" ;;
    auto|"") TARGET="$(detect_model)" ;;
    *) echo "Onbekend model: $MODEL_ARG (gebruik pi4 of pi5)" >&2; exit 2 ;;
esac

[ -f "$CFG.fxbox-backup" ] || cp "$CFG" "$CFG.fxbox-backup"
[ -f "$CMD.fxbox-backup" ] || cp "$CMD" "$CMD.fxbox-backup"

# UART/MIDI overlays differ by Pi generation (see zynthian-sys boot/config.txt):
# Pi 4: free PL011 (ttyAMA0) for DIN MIDI by moving Bluetooth to the mini-UART.
# Pi 5: enable the primary UART via uart0-pi5; midi-uart0 adjusts the baud rate.
case "$TARGET" in
    pi5) UART_LINES=$'enable_uart=1\ndtoverlay=uart0-pi5\ndtoverlay=midi-uart0' ;;
    *)   UART_LINES=$'enable_uart=1\ndtoverlay=miniuart-bt\ndtoverlay=midi-uart0' ;;
esac

sed -i '/^# >>> fxbox/,/^# <<< fxbox/d' "$CFG"
sed -i 's/^dtparam=audio=on/#dtparam=audio=on  # disabled by fxbox/' "$CFG"
cat >> "$CFG" <<EOF
# >>> fxbox (managed by FXBox install.sh; edits inside this block are overwritten)
# Target: $TARGET
[all]
dtparam=i2c_arm=on
dtparam=spi=on
dtparam=i2s=on
dtparam=audio=off
hdmi_force_hotplug=1
disable_splash=1
$UART_LINES
dtoverlay=hifiberry-dacplusadcpro
force_eeprom_read=0
dtoverlay=piscreen2r-notouch,rotate=270
dtoverlay=piscreen2r-backlight
# Backlight on from power-up (GPIO 22), also if the backlight overlay is not applied.
gpio=22=op,dh
# <<< fxbox
EOF

# cmdline.txt is one line. Remove the serial console (the UART is DIN MIDI)
# and keep boot messages off the screens.
line="$(head -n1 "$CMD")"
line="$(echo "$line" | sed -E 's/console=(serial0|ttyAMA0|ttyS0),[0-9]+ ?//g')"
for opt in quiet loglevel=3 logo.nologo vt.global_cursor_default=0 consoleblank=0 fbcon=map:0; do
    [[ " $line " == *" $opt "* ]] || line="$line $opt"
done
echo "$line" | tr -s ' ' | sed 's/^ //; s/ $//' > "$CMD"
