# T3MP3ST gpt-oss-120b LXC — 2026-08-11

Новый Debian 13.6 образ заменяет старый Debian 12 комплект. Исправлены главные
проблемы предыдущей версии: неполный набор инструментов, прямой внешний backend,
Host Header rejected через nginx, несовместимое с unprivileged LXC systemd
hardening, UI-переопределение корпоративной модели, потеря reasoning/tool-call
continuity и отсутствие evidence appendix в нормальном отчёте.

Release содержит образ `.tar.zst`, checksums, manifest, список инструментов,
инструкцию и безопасный перенос сетевых/LLM/nginx параметров из CT 101.
