#!/bin/bash
# grant-access.sh <user>@<host> [<user>@<host> ...]
#
# Step 0 of a new k3s node, run ONCE from the laptop, interactively: it asks for the box's password
# (ssh) and its sudo or root password. It adds two public keys and passwordless sudo, so every later
# step (bootstrap.sh, verify.sh, migrations) runs without a human at the keyboard.
#   - this laptop's key (~/.ssh/id_ed25519.pub)
#   - the homelab key Hermes/Andrzej use on paperclip (id_ed25519.homelab-2nd)
# Falls back to `su -c` when Debian was installed without sudo.
set -e
[ $# -ge 1 ] || { echo "usage: $0 user@host [user@host ...]"; exit 2; }
HOMELAB_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICcsQJnY95sQMIZ6wmhNpXejfgbZfLTakv8mpgh7qqKI homelab-2nd-access'
LAPTOP_KEY="$(cat ~/.ssh/id_ed25519.pub)"
for T in "$@"; do
  U=${T%@*}
  echo "=== $T"
  ssh -t -o PubkeyAuthentication=no "$T" "
    mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
    grep -qF '$LAPTOP_KEY' ~/.ssh/authorized_keys || echo '$LAPTOP_KEY' >> ~/.ssh/authorized_keys
    grep -qF '$HOMELAB_KEY' ~/.ssh/authorized_keys || echo '$HOMELAB_KEY' >> ~/.ssh/authorized_keys
    if command -v sudo >/dev/null; then
      echo '$U ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-$U-nopasswd >/dev/null && sudo chmod 440 /etc/sudoers.d/90-$U-nopasswd
    else
      echo 'sudo not installed - enter the ROOT password:'
      su -c \"apt-get install -y sudo && echo '$U ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-$U-nopasswd && chmod 440 /etc/sudoers.d/90-$U-nopasswd\"
    fi
    sudo -n true && echo 'sudo OK on '\$(hostname)
  "
done
echo "Done. Next: host/k3s-node/bootstrap.sh"
