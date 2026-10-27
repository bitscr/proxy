# proxy

## 一键安装节点

```bash
curl -fsSL https://raw.githubusercontent.com/bitscr/proxy/main/scripts/np.sh -o np.sh && chmod +x np.sh && ./np.sh
```

装好后可直接重跑：`bash <(curl -Ls https://raw.githubusercontent.com/bitscr/proxy/main/scripts/np.sh)`

## 五个节点类型

1. Hysteria2
2. VLESS Reality
3. Tuic-V5
4. VLESS+WS（支持直连 / Cloudflare CDN 回源）
5. SOCKS5（sing-box，可自动上传到链式代理面板）

## 支持的环境

- Debian / Ubuntu / CentOS / Alpine（musl）
- amd64 / arm64 / armv7 / s390x
- systemd / OpenRC（Alpine）/ 无 init
- 低内存机器（122MB 可跑，自动低内存档）

所有节点内核二进制固化在 `vendor/`，安装时强制 sha256 校验，不跟随上游 latest。