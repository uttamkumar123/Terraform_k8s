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

# ---------- kubeadm init ----------
PRIVATE_IP=$(hostname -I | awk '{print $1}')
kubeadm_token="${kubeadm_token:-abcdef.0123456789abcdef}"
TOKEN="${kubeadm_token:-abcdef.0123456789abcdef}"
pod_cidr="${pod_cidr:-10.244.0.0/16}" 

kubeadm init \
  --token "${kubeadm_token}" \
  --apiserver-advertise-address "${PRIVATE_IP}" \
  --pod-network-cidr "${pod_cidr}"

# kubeconfig
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
chown -R root:root /root/.kube

if id ec2-user &>/dev/null; then
  mkdir -p /home/ec2-user/.kube
  cp /etc/kubernetes/admin.conf /home/ec2-user/.kube/config
  chown -R ec2-user:ec2-user /home/ec2-user/.kube
fi

# CNI (Flannel is lighter)
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

sleep 10
kubectl get nodes -o wide || true