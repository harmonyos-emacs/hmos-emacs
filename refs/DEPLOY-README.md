# HM PC Demo 部署说明（已跑通）

应用已成功签名并安装到 HarmonyOS PC。本文档记录可复现的完整流程。

## 环境

- SDK/工具链: `/home/song/Desktop/commandline-tools-linux-x64-26.0.0.851/command-line-tools`
- Java: OpenJDK 17 (`/usr/lib/jvm/java-17-openjdk-amd64`)
- PC 无线调试: `192.168.102.170:39681`（掉线后 `hdc tconn 192.168.102.170:39681` 重连）
- 工程: `/home/song/Desktop/hmtest/mdm-demo`
- bundleName: **`song.demo.test`**（与 AGC Profile 一致，勿改）

## 设备信息

- 名称: `hm-pc`
- UDID: `B9690BF09182FDC7DD015EC683D907E53951B45CA291A2B27F641058E15923E8`
- 获取: `hdc -t 192.168.102.170:39681 shell bm get -u`

## 签名材料

位于 `/home/song/Desktop/hmtest/sign-material/`：

| 文件 | 说明 |
|------|------|
| `demo.p12` | 密钥库（keytool 生成，alias=`demo_key`，密码=`123456Abc`，EC/secp256r1） |
| `demo.csr` | 证书请求（已用于 AGC 申请） |
| `cert1.cer` | AGC 下载的调试证书（含 3 级链: Root G2 → Developer Relations CA G2 → 叶子证书） |
| `touchable-area-testDebug.p7b` | AGC 调试 Profile（bundle=`song.demo.test`，设备=hm-pc，归属证书=cert1，ACL 含 `SET_WINDOW_TOUCH_AREAS`） |
| `testDebug.p7b` | 旧调试 Profile（无 `SET_WINDOW_TOUCH_AREAS` ACL；当前 module.json5 已申请该权限，旧 Profile 安装会失败） |

Profile 关键字段已验证：叶子证书 == p7b 内 development-certificate，本机 UDID 在 device-ids 中。

> 当前设备 API 24 安装后 `SET_WINDOW_TOUCH_AREAS` 仍为未授予（`reqPermissionStates = -1`），
> `setTouchableAreas` 返回 202；在可授予该 ACL 的 API 26 设备上才会生效。

## 构建 + 签名 + 安装（三步）

```bash
# 1. 构建（build-profile.json5 的 product 未配置 signingConfig，hvigor 跳过签名，产物为 unsigned）
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH=$JAVA_HOME/bin:$PATH
cd /home/song/Desktop/hmtest/mdm-demo
/home/song/Desktop/commandline-tools-linux-x64-26.0.0.851/command-line-tools/bin/hvigorw assembleApp --no-daemon

# 2. 手动签名（签名材料是明文密码，hvigor 的加密密码机制不适用，故手动签）
LIB=/home/song/Desktop/commandline-tools-linux-x64-26.0.0.851/command-line-tools/sdk/default/openharmony/toolchains/lib
java -jar $LIB/hap-sign-tool.jar sign-app -mode localSign -signAlg SHA256withECDSA \
  -keyAlias demo_key -keyPwd 123456Abc \
  -appCertFile /home/song/Desktop/hmtest/sign-material/cert1.cer \
  -profileFile /home/song/Desktop/hmtest/sign-material/touchable-area-testDebug.p7b \
  -keystoreFile /home/song/Desktop/hmtest/sign-material/demo.p12 -keystorePwd 123456Abc \
  -inFile  entry/build/default/outputs/default/entry-default-unsigned.hap \
  -outFile entry/build/default/outputs/default/entry-default-signed.hap

# 3. 安装并启动
HDC=/home/song/Desktop/commandline-tools-linux-x64-26.0.0.851/command-line-tools/sdk/default/openharmony/toolchains/hdc
$HDC -t 192.168.102.170:39681 install entry/build/default/outputs/default/entry-default-signed.hap
$HDC -t 192.168.102.170:39681 shell aa start -b song.demo.test -a EntryAbility
```

## 为什么 product 不配置 signingConfig

hvigor 签名前会执行 `validatePackageName`（sign-util.js），比对 p7b 里的 bundle-name 与 hap 的 bundleName，不一致直接构建失败；且 hvigor 的 storePassword/keyPassword 是 DevEco 加密格式（`DecipherUtil` 需要工程根目录 `material/{fd,ac,ce}` 解密材料，明文密码会报 INVALID_DATA）。因此跳过 hvigor 签名，构建后用 hap-sign-tool 手动签，流程更可控。

## AGC 资源（本次申请）

- 证书: `cert1`（调试，生效），由 `sign-material/demo.csr` 签发
- Profile: `touchable-area-testDebug`（调试），归属证书 cert1，已选设备 hm-pc；ACL 含 `SET_WINDOW_TOUCH_AREAS`
- 后续如换设备: AGC 注册新 UDID → 重新生成 Profile → 替换 `touchable-area-testDebug.p7b` 即可

## 已排除的方案（勿重复尝试）

| 方案 | 错误码 | 原因 |
|------|--------|------|
| BidRoom 旧 debug Profile（UDID 不含本机） | 9568423 | 设备未授权 |
| BidRoom 旧 release Profile 直接 hdc 安装 | 9568322 | release 包不允许 hdc 自装 |
| 手工改 p7b 里的 device-ids | CMS 签名失效 | p7b 有防篡改签名 |
| OpenHarmony 本地 CA 签名 | 9568257 | HarmonyOS PC 不信任 OH 本地 CA 链 |
| 装 `app/entry-default.hap` | 9568320 | 该产物无有效签名 |
| bundleName 用旧值 `com.zjtx.bidroom.master` | — | 与 AGC Profile (`song.demo.test`) 不匹配，hvigor 校验失败 |

## 附: OpenHarmony 本地签名备忘（仅 OH 设备可用）

坑1: profile JSON 里 `development-certificate` 值必须以 `-----END CERTIFICATE-----\n` 结尾（含换行），否则 sign-app 报 `Illegal base64 character 20`。
坑2: hap-sign-tool `sign-profile` 用 `-profileCertFile <lib>/OpenHarmonyProfileDebug.pem`（不能用 -profileFile 拼接链）。
