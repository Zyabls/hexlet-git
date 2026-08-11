# T3MP3ST source snapshot

`t3mp3st-source.tar.gz` is a release input, not an archive of a raw personal
worktree. It contains tracked T3MP3ST files plus the reviewed gpt-oss/evidence
source and regression tests required by this release. Personal automation,
credentials, `.env` files, monitor output, node_modules and unrelated untracked
files are excluded.

The builder accepts the archive only when
`sha256sum -c t3mp3st-source.tar.gz.sha256` succeeds. Current SHA-256:

`93e7ddf3bd752f2bc9cfd4b4a4d488863dfa0edc367279f47230b5c6536320f9`
