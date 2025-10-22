# 🌀 migrate-pod-pvcs-gp2-az-autoscale

> **自動遷移 Kubernetes Pod 所使用的 EBS gp2 PVC 到指定的 AWS AZ，並在過程中自動縮放（scale down / up）相關的 Deployments 與 StatefulSets。**

---

## 📘 簡介

此腳本能自動完成以下流程：

1. **偵測指定 Pod 所掛載的所有 PersistentVolumeClaim (PVC)**
2. **找出使用這些 PVC 的 Deployments / StatefulSets**
3. **自動 scale down 控制器，避免寫入衝突**
4. **針對 gp2 類型的 EBS Volume：**
   - 建立 snapshot
   - 在指定 AZ 中建立新的 volume
   - 產生新的 PersistentVolume (PV)
   - 重建並重新綁定 PVC
5. **最後自動恢復控制器 (scale up)**

適用於需要跨 AZ 遷移 gp2 EBS-backed PVC 的情境，並確保自動化與安全的操作。

---

## ⚙️ 使用方法

```bash
./migrate-pod-pvcs-gp2-az-autoscale.sh   -n <namespace>   -P <pod_name>   -z <target_az>   -r <region>   [-c <kube_context>] [--dry-run]
```

### 範例

```bash
./migrate-pod-pvcs-gp2-az-autoscale.sh   -n prod-app   -P webserver-7d4b8f56b7-abcde   -z ap-northeast-1c   -r ap-northeast-1   --dry-run
```

---

## 🔑 參數說明

| 參數 | 必填 | 說明 |
|------|------|------|
| `-n`, `--namespace` | ✅ | Pod 所在的 Namespace |
| `-P`, `--pod` | ✅ | 目標 Pod 名稱 |
| `-z`, `--target-az` | ✅ | 目標可用區（例如：`ap-northeast-1c`） |
| `-r`, `--region` | ✅ | AWS Region（例如：`ap-northeast-1`） |
| `-c`, `--context` | ❌ | 指定 `kubectl` context |
| `--dry-run` | ❌ | 啟用模擬模式（不實際修改任何資源） |
| `-h`, `--help` | ❌ | 顯示說明文件 |

---

## 🧰 系統需求

- **AWS CLI v2**
- **kubectl**
- **jq**
- 有效的 AWS IAM 權限，允許：
  - `ec2:DescribeVolumes`
  - `ec2:CreateSnapshot`
  - `ec2:CreateVolume`
  - `ec2:Wait`
- Kubernetes 權限：
  - 可讀取 Pod、PVC、PV、Deployment、StatefulSet
  - 可修改 / 刪除 / 建立 PVC / PV
  - 可縮放控制器 (`kubectl scale`)

---

## 🔄 遷移流程

1. **發現 PVC**
   - 自動解析指定 Pod 掛載的 PVC。
2. **找到相關控制器**
   - 掃描 Namespace 中所有 Deployment / StatefulSet，判斷是否使用這些 PVC。
3. **Scale Down 控制器**
   - 讓關聯 Pod 全部停止運作，避免資料寫入。
4. **為每個 gp2 Volume 執行遷移：**
   - 產生 EBS snapshot
   - 在目標 AZ 中建立新 volume
   - 產生對應的新 PV manifest
   - 重建 PVC 並重新綁定
5. **Scale Up 控制器**
   - 恢復原本的 replicas 數。

---

## 🧪 DRY-RUN 模式

使用 `--dry-run` 可模擬整個流程，不會：

- 實際建立 snapshot 或 volume
- 不會修改 K8s 資源

可用於驗證環境設定與流程預期。

```bash
./migrate-pod-pvcs-gp2-az-autoscale.sh   -n test   -P mypod   -z ap-southeast-1b   -r ap-southeast-1   --dry-run
```

---

## ⚠️ 注意事項

- 僅支援 **EBS gp2 類型** 的 PVC。
- 不會自動更新 Node 的 AZ 規劃（你需確保有對應的 nodegroup 或 affinity 可用）。
- 如果 Pod 使用多個 PVC，腳本會逐一遷移。
- 遷移過程中若發生錯誤，腳本會嘗試自動恢復控制器的 replicas。

---

## 🧩 範例輸出

```
[2025-10-22 10:12:15] Namespace: prod-app ; Pod: web-7d4b8f56b7-abcde ; Region: ap-northeast-1 ; Target AZ: ap-northeast-1c
[2025-10-22 10:12:15] Found PVCs: data-web-0 logs-web-0
[2025-10-22 10:12:16] Scaling down Deployment/web from replicas=3 -> 0 ...
[2025-10-22 10:12:55] Snapshot snap-0123456789abcdef created; waiting to complete...
[2025-10-22 10:14:22] Created new volume: vol-0123456789abcdef in ap-northeast-1c
[2025-10-22 10:14:45] PVC data-web-0 migrated successfully.
[2025-10-22 10:15:00] Restoring Deployment/web -> replicas=3
[2025-10-22 10:15:05] All done. Controllers restored.
```

---

## 🧠 工作原理摘要

- 利用 `kubectl` 查詢 Pod、PVC、PV 與控制器關聯。
- 使用 `jq` 處理 JSON 資料。
- 利用 AWS CLI 操作 EC2 volume 與 snapshot。
- 動態產生新的 PV YAML 並重新套用 PVC。
- 使用 trap 機制確保異常中斷時仍能安全恢復環境。

---

## 🧾 License

MIT License © 2025 — Simon Wei

---

## 💬 貢獻

歡迎 issue / PR，建議改進：

- 支援 gp3 自動轉換
- 支援跨帳號 snapshot 分享
- 增加非 EBS 類型檢查
