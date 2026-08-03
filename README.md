# T3MP3ST Proxmox LXC bundle

Deployment bundle for an unprivileged Proxmox VE LXC container.

- T3MP3ST source commit: `afc9dad1b27e438e36fdb0fd80c4dec26f3a02aa`
- Plain archive: `t3mp3st-proxmox-lxc-afc9dad1-20260803.tar.gz`
- Plain archive SHA-256: `76328c2d38f9d739a8771955fa9f59c365f0cfffb890a2dd7fe411deb02d71fa`
- Encrypted file: `t3mp3st-proxmox-lxc-afc9dad1-20260803.tar.gz.enc`
- Encryption: AES-256-CBC, PBKDF2, 600000 iterations
- Encrypted SHA-256: `5d4e872ac095de4d2662854925046109a127d564fda75de0b538d59e04430390`

Use the plain archive for direct installation:

```bash
sha256sum -c t3mp3st-proxmox-lxc-afc9dad1-20260803.tar.gz.sha256
tar -xzf t3mp3st-proxmox-lxc-afc9dad1-20260803.tar.gz
```

The encrypted copy remains available as an alternative; its password is distributed separately.

```bash
sha256sum -c t3mp3st-proxmox-lxc-afc9dad1-20260803.tar.gz.enc.sha256
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
  -in t3mp3st-proxmox-lxc-afc9dad1-20260803.tar.gz.enc \
  -out t3mp3st-proxmox-lxc-afc9dad1-20260803.tar.gz
tar -xzf t3mp3st-proxmox-lxc-afc9dad1-20260803.tar.gz
```

After extraction, read `t3mp3st-proxmox-lxc-20260803/README_RU.md` before deployment.
