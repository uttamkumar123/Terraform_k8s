#!/usr/bin/env bash
set -euxo pipefail

# ---------- System prep ----------
swapoff -a || true
sed -i.bak '/ swap / s/^/#/' /etc/fstab

modprobe overlay || true
modprobe br_netfilter || true
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

cat >/etc/sysctl.d/99-kubernetes-cri.conf <<'EOF'
net.bridge.bridge-nf-call-iptables=1
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-ip6tables=1
EOF
sysctl --system

# ---------- Packages (AL2023 uses dnf) ----------
dnf clean all -y || true
dnf makecache -y || true
# Keep curl-minimal from the AMI; DO NOT install 'curl' to avoid conflicts
dnf install -y --allowerasing \
  containerd jq awscli iproute socat ebtables ethtool conntrack-tools

# containerd config
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml >/dev/null
# Use systemd cgroups for kubelet compatibility
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd

# ---------- Kubernetes repo (v1.30 stable) ----------
rpm --import https://pkgs.k8s.io/core:/stable:/v1.30/rpm/repodata/repomd.xml.key
cat >/etc/yum.repos.d/kubernetes.repo <<'EOF'
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.30/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.30/rpm/repodata/repomd.xml.key
EOF

dnf install -y --allowerasing kubelet kubeadm kubectl
systemctl enable --now kubelet

# Ensure kubelet binds to the correct node IP
PRIVATE_IP="$$(hostname -I | awk '{print $1}')"
echo "KUBELET_EXTRA_ARGS=--node-ip=$${PRIVATE_IP}" | tee /etc/sysconfig/kubelet
systemctl daemon-reload
systemctl restart kubelet

# ---------- Discover control plane & join ----------
REGION="$${region:-us-east-1}"
TOKEN="$${kubeadm_token:-abcdef.0123456789abcdef}"

# Discover control-plane private IP via tag
attempts=0
CP_IP=""
until [[ -n "$CP_IP" || $attempts -ge 30 ]]; do
  CP_IP=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:k8s-role,Values=control-plane" "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].PrivateIpAddress" \
    --output text 2>/dev/null | head -n1 || true)
  [[ -z "$CP_IP" ]] && attempts=$((attempts+1)) && sleep 5
done

if [[ -z "$CP_IP" ]]; then
  echo "ERROR: Failed to discover control-plane IP" >&2
  exit 1
fi

# Wait for API server to be reachable
for i in {1..30}; do
  (echo > /dev/tcp/${CP_IP}/6443) >/dev/null 2>&1 && break || true
  sleep 5
done

# Join the cluster
# NOTE: For production, use --discovery-token-ca-cert-hash sha256:<hash> instead of unsafe skip.
kubeadm join ${CP_IP}:6443 \
  --token "$${TOKEN}" \
  --discovery-token-unsafe-skip-ca-verification

# (Optional) Basic node sanity log
echo "Joined Kubernetes cluster at ${CP_IP}:6443 from $${PRIVATE_IP}"

