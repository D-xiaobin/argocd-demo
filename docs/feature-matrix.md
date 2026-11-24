# 功能验证手册

每一项都是「怎么做 → 看什么 → 预期结果」。命令默认在仓库根目录执行。

前置：`kubectl apply -f bootstrap/root-app.yaml` 已经跑过，`argocd app list` 能看到 11 个应用。

---

## 1. 基础 Application 与三种同步策略

```bash
argocd app get basic-yaml
```

预期 `Synced / Healthy`。三个应用分别代表三种策略：

| 应用 | 策略 | 验证方式 |
|---|---|---|
| `basic-yaml` | 自动 + prune + selfHeal | 手动改副本数，30 秒内被改回 |
| `kustomize-dev` | 自动 + prune + selfHeal | 同上 |
| `kustomize-prod` | **手动** | 改 Git 后显示 `OutOfSync`，需点 SYNC |

```bash
# 制造漂移
kubectl -n demo-basic scale deploy basic-app --replicas=5
kubectl -n demo-basic get deploy basic-app -w
```

预期：副本数自己回到 2（`selfHeal`）。再试 prod：

```bash
kubectl -n demo-prod scale deploy prod-kustomize-app --replicas=5
argocd app get kustomize-prod      # OutOfSync，但不会自动修
```

---

## 2. Kustomize 分层

```bash
kubectl kustomize apps/02-kustomize/overlays/dev  | grep -E 'namespace|APP_ENV|replicas'
kubectl kustomize apps/02-kustomize/overlays/prod | grep -E 'namespace|APP_ENV|replicas|cpu'
```

预期：

- dev：`namespace: demo-dev`、`APP_ENV: dev`、`replicas: 1`
- prod：`namespace: demo-prod`、`APP_ENV: prod`、`replicas: 3`、`cpu: 500m`

集群里验证前缀也生效了：

```bash
kubectl -n demo-prod get deploy    # 名字是 prod-kustomize-app
```

---

## 3. Helm 参数覆盖

```bash
argocd app manifests helm-app | grep -E 'replicas|APP_ENV|port'
kubectl -n demo-helm get cm demo-helm-helm-config -o yaml | grep -E 'APP_ENV|LOG_LEVEL'
```

预期：`replicas: 2`（来自 `valuesObject`）、`APP_ENV: helm-from-argocd`、Service 端口 `8080`（来自 `parameters`）。

---

## 4. 多源 Application

```bash
argocd app get multi-source -o yaml | sed -n '/sources:/,/destination:/p'
kubectl -n demo-multi get deploy podinfo-multi -o jsonpath='{.spec.replicas}'
kubectl -n demo-multi get cm -o name | head
```

预期：副本数 2（来自 Git 里的 `values-prod.yaml`，不是 Chart 默认值）。

改 `apps/04-multi-source/values-prod.yaml` 里的 `replicaCount: 3` 并提交，几十秒后副本数变 3 —— 这证明 values 确实来自 Git 而不是 Chart。

---

## 5. sync-wave 顺序

```bash
argocd app sync sync-waves
kubectl -n demo-waves get events --sort-by=.lastTimestamp | grep -E 'Namespace|ConfigMap|Deployment|Service|Job' | tail -20
```

预期：Namespace → ConfigMap → Deployment → Service → Job 依次出现。UI 里能看到资源分批变绿。

---

## 6. 五种 hook

```bash
argocd app sync hooks
kubectl -n demo-hooks get jobs -w
```

预期顺序：

1. `presync-check` 先跑（PreSync）
2. `sync-migrate` 与资源一起跑（Sync）
3. 资源健康后 `postsync-smoke` 跑（PostSync），并且因为 `HookSucceeded` 策略，成功后 Job 被自动删除
4. `skip-me` 这个 ConfigMap **不存在**于集群（Skip）：

```bash
kubectl -n demo-hooks get cm skip-me    # NotFound 才对
```

想看 SyncFail：让 `hooks` 应用同步失败（比如把某个镜像改成不存在的 tag），`syncfail-alert` 会被触发。

---

## 7. 自定义健康检查

```bash
# 给 Deployment 打上标记，触发自定义 Lua 逻辑
kubectl -n demo-basic annotate deploy/basic-app demo.argocd/slow-rollout=true

argocd app get basic-yaml --refresh
```

预期：健康状态从 `Healthy` 变成 `Progressing`，message 显示「自定义健康检查：被标记为滚动中」。

```bash
kubectl -n demo-basic annotate deploy/basic-app demo.argocd/slow-rollout-
```

去掉后恢复 `Healthy`。

---

## 8. ignoreDifferences

```bash
# 让 HPA 把副本数拉到 3
kubectl -n demo-ignore patch hpa hpa-app --type merge -p '{"spec":{"minReplicas":3}}'
kubectl -n demo-ignore get deploy hpa-app -w
```

预期：副本数变成 3，但 `argocd app get ignore-differences` 仍然是 **Synced**（因为 `/spec/replicas` 被忽略了）。

对照实验：把 `advanced.yaml` 里 `ignoreDifferences` 那段注释掉再同步，就会看到 `OutOfSync`。

---

## 9. 资源级 sync-options

**Prune=false**：把 `apps/08-sync-options/manifest.yaml` 里 `keep-on-prune` 那个 ConfigMap 删掉并提交，同步后：

```bash
kubectl -n demo-options get cm keep-on-prune   # 仍然存在
argocd app get sync-options                    # 显示 Synced，但 UI 里该资源标着 Prune=false
```

**Delete=false**：删掉整个 Application，Secret 仍在：

```bash
argocd app delete sync-options --cascade=true
kubectl -n demo-options get secret keep-on-delete   # 仍然存在
```

---

## 10. 失败重试与 Degraded

```bash
argocd app get failing-sync
kubectl -n demo-fail get jobs
kubectl -n demo-fail logs job/will-fail
```

预期：

- `operationState.phase: Failed`，`message` 里带 Job 失败原因
- 重试 2 次（`retry.limit: 2`），间隔 10s、20s
- `fail-syncfail-hook` 被创建
- 应用健康状态 `Degraded`

手动重试：

```bash
argocd app sync failing-sync
```

---

## 11. 孤儿资源

```bash
kubectl -n demo-orphan create configmap i-am-orphan --from-literal=why=manual
```

UI 里打开 `orphan-demo` → **APP DETAILS** → 出现 `Orphaned resources` 面板，列出 `i-am-orphan`。

命令行：

```bash
argocd app get orphan-demo -o json | jq '.status.resources[] | select(.requiresPruning==true)'
```

清理：

```bash
kubectl -n demo-orphan delete cm i-am-orphan
```

---

## 12. AppProject 边界

**来源限制**：把某个 Application 的 `repoURL` 改成一个不在 `sourceRepos` 里的地址，同步会报：

```
application repo https://github.com/xxx/yyy.git is not permitted in project 'team-a'
```

**命名空间限制**：把 destination 改成 `default`：

```
namespace 'default' for deployment 'xxx' is not allowed in project 'team-a'
```

**发布窗口**：`team-a` 配了周日 02:00–04:00 禁止同步。用 `argocd app sync` 会提示被 window 阻止（`manualSync: true` 表示手动同步可以绕过）。

---

## 13. RBAC

```bash
# 用不同身份问「我能做什么」
argocd account can-i sync applications 'team-a/basic-yaml'
argocd account can-i delete applications 'team-a/basic-yaml'

# 模拟 ci-bot 身份
argocd account can-i sync applications 'team-a/basic-yaml' --sub ci-bot
argocd account can-i delete applications 'team-a/basic-yaml' --sub ci-bot   # 应该 false
```

`policy.default: role:readonly` 的效果：任何没有匹配策略的用户只能读。

---

## 14. 通知

把 `config/argocd-notifications-cm.yaml` 里的 `url` 换成一个你能收到请求的地址（本地调试可以用 `https://webhook.site` 拿一个临时 URL），apply 后同步任意应用：

```bash
argocd app sync basic-yaml
kubectl -n argocd logs deploy/argocd-notifications-controller --tail=50
```

预期：webhook 收到 `{"app":"basic-yaml","sync":"Synced",...}`。

---

## 15. ApplicationSet 五种生成器

```bash
kubectl -n argocd get appset
kubectl -n argocd get applications -l demo=applicationset
```

| 生成器 | 应生成 | 验证 |
|---|---|---|
| list | `list-dev`、`list-staging` | 两个命名空间各有一个 Deployment |
| git directories | `dirs-dev`、`dirs-prod` | 跟随 overlay 目录数量 |
| git files | `files-dev`、`files-prod` | 副本数分别 1 和 3 |
| clusters | `cluster-in-cluster` | 注册新集群后自动多一个 |
| merge | `merge-in-cluster` | 副本数 2（来自 list 覆盖） |

**动态验证 git directories**：新建 `apps/02-kustomize/overlays/staging/`（复制 dev 改个名），提交后：

```bash
kubectl -n argocd get applications | grep dirs-
```

预期自动多出 `dirs-staging`。

---

## 16. App of Apps

```bash
argocd app get root
argocd app list -o name | grep -c .
```

预期：`root` 的 resources 列表里包含 2 个 AppProject + 11 个 Application。

**验证 prune**：在 `argocd/apps/advanced.yaml` 里删掉 `orphan-demo` 那段并提交，同步后该 Application 会被删除（因为 `root` 开了 `prune: true`）。

---

## 17. 多集群

```bash
# 用第二个集群的 kubeconfig 生成 Secret
./scripts/kubeconfig2argocd.sh <context名> spoke
kubectl apply -f cluster-spoke.yaml

argocd cluster list
kubectl -n argocd get applications | grep cluster-    # as-clusters 自动多一个
```

预期：`as-clusters` 和 `as-merge` 都会为新集群生成应用 —— 这就是「加一个 Secret 就多管一个集群」。

---

## 18. 镜像自动更新

```bash
kubectl -n argocd get imageupdater
kubectl -n argocd logs deploy/argocd-image-updater --tail=100 | grep -i basic-yaml
```

预期：日志里出现 `basic-yaml` 的镜像检查记录。有符合 `allowTags` 正则的新 tag 时，会写回 Application 的 `kustomize.images` 字段。

> 这个功能需要单独安装 argocd-image-updater，且仓库要有写权限（`writeBackConfig.method: argocd` 时写 Application，`git` 时写仓库）。

---

## 19. 资源追踪方式

3.x 默认用 annotation 追踪资源归属：

```bash
kubectl -n demo-basic get deploy basic-app \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{"\n"}'
```

预期输出形如 `basic-yaml:apps/Deployment:demo-basic/basic-app`。

对比 2.x 的 label 方式：

```bash
kubectl -n demo-basic get deploy basic-app -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/instance}{"\n"}'
```

如果想把追踪方式改回 label（迁移期兼容），在 `argocd-cm` 里加 `application.resourceTrackingMethod: label`。

---

## 20. 删除保护

`basic-yaml` 带了 `resources-finalizer.argocd.argoproj.io`：

```bash
kubectl -n argocd delete application basic-yaml
kubectl -n demo-basic get deploy    # 资源被级联删除
```

去掉 finalizer 再删，资源会留在集群里（变成孤儿）。

---

## 一次跑完所有验证

```bash
#!/usr/bin/env bash
set -uo pipefail
for app in $(argocd app list -o name); do
  printf '%-20s ' "$app"
  argocd app get "$app" -o json | jq -r '"\(.status.sync.status) / \(.status.health.status)"'
done
```

预期输出（`failing-sync` 除外）：

```
basic-yaml           Synced / Healthy
hooks                Synced / Healthy
...
failing-sync         OutOfSync / Degraded
```
