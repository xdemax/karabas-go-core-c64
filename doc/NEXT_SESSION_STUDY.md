# Что изучить перед следующей сессией

Дата: 2026-11-11. Список по приоритету; сначала — то, что блокирует CRT
на Mini G. Текущее состояние — `doc/STATUS_2026-11-11.md`.

## 1. CRT-маппер (главный блокер)

Изучить построчно:

- MiSTer `C64_MiSTer-master/c64.sv`:
  - сброс/`reset_wait` (около строк 295–305);
  - `load_crt` и `cart_hdr_cnt`/`cart_blk_len`/`cart_bank_*`
    (около 675–772);
  - `inj_meminit` и key injection (около 730–880).
- MiSTer `C64_MiSTer-master/rtl/cartridge.v`:
  - типы **0** (generic 8/16K/Ultimax), **5** (Ocean Type 1), **32/33**
    (EasyFlash);
  - `bank_load`/`lobanks`/`hibanks`, `get_bank`, `cart_boot`, `ezrom_*`,
    `force_ultimax`, `addr_out`;
  - как `$8000/$A000/$E000` выбирают банк и когда включается Ultimax.
- Tang `C64Nano-2.9.13/src/tang/tn20k/c64nano.vhd` — тот же парсер;
  сравнить с MiSTer байт-в-байт.
- UnoXT `unoxt-c64-core-main/src/c64/c64_zx3.vhd` (`host_bootdata`,
  `cart_addr_wr_8bit`) — понять, что там разбор CRT делает контроллер,
  а не C64-ядро.

Вопросы, на которые нужны точные ответы:

1. Почему Ocean Type 1 (32 пакета: 0–15 low `$8000`, 16–31 high `$A000`)
   даёт статичный синий экран? Какой начальный банк должен быть у
   `$8000` и `$A000`? Нужно ли `bank_hi = bank_lo + 16` или
   `lobanks/hibanks`?
2. Почему EasyFlash (тип 32) чёрный? `cart_boot=1` → `game=0`/`exrom=1`
   (Ultimax) — верно? Что делает `ezrom` и нужен ли он для загрузки
   банков из CRT?
3. Совпадает ли наш SRAM-адрес банка (word `0x020000 + data_done`) с
   `get_bank()`/`CRT_ADDR` MiSTer для всех типов?
4. Какой начальный банк/адрес у Type 1 и EasyFlash после `cart_id`?

## 2. Karabas-транспорт F/FL и eject

Изучить:

- `karabas-go-modules-master/rtl/mcu/kg_mcu_loader.v` — IOCTL_SLOT/SIZE/
  STATE, `file_reset`, `file_active`, `file_wr`.
- `karabas-go-modules-master/rtl/mcu/kg_mcu_img.v` — `IMG_SLOT`,
  `IMG_SIZE`, `img_mounted` (один такт), size0.
- `src/rtl/c64_img_mount.v` — persistent `mounted`, `mount_pulse`,
  `eject_pulse`, level vs pulse.
- `src/rtl/c64_img_file_loader.v` — F-секторный буфер `sbuf`, `S_FEED`,
  `eject5_ok`, фильтр.
- `src/rtl/c64_d64_loader.v` — эталон `sbuf` + handshake.
- `src/rtl/c64_rom_loader.v` — как ROM переживает eject/reset.
- Firmware Karabas (внешний репозиторий `karabas-go-firmware`): как
  обрабатываются F/FL `autoload`, `Del` в файловом браузере, ini.

Вопросы:

1. Почему F `autoload: true` не монтируется на старте, а FL — да?
2. Что именно firmware шлёт при F-монтировании: size0 eject, level-fall
   или mount+close? Почему ложный eject приходит **до** заголовка CRT?
3. Настоящий `Del` F-слота — это size0 или отдельный сигнал? Какой
   `eject_pulse` у ROM (slot2/3) и почему он не мешает?
4. Можно ли отфильтровать ложный eject по `pending`/`state`, не задерживая
   настоящий `Del`? Текущий фильтр: ignore пока `pending5`/не IDLE + 2 с
   после чтения.
5. Нужно ли для CRT использовать **FL** (autoload работает) вместо F,
   и как тогда сделать eject (OSD item/softswitch)?

## 3. C64-шина, сброс, ROM/картридж

- `src/rtl/c64/fpga64_sid_iec.vhd` — порты EXROM/GAME/IOE/IOF, `sid`,
  `tape_*`, `reset`.
- `src/rtl/c64/fpga64_buslogic_roms_mmu.vhd` — как EXROM/GAME/Ultimax
  выбирают ROM/картридж, `$A000`/`$E000`.
- `src/rtl/c64/cartridge.v` — `mem_ce_out`, `mem_addr`, `mem_req`,
  `mem_write_out`.
- `src/rtl/c64_memory.v` — `c_map` 0x020000, `MA`, фазы SRAM, `c64_hold`.
- C64 KERNAL reset: почему 16K-картридж с `game=0/exrom=0` заменяет BASIC
  и куда переходит CPU.

## 4. Тайминг и ресурсы

- `src/karabas_minig.par`, `_map.mrp`, `.twr`; `trce` команда из
  `doc/TOOLS_AND_COMMANDS.md`.
- UCF: `TS_SRAM_OUT`, `TS_SYS_*`, TIG для host-портов.
- Понимать worst paths: C64/VIC/CIA → `mem/MA`, 16 нс; текущая загрузка
  96–97% slices.
- Что чистить: отладочные 8 квадратов, мёртвый staging/FL, лишние
  порты; затем high-effort `make minig` до Timing 0.

## 5. TAP (следующая большая фича)

- MiSTer `C64_MiSTer-master/c64.sv`: `load_tap`, tape player, `TAP_ADDR`.
- Tang `c64nano.vhd`: `load_tap`, `tap_*`.
- C64 core `fpga64_sid_iec.vhd`: `tape_play/rew/stop/ff/reset_counter`.
- Формат TAP/C1530, кнопки/счётчик, где хранить образ (SRAM/SDRAM).

## 6. Stereo SID

- `src/rtl/sid/sid_top.v` (сейчас один 8580, right=left).
- MiSTer `rtl/sid/sid_top.sv` `DUAL=1`.
- `fpga64_sid_iec.vhd` `sid_mode`/`sid_sel_l/r`, адреса $D400/$D420/$D500.
- План/оценка — `doc/PLAN_STEREO_SID.md`.

## 7. Платы Go / Mini rev A–F

- `karabas-go-core-msx/src/rtl/karabas_{go,mini,minig}_top.v`;
- их UCF: PLL, VGA/HDMI, sigma-delta/PCM5102, `MCU_SCK`, `FT_CLK_OUT`;
- `core.json` `boards`, `Makefile` `BOARDS`, `make_core.py`;
- план — `doc/PLAN_BOARDS_GO_MINI.md`.

## 8. Рабочий процесс

- MSC/заливка: `doc/TOOLS_AND_COMMANDS.md`, `doc/WORKFLOW_CAPTURE_AND_CONTROL.md`.
- Всегда проверять `AT+KARABAS=version`, md5 на SD, Timing Score.
- Артефакты — `doc/ARTIFACTS.md`.
- Не добавлять глобальные hotkeys: в Karabas hotkey действует вне OSD.
- Не изобретать транспорт без сравнения с MiSTer/Tang/UnoXT и
  `c64_d64_loader.v`.

## 9. Что не делать без проверки

- Не менять архитектуру F/FL, пока не выяснено поведение firmware
  autoload/eject.
- Не заливать сборки с Timing > 0 как финальные.
- Не считать латчи отладочных квадратов текущим состоянием: они
  сбрасываются только по power-on.
- Не делать stereo SID до освобождения слайсов.
