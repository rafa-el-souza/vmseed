# SSH public keys

Place the **public** keys (`.pub`) for each user here. `fedora-cloud.sh build`
reads them and splices their contents into the generated `build/user-data`.

Expected files (override paths via `STD_KEY_FILE` / `ADM_KEY_FILE` env vars if you prefer):

- `appuser.pub` — public key for the standard user
- `admin.pub`   — public key for the admin user

## Generating a key pair

```bash
ssh-keygen -t ed25519 -C "appuser@fedora" -f ./appuser
ssh-keygen -t ed25519 -C "admin@fedora"   -f ./admin
```

This creates `appuser` / `appuser.pub` and `admin` / `admin.pub`.

## Reuse an existing key

Just copy the public key in:

```bash
cp ~/.ssh/id_ed25519.pub ./admin.pub
```

## ⚠️ Never commit private keys

Only the `.pub` files belong in the repo. The `.gitignore` at the project root
ignores everything in this directory except `.pub` files and this README.
Keep your private keys out of version control.
