# Deep Eye Proxmox LXC — 2026-08-14

Первый релиз отдельного контейнера для `zakirkun/deep-eye` 1.4.0.

Ключевые свойства:

- официальный Proxmox Debian 13.6, unprivileged LXC;
- воспроизводимый source pin `e98a361ee38ec65660ce585ff6789017a2d7a466`;
- проверенная OpenAI-compatible интеграция и hard lock `gpt-oss-120b`;
- nginx HTTPS + bcrypt Basic Auth, backend/relay только на loopback;
- отдельный пароль `deepadmin`; старые T3MP3ST credentials не переносятся;
- web-очередь с обязательным подтверждением авторизации цели;
- постоянные state/log/report directories и SHA-256 evidence manifests;
- отчёты и evidence-файлы содержат slug исследуемого ресурса;
- безопасная установка на выбранный Proxmox storage и новый свободный IP;
- acceptance verifier: systemd, nginx, proxy guards, browser, local scan,
  persistent report/evidence, optional live LLM и restart/load stability.

Изменение upstream минимально: `openai-compatible.patch` добавляет configurable
base URL, timeout, top_p и блокировку модели. Исходный Deep Eye остаётся CLI;
web wrapper относится только к deployment-пакету.

Ограничение профиля: compliance отключён, потому что upstream commit не содержит
обязательные JSON framework-файлы. OAST/challenge/proxy/plugins/collaboration
также отключены, пока администратор не настроит и отдельно не проверит
необходимые доверенные сервисы.
