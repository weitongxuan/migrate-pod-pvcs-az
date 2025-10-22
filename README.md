# migrate-pod-pvcs-az
自動遷移 Kubernetes Pod 所使用的 EBS gp2 PVC 到指定的 AWS AZ，並在過程中自動縮放（scale down / up）相關的 Deployments 與 StatefulSets。
