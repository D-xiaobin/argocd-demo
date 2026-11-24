# argocd-demo

一个用来**把 Argo CD 的主要功能都跑一遍**的演示仓库。

不是「Hello World」级别的单应用示例，而是一套覆盖 20 个功能点的测试床：从最基础的 Application 到 sync-wave、五种 hook、多源、ApplicationSet 五种生成器、RBAC、通知、镜像自动更新、孤儿资源检测。

配合《Argo CD 学习手册》第 3~8 章使用效果最好；每个功能点怎么验证、预期什么结果，见 [docs/feature-matrix.md](docs/feature-matrix.md)。

---

## 快速开始

### 0. 前置条件

| 依赖 | 版本 | 说明 |
|---|---|---|
| Kubernetes | 1.27+ | kind / k3s / ACK / EKS 都行 |
| Argo CD | **3.4+**（推荐 3.6.x） | 3.x 的资源追踪默认用 annotation |
| kubectl | 1.27+ | |

```bash
# 如果还没有 Argo CD
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.6.1/manifests/install.yaml
kubectl -n argocd wait --for=condition=available deploy --all --timeout=300s
```

### 1. Fork 或克隆本仓库

```bash
git clone https://github.com/D-xiaobin/argocd-demo.git
cd argocd-demo
```

### 2. 把占位地址换成你自己的仓库

所有 YAML 里的 `repoURL` 已经是 `https://github.com/D-xiaobin/argocd-demo.git`，**直接 apply 就能跑**，不用改。

只有当你 fork 到自己账号下时才需要替换：

```bash
chmod +x scripts/*.sh
./scripts/set-repo-url.sh <你的GitHub用户名>

git add -A && git commit -m "chore: set repo url" && git push
```

### 3. 应用 App-of-Apps 入口

```bash
kubectl apply -f bootstrap/root-app.yaml
```

`root` 这个 Application 会递归扫描 `argocd/` 目录，把 2 个 AppProject 和 11 个 Application 全部创建出来。

### 4. 观察

```bash
argocd app list
argocd app get root
kubectl -n argocd get applications
```

UI 里应该看到一棵树：`root` 下面挂着 `basic-yaml`、`kustomize-dev`、`hooks`、`failing-sync` 等。

> 首次同步需要 1~3 分钟（要拉镜像）。`failing-sync` 会一直是红色，**这是故意的**，用来演示失败重试与 SyncFail hook。

### 5. 可选：应用 Argo CD 自身配置

`config/` 下的三个 ConfigMap 不会自动生效（避免覆盖你现有的 Argo CD 配置），需要手动 apply：

```bash
kubectl -n argocd apply -f config/argocd-cm.yaml
kubectl -n argocd apply -f config/argocd-rbac-cm.yaml
kubectl -n argocd apply -f config/argocd-notifications-cm.yaml

kubectl -n argocd rollout restart deploy/argocd-server statefulset/argocd-application-controller
```

> ⚠️ 用 `apply`，不要用 `replace`。`replace` 会把 Argo CD 安装时写入的其他 key 全部丢掉。

---

## 目录结构

```
argocd-demo/
├── bootstrap/
│   └── root-app.yaml              # App of Apps 入口
├── argocd/                        # 被 root 递归管理
│   ├── projects/
│   │   ├── team-a.yaml            # 业务项目：限制仓库/命名空间/发布窗口
│   │   └── platform.yaml          # 平台项目：管 Argo CD 自身
│   └── apps/
│       ├── core.yaml              # 5 个：基础/Kustomize 双环境/Helm/多源
│       └── advanced.yaml          # 6 个：波浪/钩子/忽略差异/同步选项/失败/孤儿
├── apps/                          # 真正被部署的清单
│   ├── 01-basic-yaml/             # 纯 YAML
│   ├── 02-kustomize/              # base + dev/prod overlay
│   ├── 03-helm/                   # 自建 Chart
│   ├── 04-multi-source/           # 多源用的 values 文件
│   ├── 05-sync-waves/             # sync-wave 顺序
│   ├── 06-hooks/                  # 五种 hook
│   ├── 07-ignore-differences/     # Deployment + HPA
│   ├── 08-sync-options/           # Prune=false / Delete=false / Replace
│   ├── 09-failing-sync/           # 故意失败的 Job
│   └── 10-orphan/                 # 孤儿资源检测
├── applicationsets/               # 5 种生成器
│   ├── 01-list.yaml
│   ├── 02-git-directories.yaml
│   ├── 03-git-files.yaml
│   ├── 04-clusters.yaml
│   ├── 05-merge.yaml
│   └── params/                    # git files 生成器读取的环境参数
├── config/                        # Argo CD 自身配置（手动 apply）
│   ├── argocd-cm.yaml             # 自定义健康检查 / 比对选项
│   ├── argocd-rbac-cm.yaml        # 三个角色 + 组映射
│   ├── argocd-notifications-cm.yaml
│   ├── image-updater.yaml         # ImageUpdater CRD
│   └── cluster-secret-example.yaml
└── docs/
    └── feature-matrix.md          # 20 个功能点的逐项验证方法
```

---

## 功能覆盖

| # | 功能 | 对应文件 |
|---|---|---|
| 1 | 基础 Application（纯 YAML） | `argocd/apps/core.yaml` |
| 2 | 自动同步 / 自愈 / 清理 | 同上（`syncPolicy.automated`） |
| 3 | 手动同步（生产模式） | `kustomize-prod` |
| 4 | Kustomize base + overlay + patch | `apps/02-kustomize/` |
| 5 | Helm valuesObject + parameters | `apps/03-helm/` |
| 6 | 多源 Application（`sources` + `ref`） | `multi-source` |
| 7 | sync-wave 顺序 | `apps/05-sync-waves/` |
| 8 | PreSync / Sync / PostSync / SyncFail / Skip | `apps/06-hooks/` |
| 9 | 自定义健康检查（Lua） | `config/argocd-cm.yaml` |
| 10 | ignoreDifferences + RespectIgnoreDifferences | `apps/07-ignore-differences/` |
| 11 | 资源级 sync-options | `apps/08-sync-options/` |
| 12 | 失败重试 + Degraded | `apps/09-failing-sync/` |
| 13 | 孤儿资源检测 | `apps/10-orphan/` |
| 14 | AppProject 五种边界 | `argocd/projects/team-a.yaml` |
| 15 | RBAC（角色 / 组 / 默认只读） | `config/argocd-rbac-cm.yaml` |
| 16 | 通知（trigger + template + webhook） | `config/argocd-notifications-cm.yaml` |
| 17 | 镜像自动更新（ImageUpdater CRD） | `config/image-updater.yaml` |
| 18 | ApplicationSet 五种生成器 | `applicationsets/` |
| 19 | App of Apps | `bootstrap/root-app.yaml` |
| 20 | 多集群注册 | `config/cluster-secret-example.yaml` |

每一项的**具体验证命令和预期结果**见 [docs/feature-matrix.md](docs/feature-matrix.md)。

---

## 几个设计说明

**为什么 `failing-sync` 一直是红的？** 它的 Job 故意 `exit 1`，用来演示重试退避、`Degraded` 状态和 `SyncFail` hook。不想看红色就删掉 `argocd/apps/advanced.yaml` 里那一段。

**为什么 `config/` 不纳入 App of Apps？** 让 Argo CD 管理自己的 `argocd-cm` 很容易在实验时把 UI 配置改坏（比如把 `policy.default` 设成只读，然后发现自己点不动了）。拆出来手动 apply，出错时好恢复。

**为什么用 `demo-*` 前缀的命名空间？** 方便一次性清理：`kubectl get ns | grep demo- | xargs kubectl delete ns`。同时 AppProject 的 `destinations` 用 `demo-*` 通配，能验证项目边界确实生效。

---

## 清理

```bash
# 1. 删掉 root（会级联删除所有子 Application 和它们管理的资源）
kubectl -n argocd delete application root --cascade=foreground

# 2. 如果还有残留命名空间
kubectl get ns -o name | grep 'namespace/demo-' | xargs -r kubectl delete

# 3. 恢复 Argo CD 自身配置（可选）
kubectl -n argocd rollout restart deploy/argocd-server statefulset/argocd-application-controller
```

---

## 常见问题

| 现象 | 原因 | 解决 |
|---|---|---|
| `ComparisonError: repository not found` | 没替换 `D-xiaobin` | 跑 `scripts/set-repo-url.sh` |
| 应用一直 `Unknown` | 仓库是私有的，Argo CD 没凭证 | `argocd repo add` 加凭证，或用公开仓库 |
| `namespace demo-xxx is not allowed` | AppProject 的 destinations 没匹配上 | 检查 `team-a.yaml` 的 `demo-*` 通配 |
| ApplicationSet 没生成应用 | 生成器路径没匹配到文件 | `kubectl -n argocd get appset -o yaml` 看 `status.conditions` |
| `failing-sync` 卡在 Running | 重试退避中 | 等 30 秒，或 `argocd app terminate-op failing-sync` |
| 改了 `argocd-cm` 后 UI 行为异常 | 配置写错 | `kubectl -n argocd edit cm argocd-cm` 改回来，或重装 |

---

## License

MIT
