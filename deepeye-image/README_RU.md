# Deep Eye CLI-only для Proxmox LXC

Проверенный образ `zakirkun/deep-eye` 1.4.0 для Debian 13.6. В этой редакции
полностью удалены nginx, web-wrapper, порты 80/443/3333 и web-пароль. Работа
выполняется по SSH или через `pct exec` командой `deepeye`.

Модель зафиксирована как `gpt-oss-120b`. API-ключ хранится только в root-owned
`/etc/deepeye/relay.env`, а локальный relay слушает `127.0.0.1:18080`.

## Почему исправлена ошибка команд

В предыдущем образе отсутствовал исполняемый файл `deepeye` в PATH, а SSH-
пользователь `deepadmin` не мог записывать отчёты. Теперь:

- `/usr/local/bin/deepeye` всегда запускает правильный venv и production config;
- `deepadmin` входит в группу `deepeye`;
- state, evidence, logs, data и reports имеют setgid/group-write права;
- acceptance scan выполняется именно от `deepadmin`, с его PATH и HOME.

## Установка на Proxmox

Передайте образ, `deploy-deepeye.sh`, SSH public key и при необходимости файл
API-ключа на PVE-ноду. Скрипт требует новый CTID и свободный IP.

```bash
chmod 0700 ./deploy-deepeye.sh
chmod 0600 ./gpt-oss-key.txt

./deploy-deepeye.sh \
  ./deepeye-cli-gpt-oss-120b-debian13.6-pve-amd64-20260817.tar.zst \
  243 \
  --ip 192.168.1.243/24 \
  --gateway 192.168.1.1 \
  --bridge vmbr0 \
  --storage local-lvm \
  --template-storage local \
  --ssh-key /root/.ssh/authorized_keys \
  --llm-key-file ./gpt-oss-key.txt \
  --llm-upstream https://llm.enplus.group/v1
```

Не назначайте адрес уже работающего контейнера. Скрипт сохраняет CT при ошибке
и выводит команду/строку сбоя, failed units и firstboot journal.

## Использование

```bash
ssh deepadmin@192.168.1.243
deepeye --version
deepeye --help
deepeye --url https://authorized.example --formats html,json
```

Либо с PVE-ноды:

```bash
pct exec 243 -- runuser -u deepadmin -- deepeye --version
pct exec 243 -- runuser -u deepadmin -- deepeye \
  --url https://authorized.example --formats html,json
```

Отчёты: `/var/lib/deepeye/reports`. Логи: `/var/lib/deepeye/logs`.
Имя отчёта содержит hostname/IP исследуемого ресурса.

## LLM после установки

```bash
pct push 243 ./gpt-oss-key.txt /root/gpt-oss-key.txt --perms 0600
pct exec 243 -- configure-deepeye-llm \
  --key-file /root/gpt-oss-key.txt \
  --upstream https://llm.enplus.group/v1 \
  --tls-mode strict
pct exec 243 -- rm -f /root/gpt-oss-key.txt
```

Для корпоративного CA используйте `--tls-mode custom-ca --ca-file FILE`.

## Проверка

```bash
pct exec 243 -- deepeye-verify
pct exec 243 -- deepeye-verify --live-llm
pct exec 243 -- deepeye-verify --live-llm --stability
```

Verifier проверяет отсутствие web/nginx, SSH, loopback relay, весь supported
tool profile, Python imports, Chromium, права `deepadmin`, настоящий локальный
scan, имена/содержимое отчётов и optional live LLM.

Compliance/OAST/challenge-solver/plugins/collaboration остаются отключёнными:
зафиксированный upstream не содержит требуемые framework data или требует
отдельные внешние доверенные сервисы.
