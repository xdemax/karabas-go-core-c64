# Karabas Go, Mini rev A–F и Mini G — порт C64

Дата: 2026-11-11. Ядро собирается для трёх плат одним `c64.kg`; firmware выбирает
битстрим по `HW_ID`.

## 1. Общая часть

`c64_machine.v`, `c64_memory.v`, загрузчики PRG/CRT/TAP/D64 и SID от платы не
зависят. Отличаются только верхние обёртки:

| Плата | Top | Видео | Аудио | MCU_SCK |
|---|---|---|---|---|
| `go` | `karabas_go_top.v` | VGA 8:8:8 + `V_CLK` | PCM5102 | не на клок-пине, `BURST_MAX_MHZ(0)` |
| `mini` | `karabas_mini_top.v` | HDMI + FT812 | sigma-delta `AUDIO_L/R` | не на клок-пине, `BURST_MAX_MHZ(0)` |
| `minig` | `karabas_minig_top.v` | HDMI + FT812 | PCM5102 I2S | IBUFG + BUFG, bursts 16 MHz |

Mini rev A–F использует UCF «rev.C»; отдельные битстримы по ревизиям не нужны.
`FT_CLK_OUT` на Mini — E7 (бывший `MCU_IO<4>`), поэтому `MCU_IO` там 4 бита.

## 2. Видео и клоки

- Mini / Mini G: HDMI, точный PAL 1008×624 при 31.25 МГц; на Mini G кадровый
  клок идёт в DCM HDMI, на Mini — так же, но без PCM5102.
- Go: тот же кадр 1008×624 при 31.25 МГц на VGA DAC, `V_CLK` через `ODDR2`;
  HS/VS инвертированы для монитора. Монитор должен принимать 720×576 @ 50 Гц.
- PLL у всех: VCO 1000 МГц, `clk_sys` 31.25, `clk_host` 25, `clk_sram` 62.5.
  На Go `clk_vid` = 31.25 МГц (VGA), на Mini/Mini G — 31.25 МГц (HDMI).

Аудио:

- Go: PCM5102 на `clk_sys`; `DAC_BCK` идёт **напрямую** из `kg_pcm5102`.
  Инвертирующий `ODDR2`, как на Mini G, на Go давал тишину — проверено на
  железе. `DAC_MUTE=1`.
- Mini G: PCM5102, `DAC_BCK` через инвертирующий `ODDR2` — проверено.
- Mini: два `kg_sigma_delta_dac` на `AUDIO_L/R`, `clk_sys` — проверено.

## 3. Ресурсы

| Плата | LUT | Слайсы | RAMB16 | Timing |
|---|---:|---:|---:|---:|
| `go` | 10 805 (71%) | 3 501 (93%) | 42 | 0 |
| `mini` | 13 458 (89%) | 3 712 (98%) | 42 | 0 |
| `minig` | 12 710 (84%) | 3 733 (99%) | 42 | 0 |

Mini требует `-global_opt speed`: без него остаются пути `clk_sys -> clk_sram`
по адресу SRAM с недобором ~32 ps. Это уже прописано в `MAP_OPT_mini` в
`src/Makefile`.

## 4. Сборка

```sh
cd src
make go          # karabas_go.bin
make mini        # karabas_mini.bin
make minig       # karabas_minig.bin
make all         # все три битстрима в одном c64.kg
make go-report
```

`core.json`:

```json
"boards": {
    "go":    {"bitstream": "karabas_go.bin"},
    "mini":  {"bitstream": "karabas_mini.bin"},
    "minig": {"bitstream": "karabas_minig.bin"}
}
```

`make_core.py ... --boards go,mini,minig` кладёт три битстрима в один `c64.kg`;
firmware выбирает нужный по `HW_ID`.

## 5. Проверка

- Все три платы проверены на железе: загрузка, видео и звук работают.
- Go: после перехода на прямой `DAC_BCK` звук появился; сборка `26111121`.
- Mini: sigma-delta `AUDIO_L/R`; Mini G: PCM5102 + CRT/TAP/индикаторы.

## 6. Осталось

1. D64 write (нужны свободные слайсы; у Go запас больше, у Mini/Mini G ~1–2%).
2. TAP write: нужен предсозданный пустой файл или поддержка в firmware.
3. Свист SID после демо на Mini G (проверить, поведение демо или 8580-фильтр).
