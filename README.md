# Terraform_k8s
Terraform code to create a vanilla K8s cluster on AWS.

1) Creates a VPC + public subnet

2) Stands up two Auto Scaling Groups (min=1, max=2):
   - one for a Kubernetes control-plane node
   - one for a data/worker node

3) Uses Launch Templates with user_data to install Kubernetes via kubeadm

4) Boots a 1-master / 1-worker cluster automatically (ASGs allow you to scale to 2 later)

!!! This is a demo code. It trades some security best pratices for simplicity (e.g. fixed kubeadm token, wide open SG !!!

# How To Run :
*** The code assumes the readers has begineer to intermediate terraform knowledge 
1) terraform init

2) terraform plan 

3) terraform apply

After a few minutes, SSH to the control-plane instance (find it in the EC2 console or via the ASG) and verify:

***Get Publich IP for control plane AWs EC2 instance

aws ec2 describe-instances --filters "Name=tag:k8s-role,Values=control-plane" "Name=instance-state-name,Values=running" --query "Reservations[].Instances[].PublicIpAddress" --region us-east-1 --output text

*** SSH using keypair

ssh -i ~/.ssh/YOUR_KEY.pem ubuntu@CONTROL_PLANE_PUBLIC_IP

*** Kubectl command to query cluster

sudo kubectl get nodes -o wide
sudo kubectl get pods -A

# Troubleshooting 
1) Verify services and ports

*** Is the API server up?

sudo ss -lntp | grep 6443

2) Kubelet and containerd status
sudo systemctl status containerd --no-pager
sudo systemctl status kubelet --no-pager

3) Cloud-init & kubelet logs
sudo tail -n 200 /var/log/cloud-init-output.log
sudo journalctl -u kubelet -n 200 --no-pager

4) Userdata script for control plane and worker will be located in /var/lib/cloud/instance/scripts/ path of the EC2 instance. You can modify and re-run it if required

5) Control Plane component like kube-apiserver is spawned as static K8s pod. K8s spec will be located in /etc/kubernetes/manifests/kube-apiserver.yaml. You can modify to bump up resources as required if frequently restarting to OOM or resource exhaustion

6) Check Kube-Apiserver health 
kubectl -n kube-system get pod -l component=kube-apiserver -o wide
kubectl -n kube-system describe pod -l component=kube-apiserver
kubectl -n kube-system logs -l component=kube-apiserver --previous --tail=200

7) Validate ETCD health
kubectl -n kube-system get pods -l component=etcd -o wide
kubectl -n kube-system logs -l component=etcd --tail=200
kubectl -n kube-system describe pod -l component=etcd

*** Disk space & inode pressure on the master node

8) df -h

9) df -i


