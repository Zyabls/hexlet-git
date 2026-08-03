Готовый незашифрованный Free AI LXC rootfs-шаблон для Proxmox VE. Это не установщик: Debian 12, Node.js 24.16.0, npm-зависимости, собранный T3MP3ST (`afc9dad1`), Codex CLI 0.146.0, CPU-only Ollama 0.32.5 и Qwen2.5-Coder 1.5B уже находятся внутри.

Для установки на изолированном узле Proxmox достаточно перенести `.tar.zst` и файл контрольной суммы. Команды находятся в `INSTALL_PROXMOX_RU.txt`.

Основной профиль использует Codex CLI через вход ChatGPT без Platform API key; полностью автономный резерв использует локальную Qwen через Ollama. В образ не включены пароли, API-ключи и авторизация Codex. Администратор `t3admin` получает публичный ключ, переданный Proxmox через `pct create --ssh-public-keys`.
