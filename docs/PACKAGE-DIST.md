# 普通软件包怎么分发

**结论：走 B 方案 —— apt 只做求解，字节由 Finx 自己用 curl 取。**
本文记录支撑这个结论的实测，不是推演。

---

## 一、硬约束

`apt 0.5.4` 没有 https method：

```
$ ls /opt/finx/lib/apt/methods/
cdrom  copy  file  ftp  gzip  http  rsh  ssh
```

而 `finx install` 的二进制路径原本是**让 apt 自己下载**（`fetch_deb` →
`apt-get --ignore-breakage --download-only install`）。所以任何 https 托管
（含 GitHub Releases、GitHub Pages）都不能直接交给 apt。

`ssh` method 存在，但只适用于配置了免密 ssh 的主机，不能作为公共分发渠道。

---

## 二、实测（本地回环、真 apt 0.5.4、隔离 `Dir`）

搭法：一个 `Dir=` 覆盖的假根，`sources.list` 指向本地 http，
`zzprobe` 一枚自建 `.deb`。

```
$ apt-get -o Dir=$R/ -o Dir::State::status=$R/var/lib/dpkg/status \
           -o Dir::Etc=$R/etc/apt/ -o Dir::State=$R/var/lib/apt/ \
           -o Dir::Cache=$R/var/cache/apt/ update
Get:2 http://127.0.0.1 ./ Release [86B]
Fetched 383B in 0s (1108B/s)
```

### 1. `--print-uris` 可用，格式稳定

```
$ apt-get … -y --ignore-breakage --print-uris install zzprobe
'http://127.0.0.1:18080/./zzprobe_1.0-1_darwin-arm64.deb' zzprobe_1.0-1_darwin-arm64.deb 776 42e30377fc6159d0c927ad0e1c75390f
```

四段：`'<URL>'` 文件名 字节数 MD5。带 `--ignore-breakage`（Finx 的用法）
同样输出。**只在确实需要下载时输出** —— 缓存里已有该文件时它什么都不打印，
所以不能把「没有输出」当成错误。

### 2. 预置的归档会被信任，但会先校验

把 `.deb` 放进 `var/cache/apt/archives/`，再把 http 服务关掉：

| 归档内容 | `apt-get -d install` |
| --- | --- |
| 正确 | `Need to get 0B/776B`，成功退出，全程不联网 |
| 损坏（同名、内容不对） | 发现不符 → 试图重下 → 连不上 → `E: Some files failed to download`，exit 100 |

所以 apt 的缓存**不是盲信**；但这层校验只到 MD5（见下）。

### 3. 索引文件名是 URI 的可预测变形

```
file:/tmp/spike2/repo/./Packages  →  var/lib/apt/lists/_tmp_spike2_repo_._Packages
http://127.0.0.1:18080/./Packages →  var/lib/apt/lists/127.0.0.1:18080_._Packages
```

规则是 URI 里非字母数字字符换成 `_`，再加 `_<文件名>`。想自己放索引就按这个算。

### 4. `Packages.gz` 必需，`Release` 可省

| 仓库里有什么 | `apt-get update` |
| --- | --- |
| `Packages.gz` + `Release` | 成功 |
| 只有 `Packages.gz` | 成功（`Release` 缺席只记 `Ign`） |
| 只有 `Packages`（未压缩） | **失败**，不回退：`E: Some index files failed to download` |

这条对发布形态有直接影响：**apt 需要一个单一的、按仓库聚合的索引**，
而 Bottle 是「一包一 tag」的散装形状。两者不能直接对接。

### 5. 端到端闭环

```
① apt-get --print-uris            → URL + 文件名 + 字节数 + MD5
② curl 取那个 URL                 → 落到 var/cache/apt/archives/<文件名>
③ 与索引里的 SHA256 比对          → 一致（866b795e…）
④ 关掉 http 服务
⑤ apt-get --ignore-breakage -d install zzprobe
   Need to get 0B/776B … Download complete and in download only mode   [exit 0]
```

第 ⑤ 步证明「求解与取字节可以分离」。

---

## 三、为什么是 B 而不是 A 或 C

| | 传输 | 完整性校验 | 改动 |
| --- | --- | --- | --- |
| A 自有服务器，纯 http | 明文 | **MD5**（索引里只有它，apt 也只认它） | 零代码 |
| **B apt 求解 + Finx 取字节** | 任意，含 **https** | **SHA256**（索引里有，Finx 自己比） | 改 `fetch_deb` |
| C 给 apt 加 https method | https | 仍 MD5 | 重写 0.5.4 的 method 协议 |

关键差别不在工作量，在**校验强度**。索引里同时有 `MD5sum` 与 `SHA256`：

```
Filename: ./zzprobe_1.0-1_darwin-arm64.deb
Size: 776
MD5sum: 42e30377fc6159d0c927ad0e1c75390f
SHA256: 866b795e05a17620824e239440975b7e60e27b17c623c23c5a00182ff06d8a56
```

B 让 Finx 有机会用后者，而让 apt 自己下载就只能用前者。碰撞强度差着一整个量级，
而这是一条**长期**的链 —— 以后每加一个包都在上面跑。

---

## 四、B 的实现要点

1. `fetch_deb` 里先跑 `--print-uris`，解析出四段。
2. 用 curl 取（沿用 `finx-install` 那套超时与续传；`https_proxy` 已支持）。
3. **SHA256 与索引比对**：索引就在 `var/lib/apt/lists/*_Packages`，按 `Filename`
   找到同名条目读 `SHA256:`。索引本身用 https 取，所以链路是完整的：
   https 保护索引 → 索引里的 SHA256 保护载荷。
4. 文件按 `--print-uris` 给的文件名落到 `var/cache/apt/archives/`。
5. 再跑原来的 `--download-only install`：它发现缓存已满足，0 字节、不联网。
   这一步是**必须的**，不是多余 —— 它是 apt 的校验关口（第 2 条实测过：内容
   不对时它会拒绝并重下）。
6. `--print-uris` 无输出时视为「缓存已满足」，继续第 5 步，不当错误。

---

## 五、发布形态的后果（待决定）

apt 要一份**聚合索引**，Bottle 是**散装资产**。两条路：

- **B1**：发布时另外生成一份聚合的 `Packages.gz`（连同 `Release`），与散装
  `.deb` 并存。索引里的人 `Filename` 必须与资产的真实路径一致。
- **B2**：Finx 取一份清单（形状同种子 `manifest`），**本地合成** `Packages`，
  按第 3 条的命名规则写成 `var/lib/apt/lists/<name>_Packages`。Bottle 形状保得住，
  但 `Filename` 得写成绝对 URL，且要自己保证命名规则不被上游以后改掉。

B1 更朴素、依赖更少；B2 保住了「一包一 tag」。这一条需要拍板。

---

## 六、复现

本文每一步都在 `/tmp` 里用真 apt 与真 dpkg 跑过，没有触碰 `/opt/finx`。
`Dir=` 覆盖是关键：apt 的路径是编译期写死的，不覆盖就会去改真前缀。

```bash
S=/tmp/spike2; R=$S/root
apt-get -o Dir=$R/ -o Dir::State::status=$R/var/lib/dpkg/status \
        -o Dir::Etc=$R/etc/apt/ -o Dir::State=$R/var/lib/apt/ \
        -o Dir::Cache=$R/var/cache/apt/ update
```
