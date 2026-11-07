# SeekZip 测试矩阵

每个用例都通过 `seekzip` CLI 在 CI（macOS ARM
运行器）中无头运行，并且必须在发布之前通过。夹具由
`Tests/Matrix/generate-matrix.sh` 生成；大型夹具在
运行器上生成，从不提交。

## 格式 (FMT)
- FMT-01 ZIP store/deflate/bzip2/lzma (zipx) —— 列举、预览、解压、测试
- FMT-02 7z 固实（solid）与非固实，LZMA2 多线程
- FMT-03 RAR4 与 RAR5（仅解压），包括恢复记录
- FMT-04 tar、tar.gz、tar.bz2、tar.xz、tar.zst、tar.lz4
- FMT-05 ISO、DMG、CAB、WIM、ARJ、LZH、MSI、DEB、RPM、XAR
- FMT-06 自解压存根（self-extracting stubs）以及带有前置垃圾数据的归档

## 大文件与性能 (PERF)
- PERF-01 10 GB 归档：列举 < 5 s，峰值 RSS < 300 MB
- PERF-02 单个条目 10 GB（稀疏 + 真实数据两种变体）
- PERF-03 Zip64：归档总大小 > 4 GB、条目 > 4 GB、偏移 > 4 GB
- PERF-04 1,000,000 个条目：列表流式呈现，UI 保持响应，
  筛选结果增量返回
- PERF-05 以 `-mmt=on` 创建 20 GB 7z：所有核心满载，在 50% 时取消
  不得留下写了一半的最终文件（临时名称被清理或有明确标记）
- PERF-06 在应用重启后暂停/恢复队列

## 加密 (ENC)
- ENC-01 ZIP 旧式 ZipCrypto（用正确密码打开）
- ENC-02 ZIP AES-256；带加密头部的 7z AES-256（`-mhe=on`）
- ENC-03 密码错误：干净地报错，无部分解压，退出代码 5
- ENC-04 Unicode 密码（越南语变音符号、emoji）
- ENC-05 密码来自 Keychain；存储的密码错误时回退到提示输入

## 分卷 (SPL)
- SPL-01 ZIP 分卷（.z01…）、7z 分卷（.7z.001…）、RAR 分片（part1.rar…）
- SPL-02 缺少中间卷：精确报错并指出缺失的分片名称
- SPL-03 分卷位于不同文件夹时，提示下一卷的位置

## 损坏 (COR)
- COR-01 被截断的归档（50%、99%）：头部错误，不崩溃
- COR-02 条目数据位翻转：按条目报告 CRC 失败；其他
  条目仍可解压
- COR-03 中央目录损坏；抢救（salvage）模式解压可读部分
- COR-04 根本不是归档（随机字节、空文件、以目录作为输入）

## 嵌套与结构 (NES)
- NES-01 归档套归档套归档（3 层）就地打开
- NES-02 空归档；只有空文件夹的归档
- NES-03 条目名称重复；条目在 APFS 上仅大小写不同
- NES-04 极深路径（> 1024 字符）与 255 字符的文件名组成部分

## 预览 (PRV)
- PRV-01 文本预览：前 200 行 / 64 KB，UTF-8 安全，截断时有提示
- PRV-02 图片、PDF 与二进制条目：不读取内容，给出 Quick Look 结论
- PRV-03 加密条目且无密码：给出明确的“需要密码”结论
- PRV-04 两层嵌套归档内的条目可预览（经 `listNested`）
- PRV-05 预览大条目时绝不完整解压（流在上限处停止）

## 文件名与编码 (NAM)
- NAM-01 带越南语变音符号和 emoji 的 UTF-8 文件名
- NAM-02 来自 Windows 日本版的 Shift-JIS (CP932) ZIP；GBK ZIP；CP1252 ZIP——
  可被检测或手动选择编码，无乱码（mojibake）
- NAM-03 包含 `=`、首尾空格、名称内含 `..` 的文件名
- NAM-04 macOS 特有内容：`__MACOSX`、`.DS_Store`、资源分支（resource forks）、xattrs

## 安全 (SEC)
- SEC-01 Zip-slip：`../` 和绝对路径条目被阻止（退出代码 4）
- SEC-02 指向目标目录之外的符号链接/硬链接条目被阻止
- SEC-03 Zip 炸弹（42.zip 式嵌套 + 扁平 1000:1 比例）：显示警告，
  解压需要显式确认
- SEC-04 解压中途磁盘已满：干净地失败，移除部分文件，
  源归档不受影响
- SEC-05 目标只读或在操作中途被移除（USB 被拔出）

## 交叉验证 (XCHK)
- XCHK-01 每个夹具同时用官方 7-Zip 和 bsdtar 列举/测试；
  条目列表和 CRC 必须一致
- XCHK-02 SeekZip 创建的归档可在 7-Zip、WinRAR、Keka、The
  Unarchiver 和 macOS Archive Utility 中无警告地打开
