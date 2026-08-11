# T3MP3ST Proxmox LXC

Актуальная production-сборка: Debian 13.6, nginx и корпоративный
`gpt-oss-120b`. Описание, перенос настроек CT 101 и acceptance-команды находятся
в [`trixie-image/README_RU.md`](trixie-image/README_RU.md).

Сборка воспроизводится workflow `.github/workflows/build-t3mp3st-lxc.yml` из
проверяемого source snapshot. Предыдущий Debian 12 комплект оставлен в
`offline-image/` только для истории и не является рекомендуемым.
