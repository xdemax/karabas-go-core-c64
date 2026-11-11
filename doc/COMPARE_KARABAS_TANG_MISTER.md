# Сравнение C64-ядер: Karabas / Tang C64Nano / MiSTer

Дата: 2026-11-11

Сводка по исходникам и README, не по рекламным описаниям.
«Наш» — текущий порт Karabas C64 (`karabas-go-core-c64`).

## 1. Машина, видео, звук

| | Karabas C64 (наш) | Tang C64Nano | MiSTer C64 |
|---|---|---|---|
| Режимы | C64 PAL | C64 PAL/NTSC, C64GS-джойстик | C64 + C64GS |
| VIC/CIA | VIC-II, 2×6526, фиксированно | выбор VIC-ревизии, CIA 6526/8521 | 656x/856x/early 856x, 6526/8521 |
| Turbo | — | есть (turbo mode/speed) | C128/Smart 2x/3x/4x |
| RTC | — | — | да |
| Pause при OSD | — | да | да |
| Видео | HDMI 720×576, 2× near-full | HDMI 720×576/480 + LCD, 2× crop | HDMI/VGA/analog, ascal: 480p/576p/1080p |
| Масштабирование | 2×, кроп 12 source px бордюра по бокам | 2×, окно 720 из 1008 | полноценный ascal, фильтры/scanlines/aspect |
| OSD | да | да | да |
| SID | 1×8580, моно | 1/2×6581/8580, stereo, кастомные фильтры | dual 6581/8580, stereo/mix, фильтры |
| DigiMax | — | да | да |
| OPL2 | — | — | да |
| Аудиовыходы | HDMI + PCM5102 | HDMI + LCD speaker | HDMI/analog/SPDIF |
| Индикаторы | красный `8` диска + аудио-пики на LED-матрицы | LED0 — активность диска | drive OSD; LED-матриц нет |
| ROM/фильтры | KERNAL + 1541 ROM overlay | KERNAL BIN, выбор 1541 DOS ROM, FLT | C64+C1541 ROM, C1581 ROM, FLT |

## 2. Носители и расширения

| | Karabas C64 | Tang C64Nano | MiSTer C64 |
|---|---|---|---|
| 1541 | 1, D64 только чтение | 1, D64/G64 чтение/запись | 2, D64/G64 чтение/запись/format |
| 1581 | — | — | да, D81 |
| Форматы дисков | D64 | D64, G64 | D64, G64, T64*, D81 |
| Точность G64 | — | raw track | flux/GCR, weak bits, RPM, wobble |
| Запись/сохранение | — (`dsk_wr` не подключён) | да, save_track на SD | да, background save |
| Parallel/DolphinDOS | — | DolphinDOS 2 | DolphinDOS |
| Внешний IEC | — | да | да |
| Лента | — | TAP/C1530 | TAP/C1530 + счётчик/FF/REW |
| Картриджи | CRT `F`: парсер/данные есть, маппер Ocean/EasyFlash не финальный | CRT/EasyFlash/freezer | почти все CRT, EasyFlash, boot/autosave |
| PRG | да (`FL`, авто `RUN`) | да | да |
| REU/GeoRAM | — | 512K/2M/16M** + GeoRAM | 512K/2M/16M + GeoRAM 4M |
| T64 | — | — | в селекторе монтирования |
| C1581 ROM | — | — | да |
| Файлы | D64, KERNAL/1541 ROM, PRG, CRT (CRT в работе) | D64/G64/CRT/PRG/BIN/TAP/FLT/REU | D64/G64/T64/D81/PRG/CRT/REU/TAP/ROM/FLT |

\* T64 указан в `CONF_STR` MiSTer, но основные реально проверенные — D64/G64/D81.  
\** 16 МБ REU только на платах кроме TN20K; на TN20K — 512K/2M.

## 3. Периферия и интерфейсы

| | Karabas C64 | Tang C64Nano | MiSTer C64 |
|---|---|---|---|
| USB-клавиатура | да | да | да |
| Джойстики | 2 | 2×D9 + USB, numpad | 4 + SNAC |
| Мышь/paddles | — | USB-мышь C1351, paddles | да |
| RS232 | — | VIC-1011/UP9600 + Swiftlink 6551 | VIC-1011/UP9600 |
| MIDI | — | физический MIDI IN/OUT* | — |
| User port | — | да | да |
| Parallel port | — | да | да |
| RTC | — | — | да |
| Freezer/Action Replay | — | да | AR/FC-картриджи |
| C64GS | — | C64GS-джойстик | режим C64GS |
| WiFi-модем | — | опционально (BL616) | через RS232 |
| Память | 4 МБ SRAM + 32 МБ SDRAM (SDRAM свободна) | SDRAM под C64/REU | DDR3 + REU |

\* MIDI/RS232/6551 у Tang зависят от конкретной платы/шилда.

## Итог

Наш Karabas сейчас — это **C64 + одна 1541 (D64 read-only) + KERNAL/1541 ROM
+ PRG (FL) + CRT (F, в работе) + HDMI/PCM + OSD + индикаторы**.
Из таблицы пока отсутствует: TAP, G64/D81, запись диска, REU/GeoRAM,
stereo/DigiMax/OPL2, MIDI/RS232/6551, parallel/external IEC, mouse/paddles,
C64GS, turbo, RTC, freezer. Подробности — `doc/STATUS_2026-11-11.md`.

## План добавления файлов

1. **PRG — сделано:** `FL` + `c64_prg_loader.v`, инъекция в C64 RAM,
   MiSTer-указатели, авто `RUN`+Enter.
2. **CRT — в работе:** MiSTer-парсер `c64_crt_loader.v` + `cartridge.v`,
   транспорт через `F`/`img_sdc` с секторным буфером. Осталось: фильтр
   ложного eject при монтировании, маппер Ocean Type 1 и EasyFlash.
3. **TAP** — позже, нужна C1530/tape-подсистема.

Железо менять не нужно; для CRT используется свободная SRAM (банки
`0x020000…`), для PRG — C64 RAM через `p_*`.
