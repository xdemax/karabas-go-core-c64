# Артефакты сборок C64

Дата: 2026-11-11. Все файлы — в `doc/artifacts/`.

## Текущее состояние (2026-11-11)

| Файл | md5 | Что |
|---|---|---|
| `c64_crt_f_filter_529fe67b.kg` | `529fe67b6cf539691e17fc6ef5ea0d2a` | F-CRT + секторный буфер + фильтр eject; FAST, **Timing 2866** (тестовый, не финал) |
| `c64_src_crtf_filter_2026-11-11.tar.gz` | `155e8ad73b57d6e9bab4a9c4bfc7773c` | исходники этого состояния (`src/rtl`, `core.json`, prj/ucf/xst/ut) |
| `c64_docs_2026-11-11.tar.gz` | `12d317651c6f792cdc123113feac294b` | снимок README и `doc/*.md` на 2026-11-11 |

**Важно:** последний **залитый** на плату билд — `a554b01b` (F-CRT, eject
напрямую, Timing 148). Он не содержит eject-фильтра и отдельным артефактом
не сохранён; сохранённый `529fe67b` — более новый исходник с фильтром, но
Timing 2866. После получения Timing 0 нужно сохранить финальный `.kg`.

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
