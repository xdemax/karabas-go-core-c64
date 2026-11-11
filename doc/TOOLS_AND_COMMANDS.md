# Инструменты и команды: сборка ядра, заливка и управление Karabas

Дата: 2026-11-09 (обновлено 2026-11-11). Всё проверено на Karabas Mini G,
`/dev/ttyACM0`, прошивка `26110520`. Актуальное состояние PRG/CRT и
артефакты — `doc/STATUS_2026-11-11.md`, `doc/ARTIFACTS.md`.

Репозитории:

- основной: `karabas-go-core-c64/` (ядро `c64`);
- запасной: `karabas-go-core-c64-unoxt-test/` (ядро `c64u`);
- общие модули: `../karabas-go-modules-master` (симлинк `modules`).

---

## 1. Serial: `tools/karabas.py`

Шлёт одну команду `AT+KARABAS=...` в `/dev/ttyACM0` (115200 8N1 raw) и печатает
ответ.

```sh
cd karabas-go-core-c64
python3 tools/karabas.py 'AT+KARABAS=version'
python3 tools/karabas.py 'AT+KARABAS=list'
```

### Основные команды

| Команда | Действие |
|---|---|
| `AT+KARABAS=version` | какое ядро реально запущено: `+KARABAS:<fw>;<HW_ID>;<core.id>;<build>` |
| `AT+KARABAS=list` | список установленных `.kg` |
| `AT+KARABAS=msc` | перезагрузка в режим USB-накопителя (SD) |
| `AT+KARABAS=boot` | **BOOTSEL RP2040** (прошивка!), НЕ boot menu |
| `AT+KARABAS=key:menu+esc` | открыть/закрыть OSD ядра |
| `AT+KARABAS=key:esc` | закрыть OSD / назад |
| `AT+KARABAS=key:f12` | Reset (если ядро назначило F12) |
| `AT+KARABAS=key:up/down/left/right` | навигация |
| `AT+KARABAS=key:enter` | выбор |
| `AT+KARABAS=type:<текст>` | эмуляция набора текста (HID) |
| `AT+KARABAS=hold:<key>` / `AT+KARABAS=release` | удержать/отпустить |

`HW_ID`: `1` — Go, `2` — Mini, `3` — Mini G.

Пример: `+KARABAS:26110520;3;c64;26110802`.

---

## 2. Сборка ядра

ISE 14.7, `src/Makefile`:

```sh
cd src
make minig            # полная сборка: xst -> ngdbuild -> map -> par -> trce -> bitgen -> c64.kg
make minig FAST=1     # быстрая тестовая: без trce, map -ol med, par -ol std
make minig-report     # LUT/BRAM/тайминг по map-отчёту
make clean            # промежуточные файлы (не .kg/.bin)
```

В `Makefile`:

```make
KG = c64.kg                     # для основного; в unoxt-test — c64u.kg
ifeq ($(FAST),1)
MAP_OPT = -logic_opt off -ol med ... -r 4 ... -mt 2 ...
PAR_OPT = -ol std -xe n -mt 4
endif
```

`FAST=1` пропускает `trce` (отчёт по таймингу) и снижает усилие. Для финальной
сборки — без `FAST`.

Выход: `src/c64.kg`, `src/karabas_minig.bin`, `.bit`.

### Полезные проверки

```sh
grep -E 'Number of (Slice LUTs|occupied Slices|RAMB16BWERs):' karabas_minig_map.mrp
grep -i -E 'ERROR|Error|Ошибка' /tmp/build.log
```

---

## 3. Заливка `.kg` на SD через MSC

```sh
# 1. Перевести плату в MSC
python3 tools/karabas.py 'AT+KARABAS=msc'

# 2. Дождаться SD (размер не 0)
for i in $(seq 1 60); do
  [ "$(cat /sys/block/sdb/size 2>/dev/null || echo 0)" != "0" ] && break
  sleep 1
done

# 3. Дождаться, пока udisks увидит раздел, и смонтировать
for i in $(seq 1 30); do udisksctl info -b /dev/sdb1 >/dev/null 2>&1 && break; sleep 1; done
udisksctl mount -b /dev/sdb1
# обычно /run/media/demo/CORES

# 4. Скопировать
cp src/c64.kg /run/media/demo/CORES/c64.kg
sync
md5sum src/c64.kg /run/media/demo/CORES/c64.kg

# 5. Размонтировать и извлечь (плата уйдёт в boot menu)
udisksctl unmount -b /dev/sdb1
drive=$(udisksctl info -b /dev/sdb | sed -n "s/.*Drive: *'\([^']*\)'.*/\1/p" | head -1)
gdbus call --system --dest org.freedesktop.UDisks2 \
  --object-path "$drive" --method org.freedesktop.UDisks2.Drive.Eject '{}'
```

Важно: `udisksctl mount` иногда падает сразу после появления `/dev/sdb1` —
подождать и повторить. `eject` через `udisksctl` может не иметь прав; `gdbus`
работает.

---

## 4. Boot menu и выбор ядра

После извлечения SD плата снова в boot menu.

```sh
python3 tools/karabas.py 'AT+KARABAS=version'    # +KARABAS:...;boot;...
python3 tools/karabas.py 'AT+KARABAS=key:down'   # нужное число раз
python3 tools/karabas.py 'AT+KARABAS=key:enter'
python3 tools/karabas.py 'AT+KARABAS=version'    # должно быть c64 / c64u
```

Порядок в меню (на момент сессии): `1 Boot Menu`, `2 C64 UnoXT test`,
`3 Commodore 64`. Проверять глазами по скриншоту OBS.

---

## 5. Скриншоты захвата (OBS)

Источник истины — превью OBS (UVC-граббер), а не `v4l2`.

```sh
# полный экран (надёжнее всего)
spectacle -f -b -n -o docs/captures/current.png

# только активное окно (если активно OBS)
spectacle -a -b -n -o docs/captures/current.png
```

Если снимается терминал/мессенджер, активировать OBS скриптами KWin:

```sh
qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript \
  "$PWD/tools/activate_obs_unmin.js"
qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.start
sleep 1
spectacle -f -b -n -o docs/captures/current.png
```

Скрипты: `tools/activate_obs.js`, `activate_obs_unmin.js`,
`activate_obs_all.js`.

Если картинка чёрная — не делать вывод «ядро не работает», пока не проверен
OSD: `key:menu+esc` + скриншот.

---

## 6. `tools/type_slow.py`

Посимвольный ввод в C64 (KERNAL опрашивает матрицу ~60 раз/с, пакет теряется).

```sh
python3 tools/type_slow.py 'load@$@,8' --delay 0.4
python3 tools/type_slow.py 'print 42' --delay 0.3
python3 tools/type_slow.py 'hello' --no-enter
```

Особенности C64:

- `type:"` приходит как `1` (мапинг PC `"` = Shift+', а C64 ждёт Shift+2);
  **вместо кавычки использовать `@`** (PC Shift+2 → C64 `"`);
- `$` работает через `type:$`;
- буквы лучше строчными (`load`, не `LOAD`), заглавные через `type:` могут
  уходить как Shift+буква и давать псевдографику;
- после сбоя/залипания модификатора — `F12` (в новых сборках сбрасывает и
  матрицу клавиатуры через `kbd_reset(reset)`).

---

## 7. Остальные инструменты

| Файл | Назначение |
|---|---|
| `tools/make_core.py` | упаковка `.bin` + `core.json` → `.kg` (вызывается из Makefile) |
| `tools/kg_model.py` | разбор/генерация формата `.kg` |
| `tools/mif2vhd.py` | конвертация Altera `.mif` в VHDL ROM |
| `tools/karabas.py` | serial-команды |
| `tools/type_slow.py` | посимвольный ввод |
| `tools/activate_obs*.js` | активация окна OBS через KWin |

---

## 8. SD-карта (раскладка на момент сессии)

```text
/CORES/
  boot.kg
  c64.kg                 # основное, MiSTer-машина
  c64u.kg                # запасное, UnoXT-машина
  c64/                   # образы для OSD "Disk 8"
    bitnax.d64
    Empty.d64
    CP-ClockF83_1.3.D64
  config/
  sega/
```

`c64u2.kg` удалён. В `core.json` основного ядра есть `Disk 8` → `/c64`.

---

## 9. Отладочные полоски (как включались)

В `c64_machine.v`:

- `dbg_mode(2'd1)` — полоски, `2'd0` — обычная картинка;
- `dbg_addr(dbg_word)` — 16-битное слово;
- в `c64video.v` полоски рисуются по `hc/45` (16 колонок, бит15 слева);
- слова циклически меняются раз в секунду (`dbg_sel`, `dbg_timer`).

Слова: сектор загрузчика, сектор кэша, байт кэша, состояние загрузчика,
`dsk_addr[15:0]`, `dsk_changes`, `img_size[15:0]`, `img_mounted`.

Расшифровка скриншота: полосы в области `x≈1074..1673`, `y=350` (1920×1080),
белый=1, синий=0; 16 ячеек.

---

## 10. Грабли

1. `AT+KARABAS=boot` — это **BOOTSEL** (режим прошивки RP2040), а не boot menu.
   Выход — `picotool`/запись UF2 или перезагрузка платы.
2. `.kg` на SD ≠ загружено в FPGA: проверять `AT+KARABAS=version`.
3. `udisksctl mount` может упасть сразу после появления раздела — подождать.
4. `spectacle` без активного OBS снимает терминал; использовать `-f`.
5. `type:` пакетом теряет символы; только посимвольно.
6. `type:"` → `1`; использовать `@`.
7. После `type:` с Shift возможен залипший модификатор; `F12` (в новых
   сборках) или передёрнуть питание.
8. Загрузка D64: образ монтируется, но старая 1541 пока не отвечает по IEC
   (`SEARCHING FOR $`); см. `TZ_FOR_CLAUDE_1541.md`.
