# Артефакты сборок C64

Дата: 2026-11-22. Все файлы — в `doc/artifacts/`.

## Финальная сборка 26111121 (2026-11-11)

- `c64.kg` — все три платы: Go, Mini rev A–F, Mini G.
- md5: `54ae874203cd375b92b100af081d7611`.
- GitHub Release: `https://github.com/xdemax/karabas-go-core-c64/releases/tag/v26111121`.
- Проверено на железе: все три платы, загрузка/видео/звук.
- Go: исправлен `DAC_BCK` (прямой, без инвертирующего ODDR2).

## Тестовая сборка link v2 26111510 (2026-11-15)

- `c64_link2_26111510_e71700a2.kg` — все три платы, `link: 2`,
  `BITSTREAM_LINK2`; нужна прошивка **26111315+**.
- md5: `e71700a26d7a0de12053b2c78c0fdb0a`.
- GitHub Release: `https://github.com/xdemax/karabas-go-core-c64/releases/tag/v26111510`.
- Собрана из рабочего дерева `tape-in` (внешний `TAPE_IN`, без TAP/T64).
- В этой сборке: убран экранный индикатор `T` (остался только `8`),
  на Mini G убран неиспользуемый вход `FT_CLK` (оставлен `FT_CLK_OUT`).
- Ресурсы/тайминг (PAR, ручной `trce` — 0 ошибок):
  - Go: LUT 72%, slices 92%;
  - Mini rev A–F: LUT 86%, slices 98%;
  - Mini G: LUT 85%, slices 98%.
- **На железе не проверена.**
- Предыдущий v1-билд сохранён как
  `c64_link1_26111201_d769542d.kg`, md5 `d769542d4247e4cfd2130f68789b32ec`.

## Тестовая сборка 26112210 (2026-11-22)

- `c64_link2_26112210_0a590fd2.kg` — все три платы, `link: 2`,
  `BITSTREAM_LINK2`; нужна прошивка **26111315+**.
- md5: `0a590fd29d0a56cc3f59a5f6df24c6f5`.
- GitHub Release: `https://github.com/xdemax/karabas-go-core-c64/releases/tag/v26112210`.
- VGA Go: HS сдвинут с `744..816` на `862..934` (back porch 74 такта
  вместо 192), картинка больше не уезжает вправо. HDMI не затронут.
- Остальное как в 26111760: D64 eject fix, плоское меню, Reset в
  `Keyboard mapping`, центр видео.
- Timing 0: Go 73/94%, Mini 86/99%, Mini G 86/99% (LUT/slices).

## Тестовая сборка 26111760 (2026-11-17)

- `c64_link2_26111760_8f97052f.kg` — все три платы, `link: 2`,
  `BITSTREAM_LINK2`; нужна прошивка **26111315+**.
- md5: `8f97052fd9deffeaaa1110946f2cb847`.
- GitHub Release: `https://github.com/xdemax/karabas-go-core-c64/releases/tag/v26111760`.
- D64 eject: `c64_d64_rd` при `img_mounted[0]=0` отдаёт `0xFF` и не
  читает SRAM; `host_loadrom` пульсирует как disk change. Старый образ
  после `Del` больше не загружается.
- Остальное как в 26111750: Reset в `Keyboard mapping`, плоское меню,
  центр видео.
- Timing 0: Go 73/93%, Mini 86/99%, Mini G 87/99% (LUT/slices).

## Тестовая сборка 26111750 (2026-11-17)

- `c64_link2_26111750_2f30b5bf.kg` — все три платы, `link: 2`,
  `BITSTREAM_LINK2`; нужна прошивка **26111315+**.
- md5: `2f30b5bf5653c0436531344c7280f8d4`.
- GitHub Release: `https://github.com/xdemax/karabas-go-core-c64/releases/tag/v26111750`.
- OSD: `Reset` (T, F12) перенесён со главной страницы в `Keyboard mapping`;
  индекс 0 сохранён, F12 работает глобально.
- Главная: `Disk 8`, `PRG`, `CRT`, `C64 KERNAL`, `1541 ROM`,
  `Joystick swap`, `Keyboard mapping`.

## Тестовая сборка 26111740 (2026-11-17)

- `c64_link2_26111740_dd379351.kg` — все три платы, `link: 2`,
  `BITSTREAM_LINK2`; нужна прошивка **26111315+**.
- md5: `dd3793514600d54466d9896ce0d99d1d`.
- GitHub Release: `https://github.com/xdemax/karabas-go-core-c64/releases/tag/v26111740`.
- Хотфикс: `Reset` (T) получил явный `"index": 0`. После переноса вниз
  меню он получал индекс по позиции (10), а `kg_mcu2` с `SW_N=2` его
  игнорировал — F12 не сбрасывал C64.
- Остальное как в 26111730: плоское меню, `Keyboard mapping`, центр видео.

## Тестовая сборка 26111730 (2026-11-17)

- `c64_link2_26111730_b7ccbbc0.kg` — все три платы, `link: 2`,
  `BITSTREAM_LINK2`; нужна прошивка **26111315+**.
- md5: `b7ccbbc0f13a59816cd97a17a537b169`.
- GitHub Release: `https://github.com/xdemax/karabas-go-core-c64/releases/tag/v26111730`.
- OSD: плоское меню в корне; пункты `Disk 8`, `PRG`, `CRT`, `C64 KERNAL`,
  `1541 ROM`, `Joystick swap`, `Keyboard mapping`, `Reset` (внизу).
  `About` и титры убраны.
- `Keyboard mapping`: направление C64 → PC, ровные колонки, OSD hotkeys
  отдельным блоком.
- Видео: 640×400 по центру, бордюр заполняет кадр, чёрных полос нет.
- Timing 0: Go 72/91%, Mini 86/99%, Mini G 85/99% (LUT/slices).

## Тестовая сборка 26111640 (2026-11-16)

- `c64_link2_26111640_d8c66958.kg` — все три платы, `link: 2`,
  `BITSTREAM_LINK2`; нужна прошивка **26111315+**.
- md5: `d8c6695857a7c176fa32da74c8783445`.
- GitHub Release: `https://github.com/xdemax/karabas-go-core-c64/releases/tag/v26111640`.
- Видео: `V_CONTENT=576`, `V_OFFSET=0`, `SRC_LINE0=18`, `SRC_X0=11`;
  активная область 640×400 отцентрована, чёрных полос нет.
- OSD: `About` и лишние титры убраны; главная — только Reset, Drives,
  System.
- Ресурсы/тайминг (PAR, ручной `trce` — 0 ошибок):
  - Go: LUT 72%, slices 91%;
  - Mini rev A–F: LUT 86%, slices 99%;
  - Mini G: LUT 85%, slices 99%.
- **На железе не проверена.**
- Документация: `doc/ARCHITECTURE.md` (полное описание по модулям).

## Текущее состояние (2026-11-11)

| Файл | md5 | Что |
|---|---|---|
| `c64_crt_f_filter_529fe67b.kg` | `529fe67b6cf539691e17fc6ef5ea0d2a` | F-CRT + секторный буфер + фильтр eject; FAST, **Timing 2866** (тестовый, не финал) |
| `c64_src_crtf_filter_2026-11-11.tar.gz` | `155e8ad73b57d6e9bab4a9c4bfc7773c` | исходники этого состояния (`src/rtl`, `core.json`, prj/ucf/xst/ut) |
| `c64_docs_2026-11-11.tar.gz` | `12d317651c6f792cdc123113feac294b` | снимок README и `doc/*.md` на 2026-11-11 |

## Ключевые рабочие артефакты

| Файл | md5 | Что проверено |
|---|---|---|
| `c64_prg_direct_8104825d.kg` | `8104825df759039622d10eecd13d9708` | PRG FL: `hello.prg` → `HELLO` |
| `c64_disk8_matrix_54bd03ca.kg` | `54bd03caa70d6d1fbc4639a6a9127636` | диск `8` + аудио-пики на матрицы |
| `c64_2x_nearfull_48db6feb.kg` | `48db6feb45f37594b3ca10664621c8f0` | принятая геометрия 2× near-full |
| `c64_sid_working_882e0e65.kg` | `882e0e6554337a4e27ab6788321238ac` | первый рабочий SID после фикса `cs` |
| `c64_diskled_3d715327.kg` | `3d715327e57ffb67cdf0ebbc7a60944f` | индикатор диска |

## Все сохранённые `.kg`

| Файл | md5 |
|---|---|
| `c64_rom_img_slots_0dd5b21c.kg` | `0dd5b21ce732ddbfd1b8844ff732922a` |
| `c64u_unoxt_testprog.kg` | `1f0108c027e532f45925a12ce9a68b99` |
| `c64_videotest_20ad2777.kg` | `20ad2777df54009a6200d26da040898c` |
| `c64_videotest_black_27d7ee64.kg` | `27d7ee64cc0881f4788730c68bc9e6fa` |
| `c64_main_test_dbg1111.kg` | `2eb767fc9185a0d3ed92713a0570217e` |
| `c64_tang_1008x624_osdcentered_3c3dad2c.kg` | `3c3dad2cd92e161b39dbc8518f375294` |
| `c64_video43_404a1e67.kg` | `404a1e67088be5ec4577557b98a43e8d` |
| `c64_2x_50450a10.kg` | `50450a100b7eaa4479cf81b90cca273b` |
| `c64_crt_f_filter_529fe67b.kg` | `529fe67b6cf539691e17fc6ef5ea0d2a` |
| `c64_disk8_matrix_54bd03ca.kg` | `54bd03caa70d6d1fbc4639a6a9127636` |
| `c64_rom_auto_reset_8k1541_55d12792.kg` | `55d12792fab34cd24bde2afd0cbf9f51` |
| `c64_tang_1008x624_5d1aaa61.kg` | `5d1aaa614e4d2055ab34e2f0a5ee0744` |
| `c64_prg_direct_8104825d.kg` | `8104825df759039622d10eecd13d9708` |
| `c64_sid_working_882e0e65.kg` | `882e0e6554337a4e27ab6788321238ac` |
| `c64_2x_x31_95c96776.kg` | `95c96776107ca734b749cfdb82159d92` |
| `c64_2x_x44_98901ad8.kg` | `98901ad857ae1a06f03b211959fed0de` |
| `c64_freevideo_9fdc1aa1.kg` | `9fdc1aa162d57e16614cee3d9b91b5d4` |
| `c64_video43_linefixed_af8bbe08.kg` | `af8bbe0842a5fae1bf5e197344ac841e` |
| `c64_noClamp_ced77f30.kg` | `ced77f30699569e5ab0ff847a7490fa6` |
| `c64_720x576_4x3content_e59f75e2.kg` | `e59f75e281a484ee5cc5bfe2475383a9` |
| `c64_video43_full576_faf7c7c6.kg` | `faf7c7c6ba562742e54fd28e11976a2c` |
| `c64_diskled_3d715327.kg` | `3d715327e57ffb67cdf0ebbc7a60944f` |

Артефакты — тестовые; финальным считается только билд с Timing 0,
проверенный на железе.
