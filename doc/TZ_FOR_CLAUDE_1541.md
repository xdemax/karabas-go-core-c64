# ТЗ для Claude: почему 1541 не отвечает на Karabas Mini G и что делать

## 0. Контекст

Порт C64 (MiSTer-машина `fpga64_sid_iec`) на **Karabas Mini G**:
XC6SLX25-2 FTG256, 4 МБ SRAM (2 × IS61WV20488, 2M×8, работают как 2M×16),
32 МБ SDRAM, HDMI 720×576@50, OSD, RP2040 (kg_mcu).

Что уже работает:

- видео и BASIC V2 на основном ядре `c64` и запасном `c64u`;
- OSD, HDMI, звук (не тестировался), SRAM;
- **загрузчик D64**: образ из OSD (`Disk 8` → `/c64/*.d64`) заливается в SRAM
  по адресу `0x120000` (подтверждено отладкой: сектор 341, `ready`, `mounted`,
  `img_size=174848`);
- **1541 читает диск**: `dsk_addr`/`dsk_changes` меняются.

**Проблема:** после `LOAD"$",8` C64 висит на `SEARCHING FOR $` — 1541 не
отвечает по IEC. Это единственный незакрытый барьер по диску.

---

## 1. Архитектура памяти и видео (важно)

Главное отличие от оригинального UnoXT:

- **UnoXT `c64_zxt.vhd`:** 64 КБ C64 RAM — в **BRAM** (`gen_ram`), внешняя SRAM
  отдана диску. `c1541_sd` читает байт D64 **асинхронно** прямо с SRAM:
  `dsk_addr` → `dsk_data_in`, защёлка `ram_do <= dsk_data_in` на `clk32n`.
- **Наш основной `c64`:** 64 КБ C64 RAM, картридж и D64 лежат в **одной
  внешней SRAM** (`c64_memory.v`). Чтение D64 идёт через арбитраж и
  регистрируется, то есть приходит на такт позже, чем 1541 защёлкивает
  `dsk_data_in` на `clk32n` (инверсный клок).

Мы добавили **кэш текущего 256-байтного сектора D64** (`c64_d64_cache.v`):
distributed RAM с асинхронным чтением, наполняется из SRAM через D64-порт
`c64_memory`. 1541 читает кэш, а не SRAM напрямую.

---

## 2. code: ключевые места

### 2.1 `c64_machine.v` (основное)

```verilog
// 1541: старый UnoXT c1541_sd
c1541_sd drive(
    .clk32(clk_sys),
    .clk32n(~clk_sys),        // было clk_sys — исправлено
    .clk_c1541(clk_sys),      // в c1541_sd не используется
    .disk_num(10'd0),

    .iec_atn_i(c64_iec_atn_o),
    .iec_data_i(c64_iec_data_o),
    .iec_clk_i(c64_iec_clk_o),
    .iec_data_o(drive_iec_data_o),
    .iec_clk_o(drive_iec_clk_o),
    .iec_reset_i(reset),

    .dsk_addr(dsk_addr),
    .dsk_data_in(dsk_data_in),   // из кэша
    .dsk_data_out(),
    .dsk_wr(),

    .rom_c1541(1'b0),
    .host_loadrom(host_loadrom)
);

// кэш сектора
c64_d64_cache d64_cache(
    .clk(clk_sys), .reset(reset),
    .dsk_addr(dsk_addr),
    .dsk_data_in(dsk_data_in),
    .mem_addr(d64_mem_addr), .mem_rd(d64_mem_rd),
    .mem_data(d64_mem_data), .mem_ack(d64_mem_ack)
);
```

### 2.2 `c64_d64_cache.v`

```verilog
reg [7:0] cache [0:255];
assign dsk_data_in = cache[dsk_addr[7:0]];   // асинхронное чтение

wire [9:0] sector = dsk_addr[17:8];          // номер 256-байтного сектора
// fill: читает 256 байт из c64_memory D64-порта (mem_rd/mem_ack),
// пишет cache[fill_i]; стартует при смене sector.
```

### 2.3 `c64_memory.v`: D64-порт и host-порт

```verilog
// D64: d_addr[17:0] -> слово 0x120000 + d_addr, младший байт
.d_addr(d64_mem_addr), .d_rd(d64_mem_rd), .d_wr(1'b0),
.d_din(8'd0), .d_dout(d64_mem_data), .d_ack(d64_mem_ack),

// host: загрузчик D64
.h_req(h_req), .h_addr(h_addr), .h_data(h_data), .h_ack(h_ack),
```

Host-порт: level-handshake из `clk_host`; в `clk_sram` 2FF-синхронизация
`h_req`, регистры `h_addr_s/h_data_s`; запись `0x120000 + h_addr` байтом
(`MWR_N=2'b10`), приоритет ниже C64-шины, выше aux.

### 2.4 `c64_d64_loader.v`

Читает образ через `img_sdc` (512-байтные сектора от MCU), 512-байтный `sbuf`,
пишет в SRAM через host-порт. Работает: сектор 341, `ready=1`.

### 2.5 `c1541_sd.vhd` (UnoXT)

Ключевой тайминг чтения диска:

```vhdl
dsk_addr <= ('0' & (start_sector_addr + sector) & floppy_byte_addr);

process(clk32n)
begin
  if rising_edge(clk32n) then
     ram_do       <= dsk_data_in;      -- защёлка на инверсном клоке
     dsk_data_out <= floppy_ram_di;
     dsk_wr       <= floppy_ram_we;
     sd_busy      <= '0';
  end if;
end process;
```

`ram_do` идёт в `c1541_gcr`/`c1541_logic` (T65 6502 + 2×6522 + GCR),
`ram_ready = not sd_busy`.

---

## 3. Что показала отладка

Временный debug-режим (16 полосок, слова раз в секунду):

- `img_size[15:0]` = `0xAB00` (174848) — образ приходит;
- `sector` загрузчика = `0x0155` (341) — образ залит в SRAM;
- `mounted` = 1, `ready` = 1;
- `dsk_addr` и счётчик изменений `dsk_addr` меняются — 1541 **читает** диск;
- C64 при этом висит на `SEARCHING FOR $`.

Значит: загрузчик и кэш работают (по крайней мере, стартуют), 1541 тикает и
обращается к диску, но **не отвечает по IEC**.

---

## 4. Вопросы

1. **Правильно ли кэш отдаёт данные 1541?** `dsk_addr[17:8]` — номер
   256-байтного сектора, `dsk_addr[7:0]` — байт; кэш наполняется из SRAM
   по `0x120000 + (sector<<8) + i`. Верно ли это для `c1541_sd`/`c1541_gcr`
   (их `start_sector_array`/`sector`/`floppy_byte_addr`)?
2. **Тайминг `ram_do <= dsk_data_in` на `clk32n`:** кэш асинхронный, данные
   валидны до фронта. Достаточно ли этого, или `c1541_gcr` ждёт данные
   на конкретном такте/фазе?
3. **`clk32n`:** мы сделали `~clk_sys` (LUT-инвертор), а не PLL-выход 180°.
   Может ли это ломать защёлку/метастабильность? Нужен ли отдельный
   инверсный клок с PLL?
4. **Почему 1541 не отвечает на ATN/`$`?** Может ли быть, что `dsk_data_in`
   не тот (сдвиг/нули), и ROM 1541 не находит сектор и не отвечает? Или
   проблема в IEC-обвязке (мы повторяем схему UnoXT: вход C64 — только выход
   1541, вход 1541 — только выход C64)?
5. **Что проверить в первую очередь** минимальными правками: `act`/`byte_n`/
   `sync_n` 1541, `ram_do`/`dsk_addr`, `iec_data_o`/`clk_o`, `uc1`/`uc3`
   IRQ, ROM `sprom_c1541`?
6. **Стоит ли портировать MiSTer-овскую 1541?** У неё `iec_drive`
   (`c1541_drv`/`c1541_multi`), интерфейс `sd_lba`/`sd_buff`/`sd_ack` +
   ROM `c1541_rom.mif`, поддержка D64/G64/D81/C1581, 2 диска, parallel.
   Для Karabas её надо:
   - портировать SystemVerilog → Verilog-2001/VHDL (ISE 14.7 XST не
     переваривает `always_comb for(int...)`, `typedef enum`, массивы портов);
   - оставить один диск, без C1581/direct GCR/parallel;
   - сделать адаптер `img_sdc` (512-байтные сектора) → `sd_lba`/`sd_buff`
     (кэш секторов в SRAM);
   - подключить ROM (из `sprom_c1541` или конвертировать MIF).
7. **Влезет ли?** Текущая загрузка `c64`: LUT 51% (7 702/15 032),
   **slices 74% (2 783/3 758)**, RAMB16 57% (30/52), DSP 21%.
   Узкое место — слайсы. Однодисковая 1541 без C1581/G64, по оценке,
   должна влезть, но надо мерить. Полная 2-дисковая + C1581, скорее всего,
   не влезет.
8. **Может, проще перенести 1541+загрузчик в `c64u`** (UnoXT-машина, 64 КБ
   RAM в BRAM), где внешняя SRAM свободна и можно повторить асинхронную
   схему оригинала? Или наоборот — это тупик, и нужна MiSTer-овская 1541?

---

## 5. Что просим

1. Диагноз: почему старая 1541 читает `dsk_addr`, но не отвечает C64;
   какие 3–5 проверок/патчей дадут ответ.
2. Оценка и план порта MiSTer `c1541_drv`/`c1541_multi` (однодисковый D64)
   под ISE 14.7 / XC6SLX25: объём работы, подводные камни SV→Verilog,
   интерфейс `sd_lba`/`sd_buff`, ROM, ресурсы.
3. Рекомендация: чинить старую или портировать новую; что делать первым.

---

## 6. Файлы

- `src/rtl/c64_machine.v` — машина, 1541, кэш, загрузчик.
- `src/rtl/c64_memory.v` — SRAM-контроллер, host/D64 порты.
- `src/rtl/c64_d64_loader.v` — загрузка D64 через `img_sdc`.
- `src/rtl/c64_d64_cache.v` — кэш 256-байтного сектора.
- `src/rtl/iec/c1541_sd.vhd`, `c1541_logic.v`, `c1541_gcr.v`,
  `c1541_via6522.vhd`, `sprom_c1541.vhd` — старая 1541 (UnoXT).
- `../C64_MiSTer-master/rtl/iec_drive/` — MiSTer-овская 1541.
- `src/rtl/karabas_minig_top.v` — `img_sdc`, `img_mounted`/`img_size`,
  `FILELOAD_*`.
- `doc/SESSION_2026-11-09.md` — итоги сессии.
- `doc/TOOLS_AND_COMMANDS.md` — сборка/заливка/управление.
