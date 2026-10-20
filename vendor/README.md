# vendor — 固化的节点内核二进制

本目录存放脚本安装节点时使用的**固定版本**二进制。脚本**只从这里下载**，不再跟随上游 `latest`。

## 为什么固化

上游更新会直接破坏兼容，历史上踩到的：

- **Xray**：26.x 移除 TLS 客户端的 `allowInsecure`（改用 `pinnedPeerCertSha256`），且该字段类型从数组变成字符串。脚本自测配置因此报错，节点装完无法验证。
- **Hysteria**：仓库从 `apernet/hysteria` 迁移，`/releases/latest` 返回 301，自动化解析失效。
- **TUIC**：项目已停在 `tuic-server-1.0.0`，上游无新版本，动态查版本号毫无意义还会失败。

固化后：版本可预期、行为一致、小机器上的安装结果稳定。

## 当前锁定版本

| 内核 | 版本 | 架构 |
| --- | --- | --- |
| Xray | `v26.3.27` | 64 / arm64-v8a / arm32-v7a / 32 |
| Hysteria | `app-v2.13.0` | amd64 / arm64 / arm / 386 |
| TUIC | `tuic-server-1.0.0` | 10 个 linux 变体（gnu + musl） |

TUIC 收录 musl 变体是为了 Alpine 小机器能直接跑（脚本会按 `tuic_arch_candidates` 逐个尝试）。

## 完整性校验

`SHA256SUMS` 记录了每个文件的 sha256，路径相对**仓库根**。脚本安装前必定校验：

- 下载后本地计算 sha256（`sha256sum`，缺失时回退 `openssl dgst`）
- 与 `SHA256SUMS` 比对，不一致**直接拒绝安装**，不做任何降级尝试
- 清单里查不到该文件同样拒绝

校验值来源可信：Xray 对官方 `.dgst`、Hysteria 对官方 `hashes.txt`、TUIC 对官方 `.sha256sum`，三者逐条比对一致后才落库。

## 自己校验

```bash
cd <repo 根>
sha256sum -c vendor/SHA256SUMS
```

## 如何升级版本

1. 从上游 release 下载新版本的全部架构文件
2. 与上游官方校验值（`.dgst` / `hashes.txt` / `.sha256sum`）逐条比对
3. 新建 `vendor/<内核>/<新版本>/` 目录放入文件，删除旧版本目录
4. 重新生成 `vendor/SHA256SUMS`：
   ```bash
   find vendor -type f -not -name SHA256SUMS -exec sha256sum {} \; | sort -k2 > vendor/SHA256SUMS
   ```
5. 同步修改脚本顶部三个变量：`VENDOR_XRAY_TAG` / `VENDOR_HY_TAG` / `VENDOR_TUIC_TAG`
6. 跑一遍对应节点安装（含自测），确认通过后再提交

**注意**：升级 Xray 前先确认脚本用到的配置字段在新版仍然有效。26.x 那次字段改动就是例子——升级内核必须连带验证脚本生成的配置。
