#!/bin/bash
# Run on your Mac: bash tools/githubsecrets.sh
set -euo pipefail
cd "$(dirname "$0")/.."

for command in gh ssh ssh-keygen ssh-keyscan; do
  command -v "$command" >/dev/null || {
    echo "Missing $command. Install GitHub CLI with: brew install gh" >&2
    exit 1
  }
done
gh auth status
default_repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
read -rp "GitHub repository [$default_repo]: " repo </dev/tty
repo=${repo:-$default_repo}
[[ $repo =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] || { echo 'Invalid repository' >&2; exit 1; }
read -rp 'VPS public IP or hostname: ' host </dev/tty
[[ $host =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || { echo 'Enter a hostname or IPv4 address without a URL scheme' >&2; exit 1; }
read -rp 'SSH port [22]: ' port </dev/tty
port=${port:-22}
[[ $port =~ ^[0-9]{1,5}$ ]] && ((10#$port >= 1 && 10#$port <= 65535)) || { echo 'Invalid SSH port' >&2; exit 1; }
port=$((10#$port))
read -rp 'Existing VPS login user [ubuntu]: ' login_user </dev/tty
login_user=${login_user:-ubuntu}
[[ $login_user =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || { echo 'Invalid login user' >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"
ssh-keygen -q -t ed25519 -N '' -C orbit-github-actions -f "$work/key"
ssh-keyscan -p "$port" -t ed25519 "$host" > "$work/known_hosts" 2>/dev/null
[[ -s "$work/known_hosts" ]] || { echo 'No SSH host key received' >&2; exit 1; }
echo 'Scanned VPS host fingerprint:'
ssh-keygen -lf "$work/known_hosts"
echo 'Compare it with this command in your existing VPS console:'
echo 'sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub'
read -rp 'Do the fingerprints match? Type yes: ' answer </dev/tty
[[ $answer == yes ]] || { echo 'Stopped without installing keys or secrets'; exit 1; }

# Verify GitHub access before changing the VPS. Existing environment settings
# (including any approval rules) are preserved by this empty update.
gh api --method PUT "repos/$repo/environments/production" >/dev/null
public_key=$(cat "$work/key.pub")
ssh -t -p "$port" -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$work/known_hosts" "$login_user@$host" "
    set -e
    id orbit-deploy >/dev/null
    sudo install -d -m 700 -o orbit-deploy -g orbit-deploy /home/orbit-deploy/.ssh
    printf '%s\n' 'restrict $public_key' |
      sudo tee -a /home/orbit-deploy/.ssh/authorized_keys >/dev/null
    sudo chown orbit-deploy:orbit-deploy /home/orbit-deploy/.ssh/authorized_keys
    sudo chmod 600 /home/orbit-deploy/.ssh/authorized_keys
  "

echo 'Checking deployment key and release-helper access...'
ssh -T -i "$work/key" -p "$port" \
  -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$work/known_hosts" "orbit-deploy@$host" \
  'sudo -n -l /usr/local/sbin/orbit-deploy'

printf '%s' "$host" | gh secret set VPS_HOST --repo "$repo" --env production
printf '%s' "$port" | gh secret set VPS_PORT --repo "$repo" --env production
gh secret set VPS_SSH_KEY --repo "$repo" --env production < "$work/key"
gh secret set VPS_KNOWN_HOSTS --repo "$repo" --env production < "$work/known_hosts"
echo "Configured VPS_HOST, VPS_PORT, VPS_SSH_KEY and VPS_KNOWN_HOSTS in $repo / production."
echo 'Run Actions → Deploy VPS → Run workflow on main to test deployment.'
