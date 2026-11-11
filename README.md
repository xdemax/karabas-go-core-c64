# C64 for Karabas Go / Mini / Mini G

Порт Commodore 64 на Karabas Go, Mini rev A–F и Mini G (XC6SLX25-2 FTG256,
4 МБ SRAM, 32 МБ SDRAM). Общая машина одна; отличаются только верхние обёртки,
видео/аудио и UCF. Один `c64.kg` содержит три битстрима, firmware выбирает
нужный по `HW_ID`.

## Статус (2026-11-11)

Подробно: **`doc/STATUS_2026-11-11.md`**.

- **Видео/BASIC/OSD/D64/ROM** — работают. 2× near-full 720×576, D64 через
  `img_sdc` (slot 0), KERNAL/1541 ROM через `F` (slots 2/3), `Del` = eject.
- **PRG** — работает: `FL` slot 1, загрузка в C64 RAM и авто-набор `RUN`+
  Enter (MiSTer `inj_meminit`, пауза клавиш 1.28M). Проверено `hello.prg`.
- **CRT** — F-слот 5, как ROM: MiSTer-парсер CRT + `cartridge.v`, данные в
  SRAM. Загрузчик транспортно адаптирован под `img_sdc` (секторный буфер
  512 Б, как в `c64_d64_loader.v`). **Статус не финальный:**
  - ложный `eject` firmware при F-монтировании обрывает загрузку до
    заголовка; в исходнике есть фильтр, он ещё не залит;
  - Ocean Type 1 даёт статичный синий экран, EasyFlash (тип 32) — чёрный:
    это уже маппер/раскладка банков, не загрузка;
  - F-autoload из ini прошивка не применяет (у `FL` autoload работает).
- **Eject:** штатный `Del` F-слота; глобального hotkey нет. После
  исправления фильтра `Del` должен снимать CRT и перезапускать C64 в BASIC.
- **Звук:** SID работает, остаточные щелчки/перегруз — в работе.
- **TAP**, запись диска/G64, stereo SID — не сделаны; оценки в
  `doc/PLAN_STEREO_SID.md`.
- **Платы:** Go, Mini rev A–F и Mini G собираются (`make all`, три
  битстрима в одном `c64.kg`). Все три платы проверены на железе: загрузка,
  видео и звук работают. Подробности — `doc/PLAN_BOARDS_GO_MINI.md`.

## Документация

- `doc/STATUS_2026-11-11.md` — **главный актуальный статус** (PRG/CRT,
  отладочные квадраты, известные проблемы, артефакты).
- `doc/NEXT_SESSION_STUDY.md` — что изучить перед следующей сессией
  (CRT-маппер, F/FL/eject, тайминг, TAP, SID, платы).
- `doc/PLAN_STEREO_SID.md` — что нужно для второго SID и сколько ресурсов.
- `doc/PLAN_BOARDS_GO_MINI.md` — порт на Karabas Go и Mini rev A–F.
- `doc/ARTIFACTS.md` — сохранённые сборки и md5.
- `doc/SESSION_2026-11-09.md` — итоги сессии 2026-11-09 (историческое).
- `doc/D64_1541_FIX.md` — причина `SEARCHING FOR $` и исправление.
- `doc/AUDIO_SID.md` — аудиотракт, захват с MS2109, баг `cs` в SID.
- `doc/ROM_FILES.md` — ROM-файлы C64/1541 и OSD-слоты (`F`, slots 2/3).
- `doc/VIDEO_HDMI_TIMING.md` — свободная развёртка 720×576.
- `doc/TOOLS_AND_COMMANDS.md` — сборка, MSC/заливка `.kg`, serial, OSD.
- `doc/TZ_FOR_CLAUDE_1541.md` — ТЗ по дисководу (1541).
- `doc/SESSION_FINDINGS_C64.md` — история отладки.
- `doc/KARABAS_MEMORY.md` — память Karabas Go/Mini/Mini G.
- `doc/WORKFLOW_CAPTURE_AND_CONTROL.md` — serial, OSD, MSC, boot menu.
- `doc/TZ_C64_RGB_HDMI.md` — ТЗ на конвертер RGB→HDMI.
- `doc/AUDIT_C64_FOR_KIMI.md`, `..._SHORT.md` — исторические аудиты.
- `doc/artifacts/` — сохранённые тестовые `.kg`.

## Сборка

Клонировать с сабмодулем:

```sh
git clone --recursive https://github.com/xdemax/karabas-go-core-c64.git
```

ISE 14.7:

```sh
cd src
make all              # go + mini + minig, один c64.kg
make go               # только Karabas Go
make mini             # только Mini rev A-F
make minig            # только Mini G
make go-report        # LUT/BRAM/тайминг выбранной платы
make minig FAST=1     # быстрая тестовая: без trce, map -ol med, par -ol std
```

Для финальной сборки использовать `make all` (с отчётом по таймингу каждой
платы).

## Память

C64 RAM/картридж/D64 — в SRAM по одному байту на 16-битное слово.
Видео — 4 строки по 504 пикселя в BRAM (2 RAMB16), без SRAM.
В UnoXT-тесте 64 КБ C64 RAM вынесены в BRAM (как в оригинальном `c64_zxt.vhd`).

Карта и тайминги — в `doc/KARABAS_MEMORY.md`.

## Управление (кратко)

```sh
python3 tools/karabas.py 'AT+KARABAS=version'
python3 tools/karabas.py 'AT+KARABAS=key:menu+esc'   # OSD
python3 tools/karabas.py 'AT+KARABAS=key:esc'
python3 tools/karabas.py 'AT+KARABAS=key:f12'
python3 tools/karabas.py 'AT+KARABAS=msc'            # обновление .kg по SD
```

`type:` в C64 набирает текст **посимвольно с паузами** (KERNAL опрашивает
клавиатуру ~60 раз/с); пакетная отправка теряет символы.
