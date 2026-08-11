# T3MP3ST gpt-oss-120b LXC — 2026-08-11

Новый Debian 13.6 образ заменяет старый Debian 12 комплект. Исправлены главные
проблемы предыдущей версии: неполный набор инструментов, прямой внешний backend,
Host Header rejected через nginx, несовместимое с unprivileged LXC systemd
hardening, UI-переопределение корпоративной модели, потеря reasoning/tool-call
continuity и отсутствие evidence appendix в нормальном отчёте.

Release содержит образ `.tar.zst`, checksums, manifest, список инструментов,
инструкцию и безопасный перенос сетевых/LLM/nginx параметров из CT 101.

## Evidence persistence hotfix

- реальное evidence из mission и tool output теперь попадает в единый
  постоянный ledger, а не остаётся в памяти процесса или только в браузере;
- каждый артефакт имеет стабильный Evidence ID, полный SHA-256, provenance,
  timestamp и защищённый файл под `/var/lib/t3mp3st/evidence`;
- mission report и bounty export используют тот же ledger и содержат Evidence
  Appendix; отчёт остаётся доступен после restart;
- SSE, восстановление UI и экспорт больше не теряют structured evidence и не
  выводят `[object Object]`;
- `T3MP3ST_STATE_DIR=/var/lib/t3mp3st/state` включён по умолчанию;
- `t3mp3st-verify --stability` проверяет полный ledger → report → bounty →
  restart → тот же ID/SHA-256;
- для уже установленного Debian 13 CT приложены
  `t3mp3st-evidence-hotfix-debian13-amd64.tar.gz` и
  `upgrade-evidence-hotfix.sh`; переустановка и изменение сети не требуются.
