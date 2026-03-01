#!/usr/bin/env bash
set -euo pipefail

# Optional: log everything for debugging
exec > >(tee -a /var/log/startup-bootstrap.log) 2>&1

mkdir -p /opt/startup/parts
chmod 755 /opt/startup /opt/startup/parts

# Write parts to disk (use UNIQUE heredoc markers to avoid collisions)
cat >/opt/startup/parts/10-base.sh <<'__PART_10_BASE__'
${base}
__PART_10_BASE__

cat >/opt/startup/parts/30-easytrade.sh <<'__PART_30_EASYTRADE__'
${easytrade}
__PART_30_EASYTRADE__

cat >/opt/startup/parts/40-easytrade-ingress.sh <<'__PART_40_EASYTRADE_INGRESS__'
${easytrade_ingress}
__PART_40_EASYTRADE_INGRESS__

cat >/opt/startup/parts/50-argocd.sh <<'__PART_50_ARGOCD__'
${argocd}
__PART_50_ARGOCD__

chmod +x /opt/startup/parts/*.sh

# Run parts in deterministic order
for f in /opt/startup/parts/*.sh; do
  echo "==> Running $f"
  /usr/bin/env bash "$f"
done