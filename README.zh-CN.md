# rimg

[English](README.md)

`rimg` 用于加速 Emacs 中的远程图片浏览，同时保留 TRAMP、Dired 和
Image-Dired 原有的职责。Emacs 继续负责远程文件管理；远端 Linux 主机上的小型
Go 进程负责解码图片、生成尺寸受限的缩略图和预览图，并在数据源附近缓存结果。

因此 Image-Dired 只需通过 SSH 传输缩略图大小的数据，而不必反复下载完整原图。

## 功能

- 支持单跳 TRAMP `/ssh:` 和 `/sshx:` 路径。
- 保留 Dired 文件管理能力以及每张图片的远程原始路径。
- 自动将版本化的 `rimgd` 二进制安装到远端。
- 通过 SSH 隧道连接权限受限的远端 Unix socket；`rimgd` 不监听远端 TCP 端口。
- 在 Linux amd64/arm64 上生成并缓存 JPEG、PNG 和 WebP 图片的缩略图。
- 使用远端与本地两级缓存，并根据文件元数据重新验证缓存。
- `RET` 打开尺寸受限的本地预览；打开远程原图必须显式执行。
- 大目录按每页 200 张分页，并按视口懒加载，只请求可见行和少量预取行。
- 预先创建固定画廊槽位，并行响应不会打乱图片顺序、移动选中项或改变网格宽度。

## 环境要求

本机：

- GNU Emacs 32 或更高版本。
- 支持“本地 TCP 转发到远端 Unix socket”的 OpenSSH。
- 构建 Linux 服务端产物时需要 Go 1.25 或更高版本。

远端：

- amd64 或 arm64 架构的 Linux。
- 可以通过单跳 TRAMP `/ssh:` 或 `/sshx:` 路径登录。
- 可以在 `~/.cache/rimg/` 以及 `/run/user/$UID` 或 `/tmp` 下的私有运行目录中创建文件。

## 安装

克隆仓库并构建两个静态 Linux 服务端产物：

```sh
git clone https://github.com/douo/rimg.git ~/.emacs.d/site-lisp/rimg
make -C ~/.emacs.d/site-lisp/rimg dist
```

在 Emacs 配置中加入客户端：

```elisp
(add-to-list 'load-path
             (expand-file-name "~/.emacs.d/site-lisp/rimg/emacs"))
(require 'rimg)
```

使用 `use-package` 时：

```elisp
(use-package rimg
  :load-path "~/.emacs.d/site-lisp/rimg/emacs"
  :commands (rimg-dired
             rimg-reconnect
             rimg-disconnect
             rimg-clear-local-cache
             rimg-prune-remote-cache))
```

默认情况下，Emacs 客户端会在仓库的 `dist/` 目录中查找
`rimgd-linux-amd64` 和 `rimgd-linux-arm64`。如果产物位于其他目录，请设置
`rimg-server-binary-directory`。

## 使用方法

1. 在 Dired 中打开远程图片目录，例如：

   ```text
   /ssh:example-host:/srv/images/
   ```

2. 执行 `M-x rimg-dired`。
3. 使用 Image-Dired 原有命令浏览画廊。

附加按键：

| 按键 | 操作 |
| --- | --- |
| `RET` | 打开尺寸受限且缓存在本地的预览图 |
| `C-RET` | 显式通过 TRAMP 打开远程原图 |
| `]` | 下一页 |
| `[` | 上一页 |

维护命令：

| 命令 | 用途 |
| --- | --- |
| `M-x rimg-reconnect` | 重建当前远端会话 |
| `M-x rimg-disconnect` | 停止 SSH 会话和远端 `rimgd` |
| `M-x rimg-clear-local-cache` | 清理当前远端对应的本地缓存 |
| `M-x rimg-prune-remote-cache` | 按时间和总大小清理远端缓存 |

## 工作原理

`rimg` 将控制面与图片数据面分开：

```text
控制面
Emacs -> Dired/TRAMP -> 远程路径、目录列表、标记和文件操作

图片数据面
远程原图
  -> rimgd 解码与缩放
  -> 持久化远端缓存
  -> 每会话 Unix socket
  -> OpenSSH 本地转发
  -> 127.0.0.1 临时端口
  -> 持久化本地缓存
  -> Image-Dired
```

### 1. 引导与会话生命周期

Emacs 客户端解析 TRAMP 目标、检测远端 Linux 架构，然后通过 TRAMP 将对应的
静态二进制复制到 `~/.cache/rimg/bin/<version>/rimgd`。随后，每个 Emacs
会话启动一个 `rimgd` 进程，并使用 OpenSSH 本地转发连接它。

远端进程只监听长度受控、权限为 `0600` 的 Unix socket；运行目录权限为
`0700`。本地 TCP 端点只绑定 `127.0.0.1` 上随机选择的临时端口。协议版本通过
健康检查后，会话才进入可用状态。SSH 通道关闭时，stdin EOF 会让 `rimgd`
退出，同时保留信号处理作为兜底。

### 2. 缩略图与预览请求

Emacs 将远端绝对路径和受限的变换参数发送到本地转发端点。`rimgd` 验证请求，
在远端解码源图片，按 contain 模式缩放，然后返回 JPEG 或 PNG 代理图片。除非
用户显式打开原图，完整原图数据不会传输到 Emacs。

### 3. 两级缓存

远端缓存键是以下内容的 SHA-256：缓存格式版本、规范化路径、文件大小、纳秒级
修改时间以及变换参数。文件或目标尺寸变化时会自然生成新键，无需为整张原图
计算哈希。

Emacs 按远端身份划分本地缓存，并使用服务端返回的键保存图片。在本地命中时，
客户端只重新验证键；内容未变化时，服务端不会再次发送缩略图正文。两级缓存都
先写临时文件，再原子重命名。

### 4. 上千张图片目录的处理

每页最多只创建 200 个固定槽位。客户端只请求视口中的行，以及上下各
`rimg-gallery-prefetch-rows` 行。滚动时才调度新视口附近尚未请求的冷槽位；并行
响应完成后立即填入各自原来的槽位。这既限制了上千张图片目录的请求量和内存
占用，也避免晚到的响应替换当前图片或改变排版。

## 安全模型

- SSH 提供身份认证、加密和主机校验。
- `rimgd` 不监听远端 TCP，只通过 Unix socket 和已认证的 SSH 隧道接收请求。
- 本地转发端口只监听 loopback。
- 请求正文、路径长度、批量数量、图片尺寸、工作线程和输出变换均有限制。
- `rimgd` 只提供健康检查、缩略图、预览和缓存预热接口，不提供 shell 执行、
  目录遍历、重命名或删除接口。
- 远程路径由同一远端用户身份下的进程读取，`rimg` 不绕过该用户的文件权限。

更多细节参见[架构文档](docs/architecture.md)和[协议 v1](docs/protocol-v1.md)。

## 配置项

常用自定义变量：

| 变量 | 默认值 | 含义 |
| --- | --- | --- |
| `rimg-thumbnail-size` | `256` | 缩略图最大宽高 |
| `rimg-page-size` | `200` | 每页最多创建的槽位数 |
| `rimg-gallery-prefetch-rows` | `2` | 视口上下预取的行数 |
| `rimg-http-parallelism` | `6` | HTTP 最大并发请求数 |
| `rimg-preview-max-width` | `1920` | 预览图最大宽度 |
| `rimg-preview-max-height` | `1920` | 预览图最大高度 |
| `rimg-local-cache-directory` | `~/.cache/rimg-emacs/` | 本地缓存根目录 |
| `rimg-server-cache-directory` | `~/.cache/rimg/thumbs` | 远端缓存根目录 |

## 开发与测试

运行可移植测试：

```sh
make test
```

构建发布产物：

```sh
make dist
```

真实远端的 Image-Dired 契约测试默认不运行，需要显式提供夹具：

```sh
RIMG_PHASE0_REMOTE_ORIGINAL=/ssh:example-host:/srv/images/sample.jpg \
  ./scripts/test-phase0.sh
```

其他远程端到端测试使用 `RIMG_E2E_REMOTE`，详见
[docs/e2e.md](docs/e2e.md)。

## 当前限制

- 只支持单跳 `/ssh:` 和 `/sshx:` TRAMP 路径。
- 远端服务目前只支持 Linux amd64 和 arm64。
- 源图片支持 JPEG、PNG 和 WebP，输出格式支持 JPEG 和 PNG。
- `rimg` 仍处于 MVP 阶段，尚未发布到 Emacs 软件包仓库。

## 许可证

MIT，详见 [LICENSE](LICENSE)。
