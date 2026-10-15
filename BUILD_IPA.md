# OpenNomi IPA 打包

本配置生成 iPhone/iPad 真机用的 **arm64 未签名 IPA**，最低系统版本保留上游的 **iOS 26.0**。IPA 需要用自己的签名工具或证书重新签名后才能安装。

## GitHub Actions

1. 将本仓库放在自己有写权限的 GitHub 仓库中。
2. 在 Actions 中选择 **Build unsigned IPA**，手动点击 **Run workflow**。
3. 成功后下载 **OpenNomi-unsigned-ipa** artifact，解压获得 `OpenNomi-unsigned.ipa`、SHA-256 校验文件和构建记录。

工作流使用标准 `macos-26` runner 和预装的 Xcode 26.6，仅手动触发；不需要上传 Apple ID、开发证书或描述文件。产物保留 7 天。

## 本地构建

安装完整 Xcode 26 或更新版本后，在仓库根目录执行：

```sh
bash scripts/build-unsigned-ipa.sh
```

输出目录为 `build/`。脚本通过命令行关闭签名并覆盖开发团队设置，保留原工程文件和 SwiftPM 锁定版本。归档成功后检查 ZIP、Info.plist、iOS 真机平台、arm64 可执行文件和权限声明。

## 验证范围

结构检查和编译成功不代表已经在 iPhone 上验证安装、语音、设备绑定或 AI 服务连接；这些需要重签并安装到设备后验证。
