# Переход C64 на MCU link v2 и новый OSD

Дата: 2026-11-14. Прошивка: **26111315 или новее**. Модули:
`karabas-go-modules` master (`9ff485e`, link v2 + bitmap OSD).

## Что изменилось в ядре

- Верхние обёртки `karabas_{go,mini,minig}_top.v` больше не используют
  `kg_mcu`, `kg_soft_switches` и `img_sdc`. Вместо них один `kg_mcu2`:
  - `MCU_INT` выведен на IO1: `MCU_IO[1]` на Mini / Mini G,
    `MCU_SPI_IO[0]` на Go (там индексы перепутаны);
  - `MCU_IO[0]` — вход `1'bz`;
  - переключатели: `SW[0]` = Reset, `SW[8]` = Joystick swap (switch 1);
  - клавиатура: `PS2_CODE` / `PS2_KIND` / `PS2_WR`; из строба `PS2_WR`
    сделан toggle для прежнего детектора в `c64_machine`;
  - джойстики: `JOY_L/JOY_R` 16 бит, в машину идут младшие 13;
  - кнопки: `BTNS[1:0]`;
  - LED-матрица: `MATRIX_CMD` / `MATRIX_CMD_WR` сохранены
    (`ENABLE_AUX(1)`, `audio_peaks` не менялся).
- Файловый маунтер `img_sdc` заменён секционным интерфейсом `kg_mcu2`
  (`ENABLE_IMG(1)`, `IMG_OUT_LATENCY(3)`); `sdc_*` для D64/ROM/CRT
  остались прежними. Запись диска по-прежнему не поддерживается:
  `SDC_WR = 0`, `SDC_BYTE_OUT_DATA = 0`.
- Загрузка PRG: C64 — OSD-ядро, PRG — элемент `FL`, поэтому прошивка
  присылает `LD_KIND = 2`. Маппинг на старые `file_*`:
  `file_reset = LD_START && kind`, `file_active = LD_ACTIVE && kind`,
  `file_wr = LD_WR && kind`, остальное — `LD_SIZE/ADDR/DATA/SLOT`.
  Kind 1 тоже принимается на случай fileloader-прошивки.
- OSD: старый `kg_osd_overlay` и `osd_command` заменены на
  `kg_l2_osd_overlay` (`wclk = clk_host`, видео `clk = clk_vid`).
  HDMI/VGA берут `osd_rgb/osd_hs/osd_vs/osd_de`.
- `core.json`: `"link": 2`; битстримы попадают в `BITSTREAM_LINK2`.

## Сборка

Первый раз после перехода — **удалить старый `c64.kg` и собрать `make all`**.
`make_core.py --boards <board>` сохраняет битстримы остальных плат из
прежнего файла; при `link: 2` старые v1-битстримы были бы записаны в
секцию `BITSTREAM_LINK2`.

## Что проверить на железе

- загрузка ядра и лог `MCU link v2`, `Link v2: core answered ... caps`;
- клавиатура, Reset (F12), Joystick swap;
- монтирование D64, KERNAL/1541 ROM, CRT (слоты 0/2/3/5);
- PRG (`FL` слот 1): загрузка и автонабор `RUN`;
- кассета с реального `TAPE_IN` (файловые TAP/T64 в ядре не нужны);
- OSD: меню, страницы, hotkeys;
- звук в джеке: на Mini G rev G2 (PCM5102) BCK теперь идёт напрямую,
  без инверсии ODDR2 (см. `doc/AUDIO_SID.md`, раздел 8);
- Mini: `FT_CLK_OUT` по-прежнему ~8 МГц (ODDR2), `MCU_SCK` идёт в
  `kg_mcu2` напрямую.
- FT812: видео и OSD через него не идут (`ft_sel = 0`); вход `FT_CLK`
  из логики убран, `FT_CLK_OUT` 8 МГц оставлен для тишины в аудио.
  Подробно — `doc/FT812.md`.
