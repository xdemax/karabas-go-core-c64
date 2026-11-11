# C64 на Karabas Mini G: помоги найти, куда копать (порт MiSTer + контрольный UnoXT)

## 0. Что мне нужно от тебя

Ниже — полное состояние порта C64 на плату Karabas Mini G. Нужен разбор: **почему KERNAL не доводит до включения экрана (BASIC не появляется), хотя CPU/ROM/VIC и видео-путь работают**. Интересуют конкретные гипотезы, порядок проверки и минимальные правки/эксперименты. Можно отвечать по-английски, код — как удобно.

---

## 1. Железо и общая картина

- Плата: **Karabas Mini G**, FPGA **Xilinx Spartan-6 XC6SLX25-2 FTG256**, HDMI 720x576@50, I2S DAC, OSD, RP2040 (kg_mcu).
- SRAM: 2 × IS61WV20488BLL-10TLI (2M × 8, 10 нс), вместе 2M × 16 = 4 МБ, `MA[20:0]`, `MD[15:0]`, побайтовые `MWR_N`/`MRD_N`.
- SDRAM 32 МБ — пока не используется.
- Прошивка платы: build `26110520`, `HW_ID=3` (Mini G).

Портируются два варианта одной и той же C64-машины:

1. **Основной порт** — MiSTer `fpga64_sid_iec` (T65 6510, VIC-II 656x, 2×CIA 6526, SID), плюс `cartridge.v`, `c1541_sd`, наш SRAM-контроллер `c64_memory.v`, наш видео-захват `c64_video.v`.
   Репозиторий: `karabas-go-core-c64/`, ядро `c64.kg`, `core.id = c64`.
2. **Контрольный UnoXT-порт** — старый UnoXT `fpga64_sid_iec` (тот же Peter Wendrich, но старая ревизия: `resetCycles=4095`, `ramDataIn/Out`, `irq_n/nmi_n inout`, 8-битный `ps2_key`, `idle`, `dma_n`, `CPU_hasbus`), 64 КБ C64 RAM в BRAM (`gen_ram`, как в оригинальном `c64_zxt.vhd`), наша SRAM — только под кадровый буфер. Тот же `c64_video.v`.
   Репозиторий: `karabas-go-core-c64-unoxt-test/`, ядро `c64u.kg`, `core.id = c64u`.

Оригинальный референс: `unoxt-c64-core-main/` (`c64_zxt.vhd`, `fpga64_sid_iec.vhd`, `video_vicII_656x.vhd`, `fpga64_rgbcolor.vhd`, `video_sync.vhd`, `gen_ram.vhd`). ROM-ы взяты оттуда: `rom_c64_basic.vhd`, `rom_c64_kernal.vhd`, `rom_c64_chargen.vhd`; векторы стандартные (`$FFFA=$FE43`, `$FFFC=$FCE2`, `$FFFE=$FF48`).

---

## 2. Тактирование, сброс, память

```
clk_sys  = 31.25 МГц (VCO 1000 / 32)  — C64-машина, фаза 0 SRAM-контроллера
clk_sram = 62.5 МГц  (VCO 1000 / 16)  — SRAM-контроллер (phase 0/1)
clk_vid  = 27.027 МГц (VCO 1000 / 37) — HDMI-пиксель и чтение кадрового буфера
clk_host = 25 МГц
```

Номинал fpga64/UnoXT — 32 МГц, у нас **31.25 МГц (−2.3 %)**.

Сброс:

```verilog
// karabas_minig_top.v
wire areset = ~locked;                 // PLL lock
wire c64_reset = ~locked;              // UnoXT-топ
// в MiSTer-топе: c64_reset = ~locked | softsw[0] | hw_btn[0];
```

В MiSTer-ядре `fpga64_sid_iec` внутренний reset снимается примерно через один системный цикл. В старом UnoXT-ядре есть generic `resetCycles=4095`, он используется. В **оригинальном** `c64_zxt.vhd` после PLL lock ещё держится `reset_counter` = 10 000 000 тактов (~0.3 с):

```vhdl
if pll_locked = '0' then
    reset_counter <= 10000000; reset_n <= '0';
elsif reset_key = '1' or rom_reset = '1' or BTN = '0' or host_reset_n = '0' then
    reset_counter <= 255; reset_n <= '0';
else
    if reset_counter = 0 then reset_n <= '1';
    else reset_counter <= reset_counter - 1; end if;
end if;
```

SRAM-контроллер (актуальная версия, важнее того, что в старых audit-документах): каждый доступ — целый `clk_sys` и обе фазы `clk_sram`:
- phase 0: выставить адрес (и данные/WE при записи);
- phase 1: держать адрес/данные, снять WE, оставить OE;
- следующий phase 0: сэмплировать `MD` (адрес стабилен ~32 нс > pad + tAA(~21 нс)).

C64/картридж имеет приоритет, вспомогательный порт (D64/видео) обслуживается в свободные циклы, запросы держатся до `ack` (`vr_ack`, `d_ack`). C64 RAM/картридж/D64 — 1 байт на 16-битное слово (младший байт), видео — полные 16-битные слова.

Карта SRAM (словные адреса, 21 бит): C64 RAM `0x000000`, cart RAM `0x010000`, cart ROM `0x020000..0x11FFFF`, D64 `0x120000`, кадры `0x160000`/`0x1A0000`.

**В UnoXT-сборке C64-порт SRAM не используется вообще** (`c_ce=0`), 64 КБ RAM — в BRAM.

---

## 3. Видео-путь (`c64_video.v`, общий для обеих сборок)

`c64_video` ловит VIC в кадровый буфер 504×312 (16-битные слова в SRAM), затем строчный буфер и вывод 720x576@50.

Ключевой кусок захвата:

```verilog
wire hsync_c, vsync_c, hblank_c, vblank_c;
video_sync vic_sync(
    .clk32(clk_sys), .pause(pause),
    .hsync(vic_hsync), .vsync(vic_vsync),
    .ntsc(1'b0), .wide(1'b0),
    .hsync_out(hsync_c), .vsync_out(vsync_c),
    .hblank(hblank_c), .vblank(vblank_c)
);

reg prev_hs, prev_vs;
reg [9:0] cap_x; reg [8:0] cap_y;
reg [15:0] pix565;

always @(posedge clk_sys) begin
    pix565 <= dbg_mode ? {...} : {vic_r[7:3], vic_g[7:2], vic_b[7:3]};
    vw_wr <= 1'b0;
    if (reset) ...
    else begin
        prev_hs <= hsync_c;
        prev_vs <= vsync_c;
        if (hsync_c && !prev_hs) begin
            cap_x <= 0;
            if (vsync_c && !prev_vs) cap_y <= 0;
            else if (cap_y != 9'd311)  cap_y <= cap_y + 1;
        end
        else if (vic_pixel_ce && cap_x != 10'd504 && cap_y != 9'd312) begin
            vw_wr   <= 1'b1;
            vw_addr <= {cap_y, cap_x[8:0]};
            vw_data <= pix565;          // NB: nonblocking -> значение pix565 с ПРЕДЫДУЩЕГО такта
            cap_x   <= cap_x + 1;
        end
    end
end
```

Вывод: 720x576, `H_ACTIVE=720`, `H_TOTAL=864`, `V_ACTIVE=576`, `V_TOTAL=625`, `src_line = vc[8:1] + 12`, `sx = x*7/10` (504 → 720). Строчный буфер в BRAM, заполняется из кадрового буфера по `vr_req`/`vr_ack`.

`video_sync` — это MiSTer-версия модуля Dar (с `pause`), у старого UnoXT `video_sync` нет `pause`; логика та же. В обоих VIC'ах (`video_vicII_656x.vhd`) синхра задаётся так:

```vhdl
hSync <= hBlanking;
vSync <= vBlanking;
```

то есть семантика у MiSTer- и UnoXT-VIC одинаковая.

---

## 4. Что уже доказано (не перепроверять без причины)

На **MiSTer-сборке** (до текущего чистого билда):

1. HDMI, PLL, OSD, кадровый буфер, MCU работают; OSD открывается `Menu+Esc`.
2. CPU исполняет код из ROM. KERNAL пропатчен: reset-вектор на `$FF00`, программа:
   ```
   FF00: A9 05        LDA #$05
   FF02: 8D 20 D0     STA $D020      ; border = green
   FF05: A9 00        LDA #$00
   FF07: 8D 21 D0     STA $D021      ; bg = black
   FF0A: A9 1B        LDA #$1B
   FF0C: 8D 11 D0     STA $D011      ; DEN=1
   ```
   Бордюр стал зелёным → CPU/ROM/reset-вектор/VIC-запись работают.
3. RAM-тест `STA $0400` / `LDA $0400` / `CMP #$AA` → зелёный бордюр (SRAM-путь OK для CPU).
4. `$D011` read-back: записали `$1B`, прочитали, маска `$7F`, сравнили → OK.
5. Raster-тест `LDA $D012 / AND #$0F / STA $D020 / JMP` → на экране **зелёное поле + одна синяя полоса внизу**, а не 16 полос. Результат неоднозначный.
6. С debug-выводом адреса CPU (защёлкивание `dbg_addr` по VIC VSYNC) нормальный KERNAL показывал **`$FFE0` каждый кадр**.
7. `dbg_vic="1111"` (4 белые полосы) — экран был чёрным; признано ненадёжным тестом (возможно, `dbg_vic` не доходил до `c64_video`).

**Текущий чистый билд** (без debug-правок, оригинальный KERNAL):
- `c64.kg` — синее/светло-синее ровное поле, BASIC нет;
- `c64u.kg` — до фикса был **чёрный экран**, OSD работал.

---

## 5. Что исправлено только что (важно)

В старой копии `fpga64_sid_iec.vhd` (UnoXT) порт `pixel_ce` был **добавлен в entity, но нигде не назначался**. Внутри ядра есть `enablePixel`; в MiSTer-версии есть строка `pixel_ce <= enablePixel;`, а в UnoXT-копии её не было. `c64_video` пишет пиксели только при `vic_pixel_ce`.

Добавил:

```vhdl
-- Expose the VIC pixel enable to the Karabas frame-buffer capture.
pixel_ce <= enablePixel;
```

После пересборки и заливки **`c64u` перестал быть чёрным** и показывает ровное поле того же типа, что и `c64`.

Пиксельный тайминг старого ядра (совпадает по смыслу с MiSTer):

```vhdl
process(clk32)
begin
  if rising_edge(clk32) then
    enablePixel <= '0';
    if sysCycle = CYCLE_VIC2
    or sysCycle = CYCLE_IDLE3
    or sysCycle = CYCLE_IDLE7
    or sysCycle = CYCLE_IEC2
    or sysCycle = CYCLE_CPU2
    or sysCycle = CYCLE_CPU6
    or sysCycle = CYCLE_CPUB
    or sysCycle = CYCLE_CPUF then
      enablePixel <= '1';
    end if;
  end if;
end process;
```

---

## 6. Текущая улика: похоже, KERNAL стартует, но не включает экран

- В VIC `EC` (бордюр, регистр `$D020`) **сбрасывается в 0** (чёрный). После чистого старта мы видим ровное поле **светло-синего цвета** (в палитре UnoXT цвет 14 = `#6C5EB5`, на захвате ≈ `(106,99,226)`).
- Значит, **CPU успел записать `$D020=14`** (это делает KERNAL в CINT), то есть CPU/ROM/KERNAL точно стартуют и в UnoXT-сборке тоже.
- Но экран не включён: если бы `DEN=1`, мы бы видели два цвета — бордюр 14 и фон 6 (тёмно-синий, `#352879`), плюс пустые знакоместа. Видим **один цвет на всю площадь** → похоже на `DEN=0` (весь экран закрыт бордюром) либо на то, что окно `MainBorder` не открывается.
- В KERNAL значения VIC по умолчанию задаются пачкой (в CINT); `$D020=14` и `$D011=$1B` пишутся в рамках инициализации VIC. Если `$D020` записался, а `DEN` нет — KERNAL, возможно, успевает записать часть регистров и затем зависает/срывается между ними.

---

## 7. Оригинальный `c64_zxt.vhd` vs наш `c64_machine_unoxt.v`

Что у нас совпадает с оригиналом:

```verilog
fpga64_sid_iec #(.resetCycles(4095)) c64 (
    .clk32(clk_sys),
    .reset_n(~reset),
    .ps2_key(kb_scancode),
    .ps2_ok(ps2_ok),          // фронт kb_scancode_upd
    .ramAddr(ram_addr),
    .ramDataIn(ram_din),
    .ramDataOut(ram_dout),
    .ramCE(ram_ce),
    .ramWe(ram_we),
    .tv15Khz_mode(1'b1),
    .ntscInitMode(1'b0),
    .hsync(vic_hs),
    .vsync(vic_vs),
    .pixel_ce(vic_pixel_ce),  // добавлено нами
    .r/g/b(...),
    .game(1'b1), .exrom(1'b1),
    .irq_n(irq_n), .nmi_n(nmi_n),
    .nmi_ack(), .dma_n(1'b1),
    .joyA(joy_a), .joyB(joy_b), .joyC(0), .joyD(0),
    .sid_ver(1'b1), .col_cpc(1'b0),
    .extfilter_en(1'b1),
    ...
);
assign irq_n = 1'b1;
assign nmi_n = 1'b1;
```

BRAM:

```verilog
gen_ram #(.dWidth(8), .aWidth(16)) c64ram(
    .clk(clk_sys),
    .we(~ram_we),
    .addr(ram_addr),
    .d(ram_dout),
    .q(ram_din)
);
```

Оригинал для сравнения:

```vhdl
bram: entity work.gen_ram
    generic map (dWidth => 8, aWidth => 16)
    port map (
        clk => clk32,
        we => not ram_we,
        addr => c64_addr_int,
        d => c64_data_out_int,
        q => c64_data_in_int
    );
```

В старом ядре `irq_n`/`nmi_n` — `inout`, внутри:

```vhdl
irqLoc <= irq_cia1 and irq_vic and irq_n;
nmiLoc <= irq_cia2 and nmi_n;
```

и сам core их драйвит `'1'` (`irq_n <= '1'; nmi_n <= '1';`). Мы снаружи тоже драйвим `1'b1` — оба драйвера в `1`, контеншена нет.

---

## 8. Гипотезы, которые надо проверить/отбросить

1. **DEN реально записывается, но мы не видим экран из-за захвата** (сдвиг окна, неверный `cap_y`, `pix565` на такт позже, несовпадение `enablePixel` и `video_sync`). Тогда «равномерное поле» — артефакт захвата, а машина, возможно, уже в BASIC.
2. **KERNAL зависает после части VIC-инициализации** (успел `$D020`, не успел `$D011`). Причина — что-то общее для обеих сборок: сброс/клок/ROM/IRQ/CIA, а не память.
3. **VIC raster/`MainBorder` не открывается** (например, `rasterEnable` не выставляется или `DEN` приходит не в той фазе), хотя raster-счётчик формально тикает.
4. **Не хватает длинного сброса** как в оригинале (10M тактов) — маловероятно, но проверить дешево.
5. **Частота 31.25 вместо 32 МГц** ломает PAL/NTSC-детект или тайминги KERNAL — маловероятно, но у нас единственное отличие по клоку от референса.
6. **`pix565` сэмплируется на такт раньше/позже**, чем меняется `vic_r/g/b` старого VIC — это может давать сдвиг/мусор, но не равномерный цвет; всё же стоит проверить.

---

## 9. Вопросы

1. Глядя на код захвата и на то, что старый VIC выдаёт `hSync=hBlanking`, `pixel_ce=enablePixel` (8 импульсов на системный цикл): **корректно ли `c64_video` считает 504 пикселя на строку и сбрасывает `cap_y` по `vsync_c`?** Может ли рассинхрон `video_sync`/`enablePixel` давать на выходе ровное поле бордюра даже при работающей машине?
2. `vw_data <= pix565` при `pix565 <= ...` в том же always-блоке — это **сэмплирование на такт раньше**. Для старого VIC это критично? Как правильно (комбинационно, или задержать `pixel_ce` на такт, или брать `vic_r/g/b` напрямую в момент `pixel_ce`)?
3. Если `$D020=14` записался, а `DEN` нет — какие места в KERNAL/ядре могут «съесть» запись `$D011`? Может ли `fpga64_buslogic`/старый `fpga64_sid_iec` терять запись в VIC при определённом тайминге (`pulseWrIo`, `phi0_vic`)?
4. Может ли **короткий сброс** (`~locked` + внутренние 4095) оставить CIA/VIC/6510 в состоянии, где KERNAL зависает? Стоит ли повторить оригинальные 10M тактов?
5. Влияет ли **31.25 МГц вместо 32** на `resetCycles=4095`, PAL-детект (`LDA $D012; BNE`), CIA TOD, VIC raster? Если да — какую частоту лучше дать (31.5279 МГц = PAL×32)?
6. Почему raster-тест `LDA $D012 / AND #$0F / STA $D020` дал зелёное поле + одну синюю полосу вместо 16 полос? Это признак того, что `$D012` почти не меняется или что захват видит не весь кадр?
7. Что даст наибольшую информацию за один билд: вывести в кадр `CPU_hasbus`-счётчик, защёлкнутый адрес CPU, `$D012` (rasterY), или free-running паттерн? Какой минимальный instrumentation ты советуешь?
8. Есть ли известные грабли при переносе именно **старой** UnoXT-ревизии `fpga64_sid_iec` на другой топ (клок 31.25, `gen_ram`, `pixel_ce`, `irq_n/nmi_n inout`), которых нет в MiSTer-ревизии?
9. Может ли проблема быть в **`video_sync` (MiSTer-версия с `pause`)** при подаче на неё `hBlanking/vBlanking` старого VIC — например, из-за полярности/ширины импульсов? Стоит ли попробовать отдельный простой счётчик строк/пикселей без `video_sync`?
10. Если у тебя есть опыт с fpga64: что обычно ломается, когда «бордюр цвета 14 есть, а экрана нет»? Какие 2–3 проверки самые диагностичные?

---

## 10. Что я планирую сделать дальше (поправь, если не то)

1. Пересобрать `c64u` с **KERNAL-тестом** (reset-вектор `$FF00`, программа ставит `$D011=$1B`, `$D020=5`, `$D021=0`) уже **с фиксом `pixel_ce`**. Это покажет, исполняет ли CPU в UnoXT-сборке и работает ли DEN напрямую.
2. Если DEN работает — значит KERNAL зависает; вывести `$D012`/адрес CPU в кадр и искать точку зависания.
3. Если DEN не работает — копать `fpga64_buslogic`/VIC write path и тайминг `pulseWrIo`/`phi0_vic`.
4. Параллельно проверить free-running паттерн в `c64_video` (без VIC) — чтобы окончательно отделить захват от машины.

---

## 11. Файлы/артефакты

- `karabas-go-core-c64/src/rtl/c64_video.v` — общий видео-захват.
- `karabas-go-core-c64/src/rtl/c64_machine.v` — MiSTer-машина.
- `karabas-go-core-c64/src/rtl/c64_memory.v` — SRAM-контроллер (с `vr_ack`/`d_ack`).
- `karabas-go-core-c64-unoxt-test/src/rtl/c64_machine_unoxt.v` — UnoXT-машина.
- `karabas-go-core-c64-unoxt-test/src/rtl/c64/fpga64_sid_iec.vhd` — старый core; здесь добавлен `pixel_ce <= enablePixel;`.
- `karabas-go-core-c64-unoxt-test/src/rtl/c64/` — старые VIC/CIA/CPU/buslogic.
- `unoxt-c64-core-main/src/c64/c64_zxt.vhd` — оригинальный топ.
- `karabas-go-core-c64/doc/SESSION_FINDINGS_C64.md` — итоги предыдущей сессии (частично устарел).
- Скриншоты: `karabas-go-core-c64/docs/captures/` (`fix_c64u_pixelce.png`, `new_c64.png`, `denonly.png`, `rastertest.png`, `dbg1111.png`).
- Текущие `.kg`: `c64.kg` md5 `14941a3e…`, `c64u.kg` md5 `e42e8f89…` (на SD и в репозиториях).
