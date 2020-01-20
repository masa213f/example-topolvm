# RancherでTopoLVMの動作環境を構築する方法

Rancher + GCPのインスタンスを使って、TopoLVMKubernetesクラスタを構築する。

GKEは使用しないので注意。

## Rancher Serverのデプロイ

Rancher用のGCPインスタンスを生成する。

以下のコマンドは`asia-northeast1-c`(東京)に、VMインスタンスを生成する。

```bash
ZONE=asia-northeast1-c
gcloud compute instances create rancher \
  --zone ${ZONE} \
  --machine-type n1-standard-2 \
  --image-project ubuntu-os-cloud \
  --image-family ubuntu-1804-lts \
  --boot-disk-size 200GB
```

Dockerをインストールする。

```bash
gcloud compute ssh --zone ${ZONE} rancher -- "curl -sSLf https://get.docker.com | sudo sh"
```

Rancherを起動する。

```bash
gcloud compute ssh --zone ${ZONE} rancher -- "sudo docker run -d --restart=unless-stopped -p 80:80 -p 443:443 rancher/rancher"
```

HTTP/HTTPSの通信を許可

1. GCP Console の "VM インスタンス" ページから、上記手順で立ち上げたVMインスタンス`rancher`の設定を開く。
2. `EDIT`をクリック。
3. 3. `Firewalls`で`Allow HTTP traffic`と`Allow HTTPS traffic`にチェックを入れる。
4. `Save`をクリック。

ブラウザで生成したGCPインスタンスにアクセスする。(証明書の設定をしていないので、警告が出るがきにしない。)

初回アクセス時には、adminパスワードの入力が求められるので設定すること。
クラスタからアクセスするためのURLはとりあえずデフォルトでOK。

## Kubernetesクラスタの構築

### ノード生成

GCPでVMインスタンスを生成する。

以下のコマンドを実行すると、`asia-northeast1-c`(東京)で3台のVMインスタンス(`master`、`worker1`、`worker2`)が生成される。
`worker1`、`worker2`には、TopoLVMで使用するために、SSD(`/dev/nvme0`)を追加している。

```bash
ZONE=asia-northeast1-c

gcloud compute instances create master \
  --zone ${ZONE} \
  --machine-type n1-standard-2 \
  --image-project ubuntu-os-cloud \
  --image-family ubuntu-1804-lts \
  --boot-disk-size 200GB

gcloud compute instances create worker1 \
  --zone ${ZONE} \
  --machine-type n1-standard-2 \
  --local-ssd interface=nvme \
  --image-project ubuntu-os-cloud \
  --image-family ubuntu-1804-lts

gcloud compute instances create worker2 \
  --zone ${ZONE} \
  --machine-type n1-standard-2 \
  --local-ssd interface=nvme \
  --image-project ubuntu-os-cloud \
  --image-family ubuntu-1804-lts
```

なお、上記手順で生成したGCPインスタンスを削除する場合は、以下のコマンドを実行すればよい。

```bash
gcloud --quiet compute instances delete master --zone ${ZONE}
gcloud --quiet compute instances delete worker1 --zone ${ZONE}
gcloud --quiet compute instances delete worker2 --zone ${ZONE}
```

### Dockerインストール

各ノードにDockerをインストールする。

```bash
gcloud compute ssh --zone ${ZONE} master -- "curl -sSLf https://get.docker.com | sudo sh"
gcloud compute ssh --zone ${ZONE} worker1 -- "curl -sSLf https://get.docker.com | sudo sh"
gcloud compute ssh --zone ${ZONE} worker2 -- "curl -sSLf https://get.docker.com | sudo sh"
```

### Rancherでクラスタの登録

WebブラウザからRancherにログインする。

「Add Cluster」->「From existing nodes (Custom)」

設定値は以下。

- Cluster Name: <任意のクラスタ名>
- Kubernetes Version: `v1.16.4-rancher1-1`(デフォルト)
- その他はデフォルト
- -> 「Next」

「Cluster Options」

- Node Role: `etcd`、`Controle Plane`にチェック。表示されているコマンドを`master`上でを実行する。
    ```bash
    gcloud compute ssh --zone ${ZONE} master
    # ログイン後、rkeのコマンド実行。
    exit
    ```
- Node Role: `Worker`にチェック。表示されているコマンドを`worker1`、`worker2`上で実行する。
    ```bash
    gcloud compute ssh --zone ${ZONE} worker1
    # ログイン後、rkeのコマンド実行。
    exit

    gcloud compute ssh --zone ${ZONE} worker2
    # ログイン後、rkeのコマンド実行。
    exit
    ```
- この手順が終わると、画面下に"3 new nodes have registered"とでる。
- -> 「Done」
- クラスタのステータスが`Provisioning`から`Active`になるのを待つ。
- クラスタのダッシュボードの右上「Kubeconfig File」の内容を、ローカルの`~/.kube/config`にコピーすれば、ローカルから`kubectl`が実行できる。

### cert-manager インストール

```
kubectl apply --validate=false -f https://github.com/jetstack/cert-manager/releases/download/v0.12.0/cert-manager.yaml
```

## TopoLVMのデプロイ

### lvmdの起動

`worker2`も同様に実行する。

```bash
gcloud compute ssh --zone ${ZONE} worker1

# VMインスタンスにログインし、以下を実行する。
sudo vgcreate myvg /dev/nvme0n1

# lvmd のインストール
TOPOLVM_VERSION=0.2.2
sudo mkdir -p /opt/sbin
curl -sSLf https://github.com/cybozu-go/topolvm/releases/download/v${TOPOLVM_VERSION}/lvmd-${TOPOLVM_VERSION}.tar.gz | sudo tar xzf - -C /opt/sbin

# Serviceの登録
sudo curl -sSL -o /etc/systemd/system/lvmd.service https://raw.githubusercontent.com/cybozu-go/topolvm/v${TOPOLVM_VERSION}/deploy/systemd/lvmd.service
sudo systemctl enable lvmd
sudo systemctl start lvmd

exit
```

### namespaceにラベルを設定

```bash
kubectl label namespace kube-system topolvm.cybozu.com/webhook=ignore
kubectl label namespace cert-manager topolvm.cybozu.com/webhook=ignore
```

### TopoLVMデプロイ

```bash
TOPOLVM_VERSION=0.2.2
kubectl apply -k https://github.com/cybozu-go/topolvm/deploy/manifests?ref=v${TOPOLVM_VERSION}
kubectl apply -f https://raw.githubusercontent.com/cybozu-go/topolvm/v${TOPOLVM_VERSION}/deploy/manifests/certificates.yaml
```

### topolvm-schedulerの設定

nodeAffinityとtolerationsを変更する。

今回の手順でデプロイされるControlPlaneノードには、以下のLabel/Taintが設定されている。

- Label
    1. `node-role.kubernetes.io/controlplane=true`
    2. `node-role.kubernetes.io/etcd=true`
- Taints
    1. `node-role.kubernetes.io/etcd=true:NoExecute`
    2. `node-role.kubernetes.io/controlplane=true:NoSchedule`

topolvm-schedulerのマニフェストを編集する。

```diff
$ kubectl edit daemonset topolvm-scheduler -n topolvm-system
# 以下のように編集
 apiVersion: apps/v1
 kind: DaemonSet
...
 spec:
...
   template:
...
     spec:
       affinity:
         nodeAffinity:
           requiredDuringSchedulingIgnoredDuringExecution:
             nodeSelectorTerms:
             - matchExpressions:
-              - key: node-role.kubernetes.io/master
+              - key: node-role.kubernetes.io/controlplane
                 operator: Exists
...
       tolerations:
       - key: CriticalAddonsOnly
         operator: Exists
-      - effect: NoSchedule
-        key: node-role.kubernetes.io/master
+      - key: node-role.kubernetes.io/controlplane
+        operator: Exists
+      - key: node-role.kubernetes.io/etcd
+        operator: Exists
...
```

### Scheduler Extender

```bash
gcloud compute ssh --zone ${ZONE} master

# VMインスタンス上で以下を実行する。
TOPOLVM_VERSION=0.2.2
sudo mkdir -p /etc/kubernetes/scheduler
sudo curl -sSL -o /etc/kubernetes/scheduler/scheduler-config.yaml https://raw.githubusercontent.com/masa213f/example-topolvm/master/scheduler-config/scheduler-config.yaml
sudo curl -sSL -o /etc/kubernetes/scheduler/scheduler-policy.cfg https://raw.githubusercontent.com/cybozu-go/topolvm/v${TOPOLVM_VERSION}/deploy/scheduler-config/scheduler-policy.cfg
```

- クラスタのダッシュボードから -> 「Edit」
- `Cluster Options`で「Edit as YAML」、以下の変更をする。
```diff
   services:
     etcd:
       backup_config:
         enabled: true
         interval_hours: 12
         retention: 6
         safe_timestamp: false
       creation: 12h
       extra_args:
         election-timeout: '5000'
         heartbeat-interval: '500'
       gid: 0
       retention: 72h
       snapshot: false
       uid: 0
     kube-api:
       always_pull_images: false
       pod_security_policy: false
       service_node_port_range: 30000-32767
     kube-controller: {}
     kubelet:
       fail_swap_on: false
       generate_serving_certificate: false
     kubeproxy: {}
-    scheduler: {}
+    scheduler:
+      extra_args:
+        config: /etc/kubernetes/scheduler/scheduler-config.yaml
   ssh_agent_auth: false
```
- 「Save」

### 動作確認

以下を kubectl applyする。

```yaml
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: topolvm-pvc
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: topolvm-provisioner
---
apiVersion: v1
kind: Pod
metadata:
  name: my-pod
  labels:
    app.kubernetes.io/name: my-pod
spec:
  containers:
  - name: ubuntu
    image: quay.io/cybozu/ubuntu:18.04
    command: ["/usr/local/bin/pause"]
    volumeMounts:
    - mountPath: /test1
      name: my-volume
  volumes:
    - name: my-volume
      persistentVolumeClaim:
        claimName: topolvm-pvc
```
