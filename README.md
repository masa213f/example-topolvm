# RancherでTopoLVMの動作環境を構築する方法

Rancher + GCPのインスタンスを使って、TopoLVMKubernetesクラスタを構築する。

GKEは使用しないので注意。

## Rancherのデプロイ

Rancher用のGCPインスタンスを生成する。

```
gcloud compute instances create rancher \
  --zone asia-northeast1-c \
  --machine-type n1-standard-2 \
  --image-project ubuntu-os-cloud \
  --image-family ubuntu-1804-lts \
  --boot-disk-size 200GB
```

Dockerを起動する。

```
gcloud compute ssh --zone asia-northeast1-c rancher -- "curl -sSLf https://get.docker.com | sudo bash /dev/stdin"
```

Rancherを起動する。

```
gcloud compute ssh --zone asia-northeast1-c rancher -- "sudo docker run -d --restart=unless-stopped -p 80:80 -p 443:443 rancher/rancher"
```

HTTP/HTTPSの通信を許可

```
gcloud compute firewall-rules create rancher --allow tcp:80,tcp:443
```

ブラウザで生成したGCPインスタンスにアクセスする。

初回アクセス時には、adminパスワードの入力が求められるので設定すること。
クラスタからアクセスするためのURLはとりあえずデフォルトでOK。

## Kubernetesクラスタの構築

### ノード生成

GCPでVMインスタンスを生成する。

以下のコマンドを実行すると、`asia-northeast1-c`(東京)で3台のVMインスタンス(`node1`、`node2`、`node3`)が生成される。

実行するスクリプトの内容は[こちら](scripts/setup-node.sh)。

```
curl -sSLf https://raw.githubusercontent.com/masa213f/example-topolvm/master/scripts/setup-node.sh | bash /dev/stdin
```

なお、上記手順で生成したGCPインスタンスを削除する場合は、以下のコマンドを実行すればよい。

```
gcloud --quiet compute instances delete node1 --zone asia-northeast1-c
gcloud --quiet compute instances delete node2 --zone asia-northeast1-c
gcloud --quiet compute instances delete node3 --zone asia-northeast1-c
```

### Dockerインストール

各ノードにDockerをインストールする。

```
gcloud compute ssh --zone asia-northeast1-c node1 -- "curl -sSLf https://get.docker.com | sudo bash /dev/stdin"
gcloud compute ssh --zone asia-northeast1-c node2 -- "curl -sSLf https://get.docker.com | sudo bash /dev/stdin"
gcloud compute ssh --zone asia-northeast1-c node3 -- "curl -sSLf https://get.docker.com | sudo bash /dev/stdin"
```

### Rancherでクラスタの登録

WebブラウザからRancherにログインする。

「Add Cluster」->「From existing nodes (Custom)」

設定値は以下。

- Cluster Name: <任意のクラスタ名>
- Kubernetes Version: `v1.16.3-rancher1-1`(デフォルト)
- Network Provider: `Canal (Network Isolation Available)`(デフォルト)
- -> 「Next」

「Cluster Options」

- Node Role: `etcd`、`Controle Plane`にチェック、`node1`上で表示されているコマンドを実行。
- Node Role: `etcd`、`Controle Plane`にチェック、`node2`、`node3`上で表示されているコマンドを実行。  
    ※ GCPインスタンスへSSHする方法は以下。
    ```
    gcloud compute ssh --zone asia-northeast1-c node1
    gcloud compute ssh --zone asia-northeast1-c node2
    gcloud compute ssh --zone asia-northeast1-c node3
    ```
- この手順が終わると、画面下に"3 new nodes have registered"とでる。
- -> 「Done」
- クラスタのステータスが`Provisioning`から`Active`になるのを待つ。
- クラスタのダッシュボードの右上「Kubeconfig File」の内容を、ローカルの`~/.kube/config`にコピーすれば、ローカルから`kubectl`が実行できる。

## TopoLVMのデプロイ

### lvmdインストール

node2、3にlvmdをインストールする。

以下のコマンドを実行すると、ノード上でダミーファイル(5GiB)を生成し、そのダミーファイルを使って、ボリュームグループの生成 及び `lvmd` の起動を行う。

実行するスクリプトの内容は[こちら](scripts/setup-lvmd.sh)。

```
gcloud compute ssh --zone asia-northeast1-c node2 -- "curl -sSLf https://raw.githubusercontent.com/masa213f/example-topolvm/master/scripts/setup-lvmd.sh | sudo bash /dev/stdin"
gcloud compute ssh --zone asia-northeast1-c node3 -- "curl -sSLf https://raw.githubusercontent.com/masa213f/example-topolvm/master/scripts/setup-lvmd.sh | sudo bash /dev/stdin"
```

### `kube-system`にラベルを設定

```
kubectl label namespace kube-system topolvm.cybozu.com/webhook=ignore
```

### TopoLVMデプロイ

```
git clone git@github.com:cybozu-go/topolvm.git
cd topolvm/example
git checkout -b v0.2.2

# make setup でもいい
go install github.com/cloudflare/cfssl/cmd/cfssl
go install github.com/cloudflare/cfssl/cmd/cfssljson

make ./build/certs/server.csr ./build/certs/server.pem ./build/certs/server-key.pem
kubectl apply -k .
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

```
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
       - effect: NoSchedule
-        key: node-role.kubernetes.io/master
+        key: node-role.kubernetes.io/controlplane
+        operator: Exists
+      - effect: NoExecute
+        key: node-role.kubernetes.io/etcd
+        operator: Exists
...
```

### 動作確認

```
kubectl apply -f podpvc.yaml
```
