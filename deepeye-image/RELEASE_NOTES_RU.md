# Deep Eye CLI-only Proxmox LXC — 2026-08-17

Исправленный CLI-only образ Deep Eye 1.4.0:

- полностью удалены nginx, web-wrapper и listeners 80/443/3333;
- добавлена команда `/usr/local/bin/deepeye` с правильным venv/config/PATH;
- `deepadmin` получил group-write доступ к persistent reports/logs/evidence;
- реальный scan и tool checks выполняются в окружении SSH-пользователя;
- deploy теперь показывает точную строку и команду ошибки с журналом firstboot;
- `gpt-oss-120b` остаётся жёстко зафиксирован через loopback relay;
- 17 системных команд, 17 Python imports и Chromium проходят runtime gate;
- отчёты содержат hostname/IP цели в имени и теле.
- Chromium проверяется реальным запуском от SSH-пользователя и browser-verified
  XSS-проверкой на изолированном localhost fixture;
- подтверждение XSS требует браузерного dialog, а не только отражения payload;
- Playwright закрывает browser и connection после каждого URL, поэтому в
  acceptance scan запрещено предупреждение о pending task.

Source pin: `e98a361ee38ec65660ce585ff6789017a2d7a466`.
Base: официальный Proxmox Debian 13.6, unprivileged LXC.
