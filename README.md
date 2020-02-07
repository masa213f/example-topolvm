# RancherでTopoLVMの動作環境を構築する方法

Rancher + GCPのインスタンスを使って、TopoLVMが動作するKubernetesクラスタを構築する方法を記載している。

GKEは使用せず、RancherのCustom Cluster(RKEでデプロイされるKubernetesクラスタ)を使用している。

本手順では、計4台のVMインスタンスを使用している。役割は以下のとおり。

| ホスト名  | マシンタイプ    | 用途                        | 備考                       |
| --------- | --------------- | --------------------------- | -------------------------- |
| `rancher` | `n1-standard-2` | Rancher Server              | HTTP/HTTPSの通信を許可     |
| `master`  | `n1-standard-2` | Kubernets Masterノード      |                            |
| `worker1` | `n1-standard-2` | Kubernets Worker ノード (1) | SSD追加(TopoLVMで使用する) |
| `worker2` | `n1-standard-2` | Kubernets Worker ノード (2) | SSD追加(TopoLVMで使用する) |

なお、TopoLVMを動かすことを目的としているため、セキュリティは考慮していない。

## 1. Rancher Serverの起動

### Rancher用のVMインスタンスを生成

以下のコマンドを実行し、`asia-northeast1-c`(東京)に、VMインスタンスを生成する。

```bash
ZONE=asia-northeast1-c
gcloud compute instances create rancher \
  --zone ${ZONE} \
  --machine-type n1-standard-2 \
  --image-project ubuntu-os-cloud \
  --image-family ubuntu-1804-lts \
  --boot-disk-size 200GB
```

生成直後は、Firewallの設定により外部からのHTTP/HTTPSの通信がブロックされる。
以下の手順で、HTTP/HTTPSの通信を許可しておく。

1. GCP Console の "VM インスタンス" ページから、上記手順で立ち上げたVMインスタンス`rancher`の設定を開く
2. `EDIT`をクリック
3. `Firewalls`で`Allow HTTP traffic`と`Allow HTTPS traffic`にチェックを入れる
4. `Save`をクリック

### Dockerインストール

```bash
gcloud compute ssh --zone ${ZONE} rancher -- "curl -sSLf https://get.docker.com | sudo sh"
```

### Rancher Serverの起動

```bash
gcloud compute ssh --zone ${ZONE} rancher -- "sudo docker run -d --restart=unless-stopped -p 80:80 -p 443:443 rancher/rancher"
```

ローカルのWebブラウザから、`rancher`のExternal IPにアクセスする。
(証明書の設定をしていないので、警告が出るが気にしない)

初回アクセス時には、adminパスワードの入力が求められるので設定すること。
クラスタからアクセスするためのURLはとりあえずデフォルトでOK。

## 2. Kubernetesクラスタの構築

### ノード生成

GCPでVMインスタンスを生成する。

以下のコマンドを実行すると、`asia-northeast1-c`(東京)に3台のVMインスタンス(`master`、`worker1`、`worker2`)が生成される。
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

WebブラウザからRancherのWeb UIにアクセスする。

「Add Cluster」->「From existing nodes (Custom)」を選択し、新しくクラスタを登録する。

設定値は任意の値でOK(なはず)。動作確認時は、Kubernetsのバージョンをv1.16系、その他の値はデフォルトのままにした。

- Cluster Name: <任意のクラスタ名>
- Cluster Options
  - Kubernetes Version: `v1.16.4-rancher1-1`
  - Node Options:
    1. `etcd`、`Controle Plane`にチェック。表示されているコマンドを`master`上で実行する。
        ```bash
        gcloud compute ssh --zone ${ZONE} master
        # masterにログインした後、コマンドを実行する。
        exit
        ```
    2. `Worker`にチェック。表示されているコマンドを`worker1`、`worker2`上で実行する。
        ```bash
        gcloud compute ssh --zone ${ZONE} worker1
        # worker1にログインした後、コマンドを実行する。
        exit

        gcloud compute ssh --zone ${ZONE} worker2
        # worker2にログインした後、コマンドを実行する。
        exit
        ```
  - この手順が終わると、画面下に"3 new nodes have registered"と表示されるので「Done」。

クラスタ追加後、クラスタのステータスが`Provisioning`から`Active`になるのを待つ。

なお、クラスタのダッシュボードの右上「Kubeconfig File」の内容を、ローカルの`~/.kube/config`にコピーすれば、ローカルから`kubectl`が実行できる。

## 3. Kubernetes上での準備

### cert-managerデプロイ

```
kubectl apply --validate=false -f https://github.com/jetstack/cert-manager/releases/download/v0.12.0/cert-manager.yaml
```

### namespaceにラベル設定

```bash
kubectl label namespace kube-system topolvm.cybozu.com/webhook=ignore
kubectl label namespace cert-manager topolvm.cybozu.com/webhook=ignore
```

## 4. lvmdインストール

### VGの生成

`worker1`、`worker2`上で、VG(VodumeGroup)を生成する。

```bash
gcloud compute ssh --zone ${ZONE} worker1 -- sudo vgcreate myvg /dev/nvme0n1
gcloud compute ssh --zone ${ZONE} worker2 -- sudo vgcreate myvg /dev/nvme0n1
```

### lvmdインストール

以下の手順で`worker1`にlvmdをインストールする。`worker2`も同様に実行する。

```bash
gcloud compute ssh --zone ${ZONE} worker1

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

## 5. TopoLVMデプロイ

```bash
TOPOLVM_VERSION=0.2.2
kubectl apply -k https://github.com/cybozu-go/topolvm/deploy/manifests?ref=v${TOPOLVM_VERSION}
kubectl apply -f https://raw.githubusercontent.com/cybozu-go/topolvm/v${TOPOLVM_VERSION}/deploy/manifests/certificates.yaml
```

## 6. topolvm-schedulerの設定

nodeAffinityとtolerationsを変更し、topolvm-schedulerをmaster上に配置する。

今回の手順でデプロイされるControlPlaneノードには、以下のLabel/Taintが設定されている。

- Label
    1. `node-role.kubernetes.io/controlplane=true`
    2. `node-role.kubernetes.io/etcd=true`
- Taints
    1. `node-role.kubernetes.io/controlplane=true:NoSchedule`
    2. `node-role.kubernetes.io/etcd=true:NoExecute`


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

## 7. Scheduler Extensionの設定

```bash
gcloud compute ssh --zone ${ZONE} master

# VMインスタンス上で以下を実行する。
TOPOLVM_VERSION=0.2.2
sudo mkdir -p /etc/kubernetes/scheduler
sudo curl -sSL -o /etc/kubernetes/scheduler/scheduler-config.yaml https://raw.githubusercontent.com/masa213f/example-topolvm/master/scheduler-config/scheduler-config.yaml
sudo curl -sSL -o /etc/kubernetes/scheduler/scheduler-policy.cfg https://raw.githubusercontent.com/cybozu-go/topolvm/v${TOPOLVM_VERSION}/deploy/scheduler-config/scheduler-policy.cfg

exit
```

- クラスタのダッシュボードから -> 「Edit」
- `Cluster Options`で「Edit as YAML」、以下の変更をする。
```diff
   services:
     ...
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

## 動作確認

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
