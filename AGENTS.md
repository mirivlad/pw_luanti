# AGENTS.md — PerfectWorld

Руководство для coding agents (Codex, Hermes и др.), начинающих сессию без контекста.

**Язык общения с пользователем:** русский. Названия API, команд, файлов, сущностей и commit messages оставлять в оригинальной технической форме.

---

## 1. Назначение проекта

PerfectWorld — самостоятельный модпак для Luanti/Mineclonia, создающий процедурный физический мир: регионы, поселения, здания, дороги и фермы.

### Самостоятельность

Проект полностью независим. **Запрещено** переносить игровую логику AliveWorld (events, rumors, chronicle, GPS, tracking, claims, sites, routes, settlement simulation) без отдельного явного решения пользователя.

### Цель

Детерминированная генерация физического мира через Lua mapgen. Мир должен выглядеть так, будто он был построен, а не сгенерирован.

---

## 2. Структура модулей

| Модуль | Путь | depends | Ответственность |
|--------|------|---------|-----------------|
| **pw_core** | `perfectworld/pw_core/` | — | API, settings, world seed, composite IDs, world format lock |
| **pw_compat_mcl** | `perfectworld/pw_compat_mcl/` | pw_core | Mineclonia material compatibility |
| **pw_planner** | `perfectworld/pw_planner/` | pw_core (opt: pw_structures) | Детерминированное планирование, village grammar, validation, materialization |
| **pw_structures** | `perfectworld/pw_structures/` | pw_core (opt: pw_compat_mcl) | Registry, terrain prep, rotation, placement |
| **pw_roads** | `perfectworld/pw_roads/` | pw_core, pw_planner | Road network API |
| **pw_settlements** | `perfectworld/pw_settlements/` | pw_core | Settlement type definitions (skeleton) |
| **pw_population** | `perfectworld/pw_population/` | pw_core | Population API (skeleton) |
| **pw_debug** | `perfectworld/pw_debug/` | pw_core (opt: pw_planner, pw_structures) | Debug commands, screenshot system |
| **pw_bot_bridge** | `perfectworld/pw_bot_bridge/` | pw_core (opt: pw_compat_mcl, pw_planner, pw_structures, pw_roads, pw_settlements, luanti_testkit) | Серверное восприятие мира для будущего PW Bot: режимы `player`/`oracle`, protocol `pw_bot_bridge/v1` |
| **pw_tests** | `perfectworld/pw_tests/` | luanti_testkit, pw_* | TestKit-based tests |
| **luanti_testkit** | `luanti_testkit/` | — | Universal server-side test framework |
| **pw_remote_control** | `pw_remote_control/` | — | JSON remote control |

---

## 3. Запуск и тестирование

### Установка и сборка

```bash
python3 scripts/install-content.py
./scripts/sync-local-mods.sh
docker compose build
```

### Server mode (с `--terminal`)

```bash
docker compose up -d
# Ждать: grep -q "Server for gameid=.*listening" data/debug.txt
docker compose down
```

### Test mode (без `--terminal`, логи в `debug-test.txt`)

```bash
docker compose -f docker-compose.yml -f docker-compose.test.yml up -d
```

### Ожидание готовности

```bash
timeout 90 sh -c 'while :; do grep -q "Server for gameid=.*listening" data/debug-test.txt && exit 0; sleep 2; done'
```

### Тестовый игрок (`pwbot`)

```bash
# Пароль
cp secrets/pwbot.password.example secrets/pwbot.password
# Отредактировать файл

# Запуск клиента
./scripts/run-test-client.sh
# или:
xvfb-run --auto-servernum luanti --go --address 127.0.0.1 --port 30000 \
  --name pwbot --password-file secrets/pwbot.password >> logs/test-client.log 2>&1 &
```

### Запуск тестов

Полный цикл одной командой (сервер, pwbot, привилегии, запуск, отчёт):

```bash
scripts/run-testkit.sh
```

Флаги: `--keep` (использовать уже запущенный сервер), `--no-client`
(не запускать pwbot).

Вручную:

```bash
docker exec perfectworld-dev sh -c 'echo "/grant pwbot all" > /proc/1/fd/0'
echo '{"command":"runchat","chatcmd":"pw_test_all","player":"pwbot"}' \
  > data/worlds/perfectworld/rc_cmd.json
```

### Отчёты

- JSON: `data/worlds/perfectworld/ltk_report_*.json`
- Лог: `data/debug-test.txt` (test mode) / `data/debug.txt` (server mode)
- Статусы: PASS, FAIL, SKIP, ERROR

### Текущий baseline

204 total | 204 PASS | 0 FAIL | 0 SKIP | 0 ERROR

Baseline должен оставаться зелёным. Отчёт печатается через
`python3 scripts/report-summary.py`.

---

## 4. Обязательные проверки перед завершением

- `bash -n scripts/*.sh`
- `python3 -m py_compile scripts/*.py`
- `git diff --check`
- `bash scripts/smoke-test.sh`
- Полный тестовый запуск (`scripts/run-testkit.sh`), если менялся Lua-код
- Проверка `ERROR\|FATAL\|ModError\|LuaError\|AsyncErr\|stack traceback`
  в логах сервера и клиента

Быстрая проверка синтаксиса Lua без сервера:

```bash
docker run --rm --entrypoint luajit -v "$PWD/local_mods:/m" perfectworld-luanti \
  -e "local f,e=loadfile('/m/perfectworld/pw_planner/init.lua') print(f and 'OK' or e)"
```

---

## 5. Правила разработки

### Детерминированность
Планы зависят только от: world seed + region coordinates + planner version +
PerfectWorld configuration.

Каждое решение — независимый хеш `hash32(seed_key .. "#" .. label)` через
`perfectworld.core.choice`. Последовательные PRNG запрещены: числа в Lua —
double, произведение выше `2^53` теряет младшие биты (предыдущий LCG вырождался
в цикл длиной 10466). Добавление нового решения не должно сдвигать существующие,
поэтому метки должны быть стабильными строками.

Арифметика: используйте `perfectworld.core.mul32` для 32-битного умножения;
любые промежуточные произведения держите ниже `2^53`.

### Идемпотентность
Повторный запуск materialization не дублирует объекты.

### Безопасность мира
- Проверка `is_protected` перед изменением нод
- Классификация заменяемых нод (vegetation, leaves, trunks, snow, air)
- Rollback при ошибках размещения структур

### Persistence
Через `minetest.get_mod_storage()`. Ключи: `pw_world_format_lock`, `pw_placed_settlements`, `pw_materialized_structures`, `pw_settlement_plans`, `pw_roads`.

### Mineclonia node names
Только в `pw_compat_mcl`. Остальные модули используют `perfectworld.compat.get_material("wall")`.

### Тесты
- Не ослаблять тесты ради зелёного результата
- Запрещены тавтологии вида `assert.is_true(true)` и `assert.is_true(x or true)`
- При отсутствии предусловия — SKIP, не FAIL
- Изолировать изменения мира (snapshot/restore)
- Тесты планировки используют `perfectworld.planner.make_synthetic_terrain`,
  чтобы не зависеть от того, какие mapblock уже сгенерированы

### Валидация поселений
`perfectworld.planner.validate_settlement(id)` проверяет запись **и реальный
мир**. Запись в mod_storage не является доказательством того, что что-то
построено.

---

## 6. Скриншоты

Скриншоты снимаются с работающего headless-клиента:

```bash
# 1. поднять сервер и pwbot
scripts/run-testkit.sh
# 2. посчитать камеры и метаданные
#    (/pw_village_shotlist пишет pw_shotlist_*.json в каталог мира)
# 3. снять кадры
python3 scripts/capture-screenshots.py \
  --shotlist data/worlds/perfectworld/pw_shotlist_<stamp>.json \
  --out /path/outside/git --ids <settlement_id>,<settlement_id>
```

Скрипт ведёт камеру через `pw_remote_control` и снимает окно Luanti через
ImageMagick `import`.

**Клиент определяется строго**: требуется процесс `luanti --go` с
`XAUTHORITY` внутри `/tmp/xvfb-run.*`. Обёртка `xvfb-run` наследует DISPLAY
рабочего стола пользователя — если ориентироваться на неё, `import` снимет
экран пользователя, а не игру. При несовпадении скрипт отказывается работать,
а не угадывает.

## 7. PW Bot и `pw_bot_bridge` — обязательные правила

Подробности: [`docs/pw-bot/`](docs/pw-bot/README.md).

PW Bot **ещё не существует**. Реализованы только его «органы чувств» —
серверный мод `pw_bot_bridge`. Не заявляйте в документации или коммитах, что
бот готов.

Главный принцип:

```text
Bridge observes and explains.
The real client acts.
```

Правила, обязательные для любого будущего изменения:

- **Скриншот — не зрение бота.** Восприятие только программное, из состояния
  сервера. Скриншот остаётся диагностическим артефактом для человека.
- **Никакой зависимости от распознавания изображений.** Ни OpenCV, ни анализа
  кадров, ни внешних процессов из мода.
- **`player` mode не должен раскрывать oracle-данные.** Ни одна нода, сущность
  или запись за пределами позиции, направления взгляда, FOV, дальности и линии
  видимости не попадает в ответ.
- **`oracle` mode никогда не выполняет действий.** Он меняет только объём
  информации.
- **Bridge никогда не двигает игрока**, не меняет yaw/pitch, не телепортирует,
  не открывает двери, не взаимодействует с сущностями, не сажает игрока в
  транспорт и не пишет ноды. `scripts/smoke-test.sh` проверяет это grep-ом.
- **Бот не может повысить себе права.** В протоколе нет операции смены режима,
  регистрации или привилегии — это структурная гарантия, а не проверка.
- **Интеграционные тесты запускаются на настоящем сервере** с подключённым
  `pwbot`. Чистые mock-тесты не заменяют их.
- **Семантика регистрируется централизованно** через
  `pw_bot_bridge.register_node_semantics` / `register_group_semantics` /
  `register_entity_semantics`. Не размазывайте проверки имён нод по коду.
- **Любое изменение внешнего протокола требует версионирования.**
  `pw_bot_bridge/v1` — стабильный контракт; несовместимое изменение означает
  `v2`, а не молчаливую правку.
- **Никаких неограниченных сканирований области.** Каждый запрос имеет лимиты
  площади, объёма, времени и rate limit.
- **`request_insecure_environment()` запрещён** без доказанной необходимости и
  отдельного решения пользователя. Сейчас он не нужен.
- **Не коммитить runtime spool и отчёты**: `data/worlds/*/pw_bot_bridge/`,
  `pw_bot_bridge_*.json`.

External transport выключен по умолчанию. Oracle выключен для обычных игроков.

## 8. Известные ограничения

- Не коммитить: secrets, worlds, logs, reports, screenshots, runtime-data
- FAIL/ERROR в тестах: см. `docs/status.md`
