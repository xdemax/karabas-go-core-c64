# Рабочий процесс: управление Karabas, OBS-скриншоты и обновление ядра

Дата: 2026-11-08. Обновлено после портирования ядра C64.

Документ описывает **общий** процесс для **любого ядра** Karabas Go / Mini / Mini G.
В примерах ниже `c64` — это id и имя файла текущего ядра; для другого ядра
замените `c64` на его id, а `c64.kg` — на имя его `.kg`. Всё остальное
(serial, OBS, MSC, boot menu) работает одинаково для всех ядер.

> Обновление 2026-11-08 (сессия C64):
> * Захват может «зависнуть»: OBS показывает чёрный кадр с красной рамкой,
>   хотя ядро живо. Проверка — открыть OSD (`key:menu+esc`); если OSD виден,
>   захват и HDMI живы.
> * Надёжнее делать **полноэкранный** снимок `spectacle -f` и смотреть
>   OBS-превью на нём, чем `spectacle -a`: активным окном может быть терминал
>   или мессенджер.
> * OSD ядра открывается **только** `key:menu+esc` (не просто `key:menu`).
> * В boot menu пункты идут списком; для C64-теста было:
>   `1 Boot Menu`, `2 C64 UnoXT test`, `3 Commodore 64`.
>   Выбор: `key:down` нужное число раз, затем `key:enter`.

---

## 1. Главное правило

Не путать три разные вещи:

1. **`.kg` лежит на SD** — это ещё не значит, что он загружен в FPGA.
2. **`/config/<core.id>.ini`** — настройки конкретного ядра (ROM, loader,
   параметры), а не выбор ядра.
3. **`AT+KARABAS=version`** — показывает, какое ядро реально запущено
   прошивкой. Это первая проверка перед любыми выводами о картинке.

Если `version` показывает `boot`, то на экране boot menu, а не ваше ядро.
Все наблюдения о цветах/полосах в этот момент относятся к boot menu.

---

## 2. Serial-доступ

Устройство: `/dev/ttyACM0`, 115200, 8N1, raw, без flow control.
Пользователь должен иметь доступ к устройству (ACL/группа `uucp`).

В этом репозитории есть готовый помощник:

```sh
cd <repo>
python3 tools/karabas.py 'AT+KARABAS=version'
python3 tools/karabas.py 'AT+KARABAS=list'
```

`tools/karabas.py` открывает порт, шлёт одну команду и печатает ответ.
Для другого ядра/репозитория скрипт можно скопировать без изменений.

### 2.1. Проверить, что реально запущено

```sh
python3 tools/karabas.py 'AT+KARABAS=version'
```

Ответ:

```text
+KARABAS:<firmware_build>;<HW_ID>;<core.id>;<core.build>
OK
```

`HW_ID`: `1` — Go, `2` — Mini, `3` — Mini G.
Пример для текущего C64 на Mini G:

```text
+KARABAS:26110520;3;c64;26110802
```

### 2.2. Список установленных ядер

```sh
python3 tools/karabas.py 'AT+KARABAS=list'
```

Пример:

```text
+KARABAS:c64.kg;c64;Commodore 64;26110802
+KARABAS:boot.kg;boot;Boot Menu;26110116
OK
```

`boot.kg` — это boot menu, а не рабочее ядро.

### 2.3. Клавиши и OSD

Формат:

```text
AT+KARABAS=key:<key>
```

Работает для всех ядер:

| Команда | Действие |
|---|---|
| `AT+KARABAS=key:menu+esc` | открыть/закрыть OSD ядра |
| `AT+KARABAS=key:esc` | закрыть OSD / назад |
| `AT+KARABAS=key:f12` | Reset, если ядро назначило F12 |
| `AT+KARABAS=key:up` / `down` / `left` / `right` | навигация в OSD/boot menu |
| `AT+KARABAS=key:enter` | выбрать пункт |
| `AT+KARABAS=type:HELLO` | ввести текст (если ядро принимает клавиатуру) |
| `AT+KARABAS=hold:<key>` / `AT+KARABAS=release` | удержать/отпустить |

Важно: **`key:menu` без `+esc` не открывает OSD ядра**. Для OSD нужен
`menu+esc`. `key:menu` сам по себе использовался только для boot menu.

Пример открытия OSD и проверки, что оверлей ядра работает:

```sh
python3 tools/karabas.py 'AT+KARABAS=key:menu+esc'
sleep 1
spectacle -a -b -n -o docs/captures/osd.png
```

---

## 3. OBS: скриншот экрана платы

Источник истины — превью OBS (USB UVC-граббер), а не `v4l2 --query-dv-timings`.
У UVC-граббера тайминги могут быть `0x0` даже при наличии картинки.

### 3.1. Быстрый и надёжный способ: полноэкранный снимок

Так как на машине может быть активно другое окно (терминал, мессенджер),
самый надёжный способ — снять **весь экран** и посмотреть OBS-превью на нём:

```sh
mkdir -p <repo>/docs/captures
spectacle -f -b -n -o <repo>/docs/captures/current.png
```

Затем открыть PNG глазами. Если OBS виден на снимке — смотрим его превью.
Если OBS свернут/закрыт другим окном — используйте активацию ниже.

### 3.2. Снимок именно окна OBS

Если окно OBS активно:

```sh
spectacle -a -b -n -o <repo>/docs/captures/current.png
```

Если снимается терминал/мессенджер, активировать OBS скриптом KWin:

```sh
qdbus6 org.kde.KWin /Scripting \
  org.kde.kwin.Scripting.loadScript \
  <repo>/tools/activate_obs.js
qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.start
sleep 1
spectacle -a -b -n -o <repo>/docs/captures/current.png
```

Если OBS свернут, `activate_obs.js` может не развернуть его. Тогда:

```sh
qdbus6 org.kde.KWin /Scripting \
  org.kde.kwin.Scripting.loadScript \
  <repo>/tools/activate_obs_unmin.js
qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.start
sleep 1
spectacle -f -b -n -o <repo>/docs/captures/current.png
```

`activate_obs_unmin.js` ищет окно с `obs` в заголовке, снимает `minimized`
и делает его активным. `activate_obs_all.js` дополнительно сворачивает
остальные окна.

Если и это не сработало — просто переключитесь на окно OBS вручную и снова
сделайте `spectacle -a` или `-f`.

### 3.3. Если картинка чёрная

Не делать вывод «ядро не работает» по чёрному кадру, пока не проверен OSD:

```sh
python3 tools/karabas.py 'AT+KARABAS=key:menu+esc'
sleep 1
spectacle -f -b -n -o <repo>/docs/captures/osd_check.png
```

Если OSD виден — HDMI, PLL и видео-выход живы; чёрный кадр относится
к конкретному ядру/видео-пайплайну. Если OSD не виден — проверить захват
(перезапустить OBS/граббер) и питание платы.

### 3.3. Где хранить

`/tmp` очищается. Складывайте снимки в:

```text
<repo>/docs/captures/
```

---

## 4. Обновление `.kg` на SD через MSC

Это работает для любого ядра. Пример для `c64.kg`.

### 4.1. Перевести плату в MSC

```sh
python3 tools/karabas.py 'AT+KARABAS=msc'
```

Плата перезагрузится в режим USB-накопителя. `/dev/ttyACM0` может исчезнуть.

### 4.2. Дождаться SD и смонтировать

```sh
for i in $(seq 1 30); do
  sz=$(cat /sys/block/sdb/size 2>/dev/null || echo 0)
  [ "$sz" != "0" ] && break
  sleep 1
done
udisksctl mount -b /dev/sdb1
```

Обычно точка монтирования: `/run/media/demo/CORES`.
Если `udisksctl mount` не сработал, проверьте `lsblk` и смонтируйте вручную.

### 4.3. Скопировать ядро

```sh
cp <repo>/src/c64.kg /run/media/demo/CORES/c64.kg
sync
md5sum <repo>/src/c64.kg /run/media/demo/CORES/c64.kg
```

### 4.4. Размонтировать и извлечь

```sh
udisksctl unmount -b /dev/sdb1
drive=$(udisksctl info -b /dev/sdb \
  | sed -n "s/.*Drive: *'\([^']*\)'.*/\1/p" | head -1)
gdbus call --system --dest org.freedesktop.UDisks2 \
  --object-path "$drive" \
  --method org.freedesktop.UDisks2.Drive.Eject '{}'
```

После eject плата снова загрузится в **boot menu**.

### 4.5. Выбрать ядро

Проверить, что запущено:

```sh
python3 tools/karabas.py 'AT+KARABAS=version'
```

Если `boot`, открыть/выбрать пункт boot menu:

```sh
python3 tools/karabas.py 'AT+KARABAS=key:down'
python3 tools/karabas.py 'AT+KARABAS=key:enter'
python3 tools/karabas.py 'AT+KARABAS=version'
```

В boot menu пункты идут списком; для вашего ядра может понадобиться
несколько `up`/`down`. После `enter` снова проверьте `version`: там должен
быть id вашего ядра, а не `boot`.

---

## 5. Конфиги ядра

Файл:

```text
/config/<core.id>.ini
```

Пример для C64:

```text
/config/c64.ini
```

Содержимое (пример):

```ini
[loader]
file=/c64/game.prg

[core]
build=26110802
```

`/config/<id>.ini` — это **не** глобальный выбор ядра. Для ядра `c64`
нужен `c64.ini`; для `sega_t4status7` — `sega_t4status7.ini`.
`.kg` также содержит `loader`/`filename`, но авто-загрузка через него/ini
работала не всегда; после смены ядра проверяйте, что файл действительно
загрузился, по поведению ядра.

---

## 6. Быстрый чек-лист (для любого ядра)

```sh
# 0. id и имя файла текущего ядра
#    C64: id=c64, file=c64.kg
#    Sega: id=sega_t4status7, file=sega_t4status7.kg

# 1. Кто реально запущен
python3 tools/karabas.py 'AT+KARABAS=version'

# 2. Если boot — выбрать ядро
python3 tools/karabas.py 'AT+KARABAS=key:down'
python3 tools/karabas.py 'AT+KARABAS=key:enter'
python3 tools/karabas.py 'AT+KARABAS=version'

# 3. Открыть OSD ядра (проверка видео/оверлея)
python3 tools/karabas.py 'AT+KARABAS=key:menu+esc'
sleep 1
spectacle -a -b -n -o docs/captures/osd.png
# посмотреть PNG глазами

# 4. Закрыть OSD
python3 tools/karabas.py 'AT+KARABAS=key:esc'

# 5. Обновить ядро
python3 tools/karabas.py 'AT+KARABAS=msc'
# дождаться /dev/sdb, смонтировать, скопировать .kg, sync, unmount, eject
# затем снова выбрать ядро из boot menu
```

---

## 7. Уроки, которые нельзя повторять

1. Не делать вывод о ядре по списку файлов на SD — только по
   `AT+KARABAS=version`.
2. Не править `sega.ini`/`c64.ini` и думать, что это выбор ядра: конфиг
   привязан к id.
3. Не считать `v4l2 --query-dv-timings = 0` доказательством отсутствия
   сигнала.
4. Не снимать OBS, не убедившись, что активно именно окно OBS: иначе
   получится терминал/мессенджер.
5. Не хранить единственные скриншоты/скрипты в `/tmp`.
6. Перед выводами о ядре проверять, что HDMI стабилен и capture показывает
   именно плату.
7. `key:menu` — это не OSD ядра; OSD открывается `key:menu+esc`.
8. После MSC плата снова в `boot`; ядро надо выбрать заново.
9. Если `.kg` не копируется, проверьте, что `/dev/sdb1` действительно
   смонтирован (иногда `/run/media/demo/CORES` ещё не существует).

---

## 8. Текущее состояние C64 (пример применения документа)

- Основное ядро: `c64.kg`, id `c64`, сборка `26110802`.
- Контрольное: `c64u.kg`, id `c64u` (UnoXT-машина, 64 КБ RAM в BRAM).
- Плата: Karabas Mini G, `HW_ID=3`.
- Видео: `c64video.v` — 4 строки BRAM, genlock по кадру VIC, 720×576@50;
  внешняя SRAM под видео не используется.
- **BASIC V2 грузится**, OSD (`Menu+Esc`) работает, картинка стабильна.
- **D64, KERNAL/1541 ROM, PRG (`FL`) работают.** PRG загружается и сам
  выполняет `RUN`+Enter.
- **CRT (`F`, slot 5)** загружается в SRAM и доходит до `cart_id`, но
  игры пока не стартуют: ложный eject при F-монтировании (фильтр в
  исходнике, не залит), затем маппер Ocean Type 1 / EasyFlash. Детали —
  `doc/STATUS_2026-11-11.md`.
- `type:` в C64 набирает текст посимвольно с паузами: KERNAL опрашивает
  клавиатуру ~60 раз/с, пакет символов теряется.
