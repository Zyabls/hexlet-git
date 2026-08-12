# T3MP3ST source snapshot

`t3mp3st-source.tar.gz` is a release input, not an archive of a raw personal
worktree. It contains tracked T3MP3ST files plus the reviewed gpt-oss/evidence
source and regression tests required by this release. Personal automation,
credentials, `.env` files, monitor output, node_modules and unrelated untracked
files are excluded.

The builder accepts the archive only when
`sha256sum -c t3mp3st-source.tar.gz.sha256` succeeds. Current SHA-256:

`0e8ea85f97d41cf38ca76a0ae6a6c9a764f759c61afa6be75ceecd19289cd1f3`
