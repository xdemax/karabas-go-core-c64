# Архитектура ядра C64 для Karabas Go / Mini / Mini G

Дата: 2026-11-17. Описание текущего состояния (link v2, build 26111750).
Прошивка: **26111315+**. Сборка и артефакты — `README.md`, `doc/ARTIFACTS.md`.

## 1. Что это

Один общий модуль `c64_machine.v` (C64 + 1541 + видео + SID) и три тонкие
обёртки под платы:

| Плата | Верхний модуль | Видео | Аудио |
|---|---|---|---|
| Karabas Go | `karabas_go_top.v` | VGA 8:8:8 + `V_CLK` | PCM5102 (I2S) |
| Mini rev A–F | `karabas_mini_top.v` | HDMI | sigma-delta `AUDIO_L/R` |
| Mini G / G2 | `karabas_minig_top.v` | HDMI | UDA1334ATS (rev G) / PCM5102 (rev G2) |

Отличия плат — только PLL, пины, видео/аудио и обвязка MCU. Машина,
память, загрузчики и SID общие. Один `c64.kg` содержит три битстрима,
firmware выбирает нужный по `HW_ID`.

## 2. Блочная схема

```text
                ┌──────────────── karabas_<board>_top.v ────────────────┐
                │                                                       │
 MCU link v2 ──►│ kg_mcu2 ── LD/IMG/OSD/SW/HID/AUX                       │
 (SPI/INT)      │   │          │            │                           │
                │   │          │            └─► kg_l2_osd_overlay ──┐   │
                │   │          └─ kg_l2_img (sdc_* сектора)          │   │
                │   ▼                                                  ▼   │
                │ c64_machine.v  ── rgb/hs/vs/de ──► c64_video ──► HDMI/VGA
                │   │  (CPU/VIC/CIA/SID/1541/CRT/ROM)                  │
                │   ├── SRAM: MA/MD/MWR_N/MRD_N                        │
                │   └── audio_l/r 18-bit ──► 48 kHz ──► HDMI / DAC      │
                └───────────────────────────────────────────────────────┘
```

## 3. Тактирование и сброс

PLL (`kg_pll`) на всех платах даёт от 50 МГц:

- `clk_sys = clk_vid = 31.25 МГц` — C64 и видео (1008x624, 49.68 Гц);
- `clk_sram = 62.5 МГц` — внешняя SRAM (2 такта на доступ);
- `clk_host = 25 МГц` — MCU link и загрузчики;
- `clk_8mhz` — FT812 и HDMI-обвязка.

Сброс:

- `reset` — C64/1541: PLL lock, кнопка, OSD Reset, завершение загрузки ROM;
- `reset_host` — только power-on: маунты образов переживают F12;
- `c64video` тактируется от `reset_host`, чтобы HS/VS/DE не пропадали при
  сбросе C64.

## 4. Верхние обёртки

### Go

- VGA: `VGA_R/G/B = osd_rgb`, `VGA_HS/VS` инвертированы из `osd_hs/vs`.
- PCM5102: `kg_pcm5102 #(.DIV_BITS(2))` от `clk_sys`, `DAC_BCK` — напрямую
  (без инвертирующего ODDR2), `DAC_MUTE=1`.
- `MCU_SCK` не на клок-пине: идёт в `kg_mcu2` напрямую.
- `MCU_INT` — на `MCU_SPI_IO[0]` (на Go индексы IO перепутаны).
- FT812: видео не используется; SPI-пины отдельные.

### Mini rev A–F

- HDMI (`kg_hdmi_ft`), `FT_CLK_OUT` — ODDR2 8 МГц (обязателен для FT812).
- `FT_CLK` не используется: `kg_hdmi_ft.clk = clk_8mhz`.
- Аудио: sigma-delta `kg_sigma_delta_dac` на `AUDIO_L/R` (48 кГц).
- `MCU_SCK` — прямо в `kg_mcu2`; `CLOCK_DEDICATED_ROUTE=FALSE` в UCF.

### Mini G / Mini G2

- HDMI (`kg_hdmi_ft`), `FT_CLK_OUT` — ODDR2 8 МГц; `FT_CLK` из логики убран
  (`kg_hdmi_ft.clk = clk_8mhz`).
- I2S DAC: `kg_pcm5102 #(.DIV_BITS(2))` от `clk_vid`, `DAC_BCK` напрямую.
  DIN/LRCK меняются по падению BCK, DAC сэмплирует следующий фронт через
  полпериода. Это фикс «нет звука» на rev G2 (PCM5102): раньше ODDR2
  инвертировал BCK, и данные менялись ровно на сэмплирующем фронте.
- `MCU_SCK` — IBUFG + BUFG.

## 5. Машина C64 (`c64_machine.v`)

Внутри — VHDL-ядро `fpga64_sid_iec` (Peter Wendrich / MiSTer) и обвязка:

- **CPU** — `cpu_6510`/T65, 1 МГц;
- **VIC-II** — `video_vicII_656x`, PAL 504x312;
- **CIA1/2** — `mos6526`, клавиатура, IEC, таймеры;
- **SID** — `sid_mister8580` (8580), один чип;
- **плата** — `cartridge.v` (CRT), `c1541_*` (1541), `c64_memory`
  (внешняя SRAM), `c64_video`/`c64video` (скейлер).

Сброс C64 дополнительно удерживается:

- `prg_hold` — пока PRG-загрузчик пишет RAM;
- `cart_hold` — пока CRT-загрузчик/`cartridge.v` держит шину.

## 6. Память

Внешняя SRAM — 2M x 16, один байт на 16-битное слово:

| Адрес (слово) | Что |
|---|---|
| `0x000000–0x00FFFF` | C64 RAM (64K) |
| `0x010000–0x01FFFF` | cartridge RAM |
| `0x020000–0x11FFFF` | cartridge ROM (1 МБ, раскладка `cartridge.v`) |
| `0x120000 + d_addr` | D64 (256 КБ, read-only) |
| `0x1E0000–0x1EFFFF` | PRG staging |
| `0x1FFFFF` | пустой/неиспользуемый адрес |

ROM:

- C64 BASIC/KERNAL/CHARGEN и 1541 ROM — встроены в BRAM;
- F-слоты 2/3 (`KERNAL`, `1541 ROM`) — overlay через `c64_rom_ov`;
- заводские ROM остаются, если файл не выбран.

Видео — в BRAM: 4 строки x 512 x RGB565 (`c64video.v`), 2 x RAMB16.
Отдельного SRAM под видео больше нет.

## 7. Загрузка файлов и образов

MCU link v2 (`kg_mcu2`) отдаёт три вида загрузки (`LD_KIND`):

| Kind | Что | Как в C64 |
|---:|---|---|
| 0 | ROM (не используется) | — |
| 1 | file loader | не используется |
| 2 | `FL`-элемент (PRG) | `LD_*` → `c64_prg_loader` |

**PRG (`FL`, slot 1)**: `LD_START/ACTIVE/WR/DATA/ADDR/SIZE/SLOT` в
`c64_machine` → `c64_prg_loader`: байты в очередь, staging в SRAM,
после boot KERNAL — копирование в C64 RAM, автонабор `RUN`+Enter.

**F-слоты (`F`)**: `kg_l2_img` даёт секторный интерфейс `sdc_*`
(как `img_sdc`), `c64_img_mount` запоминает маунты:

- slot 0 D64 → `c64_d64_loader` → SRAM `0x120000`; 1541 читает через
  `c64_d64_rd`;
- slots 2/3 KERNAL/1541 ROM → `c64_rom_loader` → `c64_rom_ov`;
- slot 5 CRT → `c64_img_file_loader` → `c64_crt_loader` → SRAM-банки +
  `cartridge.v`.

`c64_img_file_loader` также умеет отдавать байты PRG/TAP-путям, но
файловый TAP-лоадер в текущей ветке не подключён.

**Кассета**: только реальный `TAPE_IN` (компаратор) → `cass_read` →
CIA FLAG. `TAPE_OUT=0`; мотор не управляется. Файловых TAP/T64 нет
(`doc/TAPE_IN.md`).

## 8. 1541

- `c1541_sd.vhd` + `c1541_logic.v` + `c1541_gcr.v` + `c1541_via6522.vhd`;
- D64 читается из SRAM через `c64_d64_rd` (окно `0x120000`);
- один дисковод, **только чтение**; `drive_led` — индикатор диска `8`;
- запись диска/G64 не поддерживаются;
- образ монтируется как F-слот 0 через `kg_l2_img`.

## 9. Видео

VIC-II выдаёт 504x312 при 7.8125 МГц (pixel_ce на 31.25 МГц).
`c64_video` → `c64video`:

- line buffer 4x512xRGB565 в BRAM;
- свободная развёртка 720x576 / 1008x624 при 31.25 МГц (49.68 Гц);
- genlock от кадра VIC; при пропадании кадров — чёрный экран, но
  HS/VS/DE и OSD продолжают работать;
- активная область C64 320x200 → 640x400 (2x), **отцентрована**:
  бордюр по 88 строк сверху/снизу и по 40 пикселей слева/справа,
  чёрных полос нет (`V_CONTENT=576`, `V_OFFSET=0`, `SRC_LINE0=18`,
  `SRC_X0=11`);
- OSD link v2 — `kg_l2_osd_overlay` поверх `rgb` в `clk_vid`
  (`wclk=clk_host`), 256x128 bitmap, масштаб 2 при 720x576;
- Go: VGA; Mini/Mini G: HDMI `kg_hdmi_ft`; FT812 в видео не участвует.

Активная область 640x400 — это 1.6, не 4:3; для 4:3 нужен отдельный
горизонтальный crop/шаг (в `c64video` есть режим `3/5`).

## 10. Звук

- SID 8580, 18-bit signed, DC-blocker в `c64_machine`;
- в верхней обёртке — сэмплирование 48 кГц (аккумулятор +48 при 31.25 МГц);
- HDMI: `kg_hdmi_ft` с `audio_en = ~dvi_only`;
- Go: PCM5102 I2S, `DAC_BCK` напрямую;
- Mini A–F: sigma-delta DAC на `AUDIO_L/R`;
- Mini G: UDA1334ATS, Mini G2: PCM5102; `DAC_BCK` напрямую, без
  инверсии ODDR2 (фикс rev G2);
- FT812: `FT_CLK_OUT` 8 МГц обязателен, иначе чип фонит в звук.

Остаточные щелчки/перегруз — известная незакрытая задача; stereo SID
не сделан (`doc/PLAN_STEREO_SID.md`).

## 11. Ввод, OSD, индикаторы

- клавиатура: USB HID/PS2 от MCU → `PS2_CODE/PS2_KIND/PS2_WR` → toggle →
  `ps2_key` в `fpga64_sid_iec` (матрица C64);
- джойстики: `JOY_L/R` 16 бит, в машину — младшие 13;
- кнопки: `BTNS[1:0]` (board), сброс;
- переключатели: `SW[0]` Reset, `SW[8]` Joystick swap;
- LED-матрица: `audio_peaks` → `MATRIX_CMD/MATRIX_CMD_WR` → `kg_mcu2`
  AUX;
- индикатор диска `8` в нижнем бордюре (зелёный чтение / красный запись);
  индикатор кассеты `T` удалён вместе с TAP-лоадером.

## 12. MCU link v2

- `MCU_SCK/MOSI/MISO/SS` + `MCU_INT` (IO1);
- `kg_mcu2` = `kg_l2_link/sys/hid/load/osd/img/aux` (PORT/RTC выключены);
- `CAPS=0`; `SW_N=2`; `ENABLE_OSD/IMG/AUX=1`; `IMG_OUT_LATENCY=3`;
- `core.json`: `link: 2`, `type: osd`; битстримы в `BITSTREAM_LINK2`;
- прошивка 26111315+; старые прошивки ядро не увидят.

Подробности — `doc/LINK_V2.md`.

## 13. Сборка и ресурсы

```sh
cd src
make all        # go + mini + minig, один c64.kg
make go-report  # LUT/slices/timing
```

После перехода на link v2 первый раз удалить старый `c64.kg` и собрать
`make all` (иначе v1-битстримы могут попасть в `BITSTREAM_LINK2`).

Ресурсы сборки 26111750: Go 72/91%, Mini 86/99%, Mini G 85/99%
(LUT/slices), RAMB16 78%, timing 0. Mini/Mini G — на пределе по слайсам,
новые фичи требуют экономии.

## 14. Что работает и что нет

Работает (проверено на железе, если не указано иное):

- BASIC, KERNAL, видео 720x576, OSD link v2;
- D64 read-only, один 1541, KERNAL/1541 ROM через F;
- PRG через FL (загрузка + авто `RUN`);
- CRT через F: парсер + `cartridge.v`, типовые 8K/16K/Ultimax
  картриджи проверялись; Ocean Type 1/EasyFlash — отдельные мапперы,
  проверять на конкретных образах;
- клавиатура, джойстики, Reset/Joystick swap, LED-матрица;
- звук: HDMI и DAC; на Mini G rev G2 исправлен `DAC_BCK`.

Ограничения/не сделано:

- запись диска/G64;
- файловый TAP/T64 (кассета — только `TAPE_IN`);
- stereo SID, REU/GeoRAM, MIDI/RS232/принтер, mouse/paddles;
- FT812 видео/OSD не используются (только `FT_CLK_OUT` для тишины);
- остаточные аудиоартефакты SID.

## 15. Карта файлов

| Файл | Роль |
|---|---|
| `src/rtl/karabas_go_top.v` | обёртка Go (VGA, PCM5102) |
| `src/rtl/karabas_mini_top.v` | обёртка Mini A–F (HDMI, sigma-delta) |
| `src/rtl/karabas_minig_top.v` | обёртка Mini G/G2 (HDMI, I2S DAC) |
| `src/rtl/c64_machine.v` | общая машина C64 |
| `src/rtl/c64_memory.v` | контроллер внешней SRAM |
| `src/rtl/c64_video.v` | обёртка/параметры скейлера |
| `src/rtl/c64video.v` | line buffer, 720x576, genlock |
| `src/rtl/c64_prg_loader.v` | PRG (LD kind 2) |
| `src/rtl/c64_crt_loader.v` | CRT-парсер + banks |
| `src/rtl/c64_d64_loader.v` | D64 → SRAM |
| `src/rtl/c64_rom_loader.v` | KERNAL/1541 ROM overlay |
| `src/rtl/c64_img_file_loader.v` | байты F-образов (CRT и др.) |
| `src/rtl/c64/cartridge.v` | CRT-маппер |
| `src/rtl/iec/c1541_*` | 1541 |
| `src/rtl/c64/fpga64_sid_iec.vhd` | CPU/VIC/CIA/SID |
| `src/rtl/sid_mister8580/*` | SID 8580 |
| `modules/rtl/mcu/kg_mcu2.v` | MCU link v2 |
| `modules/rtl/mcu/kg_l2_*.v` | link/OSD/IMG/AUX |
| `modules/rtl/video/osd/kg_l2_osd_overlay.v` | bitmap OSD |
