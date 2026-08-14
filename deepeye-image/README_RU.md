# Deep Eye для Proxmox LXC

Готовый unprivileged-контейнер Debian 13.6 для
[`zakirkun/deep-eye`](https://github.com/zakirkun/deep-eye), зафиксированный на
коммите `e98a361ee38ec65660ce585ff6789017a2d7a466` (Deep Eye 1.4.0).

В образ добавлен небольшой локальный web-control-plane: исходный проект — CLI
и собственного web-интерфейса не имеет. Backend слушает только
`127.0.0.1:3333`; снаружи доступен nginx по HTTPS с Basic Auth. Запуск требует
URL, явного подтверждения права на тестирование и текста основания. Отчёты,
логи, очередь заданий и SHA-256-манифесты сохраняются в `/var/lib/deepeye`.

## Что внутри

- Debian 13.6, systemd, nginx, SSH по ключу;
- Deep Eye в отдельном Python venv, Chromium/Playwright;
- HTML/JSON-отчёты и имена артефактов с исследуемым ресурсом;
- gpt-oss-120b через loopback relay `127.0.0.1:18080`;
- серверная блокировка модели `gpt-oss-120b` и поддержка OpenAI-compatible URL;
- приватные/loopback/reserved цели запрещены по умолчанию;
- один активный скан, персистентное состояние и восстановление после restart;
- `deepeye-verify` для nginx, модели, браузера, локального скана и стабильности.

Проверяемый профиль инструментов записан в `required-tools.json`: 17 команд и
17 ключевых Python-модулей. Verifier проверяет их от имени системного пользователя
`deepeye`, а не root, затем действительно запускает CLI, Chromium и ограниченный
локальный scan. Неиспользуемые инструменты не добавляются только ради процента:
например, `mitmweb` нужен лишь выключенному intercepting-proxy модулю.

Это средство только для собственных ресурсов или целей с явным разрешением.

## Установка на Proxmox-ноду

Скопируйте на ноду image, `deploy-deepeye.sh` и при необходимости файлы с
паролем/API-ключом. Пароль должен содержать не менее 12 символов. Каждый секрет
должен быть отдельным root-readable файлом, а не аргументом команды.

```bash
chmod 0700 ./deploy-deepeye.sh
chmod 0600 ./web-password.txt ./gpt-oss-key.txt

./deploy-deepeye.sh \
  ./deepeye-gpt-oss-120b-debian13.6-pve-amd64-20260814.tar.zst \
  242 \
  --ip 192.168.1.242/24 \
  --gateway 192.168.1.1 \
  --bridge vmbr0 \
  --storage local-lvm \
  --dns 192.168.1.1 \
  --ssh-key /root/.ssh/authorized_keys \
  --web-password-file ./web-password.txt \
  --llm-key-file ./gpt-oss-key.txt
```

Укажите свободный адрес. Не назначайте IP работающего T3MP3ST или другого CT.
Скрипт создаёт отдельный CT: 4 vCPU, 8 ГиБ RAM, 2 ГиБ swap, диск 100 ГиБ.
Поменять параметры можно в `deploy-deepeye.sh` до запуска.

Если пароль не передан, first boot создаст случайный. Посмотреть его на ноде:

```bash
pct exec 242 -- cat /root/deepeye-initial-credentials.txt
```

Web user всегда `deepadmin`. Открывайте `https://192.168.1.242/`; предупреждение
браузера ожидаемо для локального self-signed сертификата.

## Если у контейнера нет прямого Интернета

Образ уже содержит приложение, Python-зависимости и браузер. Для работы нужен
только маршрут от CT к вашему LLM endpoint и к разрешённым целям сканирования.
Файлы передаются через Proxmox-ноду:

```bash
scp deepeye-*.tar.zst deploy-deepeye.sh root@PVE_NODE:/root/deepeye/
ssh root@PVE_NODE
cd /root/deepeye
```

Не запускайте `pip install` внутри production CT: это разрушит проверенный набор
зависимостей. Версии записаны в `deepeye-python-lock.txt` и build manifest.

## Настройка gpt-oss-120b после установки

```bash
pct push 242 ./gpt-oss-key.txt /root/gpt-oss-key.txt --perms 0600
pct exec 242 -- configure-deepeye-llm \
  --key-file /root/gpt-oss-key.txt \
  --upstream https://llm.enplus.group/v1 \
  --tls-mode strict
pct exec 242 -- rm -f /root/gpt-oss-key.txt
```

Для корпоративного CA сначала передайте сертификат и используйте
`--tls-mode custom-ca --ca-file /etc/deepeye/corporate-ca.pem`. Режим
`insecure-host` предназначен только для временной диагностики.

## Пароль, область целей и SSH

Сменить web-пароль внутри CT:

```bash
pct exec 242 -- deepeye-set-password
```

Разрешить только конкретные домены можно в `/etc/deepeye/deepeye.env`:

```text
DEEPEYE_ALLOWED_HOSTS=example.com,*.example.com
DEEPEYE_ALLOW_PRIVATE_TARGETS=0
```

Для собственного приватного стенда установите `DEEPEYE_ALLOW_PRIVATE_TARGETS=1`
и перезапустите `deepeye`; не включайте этот параметр без необходимости.

SSH: пользователь `deepadmin`, вход только по ключу. Root по ключу также
разрешён, парольный SSH отключён.

## Проверка

```bash
pct exec 242 -- deepeye-verify
pct exec 242 -- deepeye-verify --live-llm
pct exec 242 -- deepeye-verify --live-llm --stability
```

Обычная проверка использует локальную fixture и не сканирует Интернет.
`--live-llm` делает короткий запрос к подключённому endpoint. Evidence проверки:
`/var/lib/deepeye/evidence/acceptance-*`; отчёт —
`/var/lib/deepeye/reports/acceptance-*.md`.

## Сборка

На чистом Debian/Ubuntu runner с root и Интернетом:

```bash
sudo ./build.sh ./out
sha256sum -c ./out/SHA256SUMS
```

Builder проверяет SHA-512 официального Proxmox Debian 13.6 template и исходного
архива Deep Eye, применяет patch без fuzz, запускает все применимые upstream-
тесты и regression для OpenAI-compatible gpt-oss, затем создаёт reproducible
`.tar.zst`. Единственное исключение — upstream compliance-suite: зафиксированный
коммит не содержит требуемых `utils/compliance/frameworks/*.json`, поэтому
compliance выключен в поддерживаемом профиле и его тесты явно исключены.

Неиспользованные опциональные функции Deep Eye (compliance, OAST, challenge
bypass, proxy, plugin/collaboration servers) намеренно выключены: они требуют
отсутствующих данных или отдельных доверенных сервисов и не входят в проверенный
профиль этого образа.
