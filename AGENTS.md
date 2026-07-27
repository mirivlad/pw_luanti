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

118 total | 118 PASS | 0 FAIL | 0 SKIP | 0 ERROR

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

## 7. Известные ограничения

- Не коммитить: secrets, worlds, logs, reports, screenshots, runtime-data
- FAIL/ERROR в тестах: см. `docs/status.md`
