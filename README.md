# DevOps — GitOps Infra

单节点 OrbStack K3s 集群，ArgoCD App-of-Apps 自管，PostgreSQL 本地开发环境。

## 当前运行状态

| 组件 | 命名空间 | 状态 | 访问 |
|------|---------|------|------|
| ArgoCD | argocd | ✅ Healthy | https://argocd.localhost |
| PostgreSQL 18 | postgresql | ✅ Running | `bootstrap/dev.sh pg` |
| guestbook (示例) | default | ✅ Healthy | — |

## 快速开始

```bash
git clone git@github.com:QuDevLabs/devops.git && cd devops
cp .env.example .env                     # 填 GITHUB_TOKEN（ArgoCD 读 repo 需要）
./bootstrap/dev.sh setup                 # 一键：.env → ArgoCD → helm → secrets → pg 验证
```

setup 过程中 ArgoCD admin 密码和 PostgreSQL 密码会自动生成并写回 `.env`，不需要手动操作。

### 日常

```bash
./bootstrap/dev.sh pg              # 进 psql（自动 port-forward + 加载密码）
./bootstrap/dev.sh pg-status       # Pod + PVC + psql 健康检查
./bootstrap/dev.sh pf               # 手动启动/停止 port-forward
./bootstrap/dev.sh pf-stop
```

### 新增中间件

```bash
# 1. 把 Helm chart 放在 infra/<name>/，Application CRD 放在 bootstrap/apps/<name>.yaml
#    参考 infra/postgresql/ 和 bootstrap/apps/postgresql.yaml

# 2. push 后 ArgoCD root app 自动发现 + sync
git add -A && git commit -m "feat(<name>): add <component>" && git push

# 3. 如果有 runtime secrets（密码不进 Git）
#    - 在 Application CRD 里加 ignoreDifferences for Secret
#    - 在 bootstrap/init-secrets.sh 底部加 inject <ns> <secret> key1=ENV_VAR ...
#    - 执行 ./bootstrap/dev.sh setup 重新注入
```

## 项目结构

```
.
├── AGENTS.md                      # 给 AI/协作者的规则 — invariant、环境 quirks、部署清单
├── README.md                      # 你正在读的
├── .env.example                   # 环境变量模板（git-tracked，不含值）
├── .gitignore
│
├── bootstrap/
│   ├── root-app.yaml              # root Application：扫描 bootstrap/apps/ 下所有 CRD
│   ├── apps/
│   │   ├── argocd.yaml
│   │   └── postgresql.yaml
│   ├── install-argocd.sh          # 一次性 bootstrap（helm install ArgoCD）
│   ├── init-secrets.sh            # 幂等注入 runtime secrets（密码为空自动生成）
│   └── dev.sh                     # 日常入口：setup / pg / pf / pf-stop / pg-status
│
├── argocd/chart/                  # ArgoCD 自己的 Helm umbrella chart
│   ├── Chart.yaml
│   └── values.yaml
│
└── infra/                         # 各中间件的 Helm umbrella chart
    └── postgresql/
        ├── Chart.yaml             # OCI dep → bitnami/postgresql 18.8.17
        ├── Chart.lock             # digest 锁定，必须提交
        └── values.yaml            # 密码通过 existingSecret 注入（无明文）
```

## 安全约定

- `.env`（含所有密码/token）**永远不进 Git** — `.gitignore` 已覆盖
- `.env.example` 只列变量名，含注释，不含值
- 密码注入后，ArgoCD 的 `ignoreDifferences` 保护 Secret `/data` 不被覆盖
- 密码轮换：改 `.env` → `./bootstrap/init-secrets.sh --force`
- GitHub token 只用于 ArgoCD repo-server 读 repo（deploy key 模式）

## 已知局限

| 局限 | 原因 | 规避 |
|------|------|------|
| macOS 主机 → Docker Hub OCI 不通 | OrbStack 网络隔离 | 用 Docker 容器跑 helm（dev.sh setup 自动处理） |
| macOS 主机 → GitHub HTTPS 不通 | 同上 | 用 SSH deploy key push |
| Kubernetes LoadBalancer IP 不可达 | OrbStack lb 映射到 localhost | 用 `*.localhost` 域名，不用 sslip.io |
| 删掉 postgresql namespace = 数据没了 | OrbStack local-path ReclaimPolicy=Delete | 别删 namespace |

## 版本耦合

| 工具 | 版本 | 关系 |
|------|------|------|
| ArgoCD CLI | v3.5.0 | ↕️ 必须与 helm chart 一起 bump |
| helm chart | argo-cd 10.3.0 | ↕️ 必须与 CLI 一起 bump |
| psql (本地) | 18.x | 可选，pg status 用 |
| PostgreSQL (集群内) | 18.6 (bitnami 18.8.17) | 跟随 chart |
