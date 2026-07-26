# CONTRIBUTING.md

## Getting Started

1. Clone the repository
2. Install content: `python3 scripts/install-content.py`
3. Sync mods: `./scripts/sync-local-mods.sh`
4. Build image: `docker compose build`

## Making Changes

1. Create a branch: `git checkout -b feature/my-change`
2. Make your edits
3. Run checks:
   ```bash
   bash -n scripts/*.sh
   python3 -m py_compile scripts/install-content.py
   git diff --check
   bash scripts/smoke-test.sh
   ```
4. If you changed Lua code, run the full test suite (see `docs/testing.md`)
5. Commit with a descriptive message

## Commit Guidelines

- Use English for commit messages
- Prefix: `feat:`, `fix:`, `docs:`, `test:`, `chore:`
- Keep commits focused on one logical change
- Never commit: secrets, worlds, logs, test reports, runtime data

## Reporting Bugs

For world generation bugs, include:

- World seed
- Region coordinates (rx, rz)
- Planner version
- Relevant log excerpts from `data/debug-test.txt`
- Steps to reproduce

For test failures, include:

- Full test name (suite.test)
- Error message
- `ltk_report_*.json` content
- Whether it reproduces on clean run

## Never Commit

- `secrets/pwbot.password`
- `data/worlds/perfectworld/*.sqlite`
- `data/debug*.txt`
- `data/worlds/perfectworld/ltk_report_*.json`
- `logs/`, `run/`, `artifacts/`, `backups/`
