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

# OpenSSH uses the first global value of each directive. Place explicit settings
# before Include directives and Match blocks, without altering password auth.
SSHD_CONFIG=/etc/ssh/sshd_config
[[ -f "$SSHD_CONFIG" && ! -L "$SSHD_CONFIG" ]] || fail '找不到常规 sshd_config 文件或它是符号链接，请人工检查。'

get_setting() {
  "$SSHD_BIN" -T "$@" 2>/dev/null | awk -v k="$1" 'tolower($1)==k {print $2; exit}'
}
# Do not rely on sshd -T alone: Match rules can change behavior by source IP.
EFFECTIVE=$("$SSHD_BIN" -T 2>/dev/null) || fail '原始 sshd 配置无效，停止自动修改。'
CURRENT_PUB=$(printf '%s\n' "$EFFECTIVE" | awk '$1=="pubkeyauthentication" {print $2;exit}')
CURRENT_KEYS=$(printf '%s\n' "$EFFECTIVE" | awk '$1=="authorizedkeysfile" {$1="";sub(/^ /,"");print;exit}')
NEEDS_CHANGE=0
[[ "$CURRENT_PUB" == yes ]] || NEEDS_CHANGE=1
# Preserve extra authorized_keys paths; just ensure standard path is present.
[[ " $CURRENT_KEYS " == *" .ssh/authorized_keys "* ]] || NEEDS_CHANGE=1

if (( NEEDS_CHANGE )); then
  BACKUP="${SSHD_CONFIG}.bak.$(date +%Y%m%d-%H%M%S).$$"
  cp -p "$SSHD_CONFIG" "$BACKUP" || fail '无法备份 SSH 配置。'
  log "原始配置已备份：$BACKUP"
  TMP_CONFIG=$(mktemp "${SSHD_CONFIG}.tmp.XXXXXXXX") || fail '无法创建临时文件。'
  chmod --reference="$SSHD_CONFIG" "$TMP_CONFIG" 2>/dev/null || chmod 600 "$TMP_CONFIG"
  chown --reference="$SSHD_CONFIG" "$TMP_CONFIG" 2>/dev/null || true
  {
    printf '# Managed by setup-ssh-key.sh; global directives precede Include/Match\n'
    printf 'PubkeyAuthentication yes\n'
    if [[ " $CURRENT_KEYS " != *" .ssh/authorized_keys "* ]]; then
      printf 'AuthorizedKeysFile .ssh/authorized_keys\n'
    fi
    cat "$SSHD_CONFIG"
  } > "$TMP_CONFIG" || fail '生成配置失败。'
  # Test the candidate in the original location so relative Include semantics remain unchanged.
  if ! mv -f "$TMP_CONFIG" "$SSHD_CONFIG"; then
    fail '写入 SSH 配置失败。'
  fi
  rollback() {
    cp -p "$BACKUP" "$SSHD_CONFIG" || err '自动回滚失败，请使用备份手动恢复。'
  }
  if ! "$SSHD_BIN" -t; then
    rollback
    fail 'sshd 语法验证失败，已尝试回滚；原 SSH 会话请勿关闭。'
  fi
  CHECK=$("$SSHD_BIN" -T 2>/dev/null) || { rollback; fail '无法读取新配置，已尝试回滚。'; }
  if ! printf '%s\n' "$CHECK" | grep -qx 'pubkeyauthentication yes'; then
    rollback
    fail '全局公钥认证未生效，已尝试回滚。'
  fi
  log 'SSH 全局公钥认证配置已修复并通过语法检查。'
  RELOADED=0
  if command -v systemctl >/dev/null 2>&1; then
    for service in sshd ssh; do
      if systemctl is-active --quiet "$service"; then
        if systemctl reload "$service"; then RELOADED=1; break; fi
      fi
    done
  fi
  if (( ! RELOADED )) && command -v service >/dev/null 2>&1; then
    for service in sshd ssh; do
      if service "$service" status >/dev/null 2>&1 && service "$service" reload; then RELOADED=1; break; fi
    done
  fi
  if (( ! RELOADED )); then
    rollback
    err '无法确认 SSH 服务成功重载，已尝试回滚配置。请检查服务状态。'
  else
    log 'SSH 服务已成功重载（没有强制重启）。'
  fi
else
  log 'SSH 全局公钥认证已启用，无需修改配置。'
fi

printf '\n当前全局配置：\n'
"$SSHD_BIN" -T 2>/dev/null | grep -Ei '^(pubkeyauthentication|authorizedkeysfile|permitrootlogin) ' || true
printf '\nROOT 本地回环地址条件配置（仅作参考，实际来源 IP 可能匹配不同 Match 规则）：\n'
"$SSHD_BIN" -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null | grep -Ei '^(pubkeyauthentication|authorizedkeysfile|permitrootlogin) ' || true
printf '\n请保留当前终端，另开本地终端测试：\n'
printf 'ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no root@服务器IP\n'
printf '如果失败，请检查 Match、AllowUsers/DenyUsers、云平台策略、密钥和客户端配置。\n'
