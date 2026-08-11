# T3MP3ST для Proxmox LXC: Debian 13.6 + gpt-oss-120b

Это воспроизводимый шаблон **непривилегированного** LXC для Proxmox VE. Он
собирается из официального `debian-13-standard_13.6-1_amd64.tar.zst`, проверяет
его SHA-512, проверяет отдельный снимок исходников T3MP3ST и все скачиваемые
бинарные инструменты. Секретов в образе нет.

## Что внутри

- T3MP3ST, привязанный к `127.0.0.1:3333`;
- серверная блокировка провайдера и модели на `gpt-oss-120b`;
- локальный relay `127.0.0.1:18080` для корпоративного OpenAI-compatible API;
- nginx на 80/443: HTTPS, Basic Auth, 600-секундные таймауты, без буферизации
  потоковых ответов, принудительный backend Host `127.0.0.1:3333`;
- Node.js 22.19.0, Python, Chromium, Pandoc/WeasyPrint и полный профиль
  recon/web/supply-chain инструментов из `required-tools.json`;
- отчёты `/var/lib/t3mp3st/reports` и доказательства
  `/var/lib/t3mp3st/evidence` с Evidence ID, путём и SHA-256;
- first-boot генерация уникальных SSH host keys, TLS-сертификата и web-пароля.

`OPENAI_API_KEY=relay-managed-local-only` в app env — намеренный **не секретный**
sentinel для проверки адаптера. Relay не пересылает его и подставляет настоящий
ключ только из root-owned `/etc/t3mp3st/relay.env`.

## Установка с переносом настроек CT 101

На PVE скачайте из Release образ, `SHA256SUMS` и `deploy-from-ct101.sh`, затем:

```bash
sha256sum -c SHA256SUMS --ignore-missing
chmod 0700 deploy-from-ct101.sh
./deploy-from-ct101.sh ./t3mp3st-gpt-oss-120b-debian13.6-pve-amd64-20260811.tar.zst 241
```

Сценарий копирует точный `net0`, nameserver и searchdomain из CT 101, но удаляет
старый MAC. Новый CT сначала запускается с `link_down=1`, поэтому IP-конфликта
нет. Он также переносит relay env/API key, корпоративный CA, nginx htpasswd и
SSH-ключ, не печатая секреты. Для атомарного переноса во время согласованного
окна используйте сразу:

```bash
./deploy-from-ct101.sh ./t3mp3st-gpt-oss-120b-debian13.6-pve-amd64-20260811.tar.zst 241 --cutover
```

При ошибке live/stability-проверки новый CT останавливается, а CT 101
запускается обратно. Старый CT не удаляется.

## Настройка gpt-oss-120b

Если ключ не был перенесён, внутри контейнера выполните:

```bash
sudo configure-gpt-oss
sudo t3mp3st-verify --live-llm --stability
```

Ключ вводится скрыто. Альтернатива для автоматизации — root-only файл:

```bash
sudo configure-gpt-oss --key-file /root/gpt-oss.key
```

По умолчанию TLS строгий. Для корпоративного CA положите цепочку в
`/etc/t3mp3st/corporate-ca.pem` и задайте `GPT_OSS_TLS_MODE=custom-ca` в
`/etc/t3mp3st/relay.env`. Режим `insecure-host` допустим только как временная
совместимость: отключение проверки действует лишь для hostname из
`GPT_OSS_UPSTREAM`, а не глобально для Node.js.

Начальные web-реквизиты находятся в root-only файле
`/root/t3mp3st-initial-credentials.txt`. При переносе прежнего htpasswd
используется прежний пароль. Заменить пароль:

```bash
sudo htpasswd /etc/t3mp3st/nginx.htpasswd t3admin
```

## Проверка готовности

```bash
sudo t3mp3st-verify                 # ОС, сервисы, nginx и локальные fixtures
sudo t3mp3st-verify --live-llm      # дополнительно model list + tool call
sudo t3mp3st-verify --live-llm --stability  # 1000 health-запросов, OOM/restarts
```

Проверка никогда не сканирует внешние цели: nmap/httpx/katana/ffuf/nuclei
работают только с локальной fixture на `127.0.0.1`. Создаются Markdown, HTML,
PDF, scanner outputs, SBOM и `SHA256SUMS` доказательств.

## Границы CI

GitHub Actions проверяет source checksum, shell, npm typecheck/lint/полный suite,
сборку, наличие 100% обязательных инструментов, nginx/node static acceptance и
secret guard. Реальный boot ядром PVE и корпоративный API возможны только на
вашем PVE; именно поэтому cutover запрещён без live LLM и stability gate.
