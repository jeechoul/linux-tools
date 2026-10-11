#!/usr/bin/env bash
# Install an SSH public key for root, with safe sshd validation.
set -Eeuo pipefail
umask 077

log() { printf '[INFO] %s\n' "$*"; }
err() { printf '[ERROR] %s\n' "$*" >&2; }
fail() { err "$*"; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail '请以 root 身份执行：sudo bash setup-ssh-key.sh'
[[ -t 0 ]] || fail '需要交互式终端输入公钥，请在 SSH 终端直接运行此脚本。'

SSHD_BIN=$(command -v sshd || true)
if [[ -z "$SSHD_BIN" ]]; then
  for p in /usr/sbin/sshd /sbin/sshd /usr/local/sbin/sshd; do
    [[ ! -x "$p" ]] || { SSHD_BIN=$p; break; }
  done
fi
[[ -n "$SSHD_BIN" ]] || fail '未找到 sshd，请先安装并启动 OpenSSH Server。'

printf '\n请粘贴本地 id_ed25519.pub 文件的完整单行内容，然后按回车：\n'
IFS= read -r PUBKEY
PUBKEY=${PUBKEY%$'\r'}
[[ "$PUBKEY" != *$'\n'* ]] || fail '公钥必须是一行。'
[[ "$PUBKEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]+[^[:space:]]+([[:space:]].*)?$ ]] || fail '公钥格式不正确。请粘贴 .pub 文件内容，不要粘贴私钥。'

KEYTYPE=${PUBKEY%%[[:space:]]*}
REMAINDER=${PUBKEY#*[$' \t']}
KEYDATA=${REMAINDER%%[[:space:]]*}
if command -v ssh-keygen >/dev/null 2>&1; then
  TMPKEY=$(mktemp)
  trap 'rm -f "$TMPKEY"' EXIT
  printf '%s %s\n' "$KEYTYPE" "$KEYDATA" > "$TMPKEY"
  ssh-keygen -lf "$TMPKEY" >/dev/null 2>&1 || fail '公钥内容无效，无法通过 ssh-keygen 校验。'
fi

SSH_DIR=/root/.ssh
AUTH_KEYS=$SSH_DIR/authorized_keys
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
[[ ! -L "$AUTH_KEYS" ]] || fail 'authorized_keys 是符号链接，请人工确认安全性。'
[[ ! -e "$AUTH_KEYS" || -f "$AUTH_KEYS" ]] || fail 'authorized_keys 不是普通文件。'
touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
chown 0:0 "$SSH_DIR" "$AUTH_KEYS"

if awk -v t="$KEYTYPE" -v k="$KEYDATA" '$1==t && $2==k {found=1} END {exit !found}' "$AUTH_KEYS"; then
  log '此公钥已存在，无需重复添加。'
else
  [[ ! -s "$AUTH_KEYS" || $(tail -c 1 "$AUTH_KEYS" | wc -l) -eq 1 ]] || printf '\n' >> "$AUTH_KEYS"
  printf '%s\n' "$PUBKEY" >> "$AUTH_KEYS"
  log '公钥已添加到 /root/.ssh/authorized_keys。'
fi

# Do not change sshd configuration automatically: existing Match blocks,
# cloud-init, distro includes, and access policies require careful review.
if "$SSHD_BIN" -t 2>/dev/null; then
  log 'sshd 配置语法检查通过。'
else
  err 'sshd 配置检查失败；公钥已写入，但请检查 sshd 配置。'
fi

printf '\n当前 SSH 公钥认证配置（仅供检查）：\n'
"$SSHD_BIN" -T 2>/dev/null | grep -Ei '^(pubkeyauthentication|authorizedkeysfile|permitrootlogin) ' || true
printf '\n配置已完成。通常仅添加 authorized_keys 不需要重启 SSH 服务。\n'
printf '请保留当前终端，并在本地另开终端测试：ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no root@服务器IP\n'
printf '如果失败，请检查 PermitRootLogin、PubkeyAuthentication、云平台策略及 sshd Match 配置。\n'
