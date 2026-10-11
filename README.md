# 一键开锁 — Android APK

封装的页面：`开锁软件1.1.html`（原始文件归档在 `versions/`）

| | 当前 | 说明 |
|---|---|---|
| 文件 | `DormUnlock-v1.1-debug.apk` | |
| 版本 | versionName **1.1** / versionCode **3** | versionCode 3 > 上一版 2，可覆盖安装 |
| SHA256 | `79137DBA1AD1E1D683D2DD69D02DD9C303BAD2DA6D7DEDFBE06DA06BFDD0DE64` | |
| 包名 | `com.example.dormunlock` | |
| sdk | minSdk 24（Android 7.0）/ targetSdk 35 | |
| 签名 | debug 签名，v2 + v3 校验通过 | 与 1.0 同一 `debug.keystore` |

---

## 1. 「没有获取到对应数据」的根因（已修）

我把学校这套前端拉下来读了源码，问题定位得很确定。

**`ms.hnuit.edu.cn/ssologin/index.html` 是一个 Vue 单页应用**，标题「物联智锁」。
它的登录分包 `index.4fca188d.js` 核心逻辑是：

```js
const r = i();                                   // 解析 window.location.search
r && Object.keys(r).length > 0
  ? u(r)                                         // 有参数 → POST 去换 token
  : s.layer.alert("没有获取到对应数据", () => { l.go(-1) });   // 没参数 → 弹这句并返回

function u(t) {
  p.post("/app/newapp/login/j/xxxyssologin", t)  // 把 URL 上的参数原样 POST 上去
    .then(e => { let a = e.result;
      s.storage.setSession("token", a.token);
      s.storage.setSession("reflashtoken", a.reflashtoken);
      l.replace({ path: "index" }); });
}
```

**这个登录页必须带 query 参数才能工作**——它把 URL 参数原样 POST 到
`/api/app/newapp/login/j/xxxyssologin` 换 token。1.1 里写的是裸的
`/ssologin/index.html`（没有任何参数），所以必然弹「没有获取到对应数据」然后退回。
**不是网络问题，是入口 URL 用错了。**

正确入口是 1.0 里那个带 `appId` 的地址（我实测过它的跳转）：

```
GET http://42.247.25.165:19996/login/login/xxxylogin?appId=1000335
→ 302 https://sso.hnuit.edu.cn/cas/login?service=...xxxylogin%3FappId%3D1000335
```

必须从这个 CAS 入口进：认证成功后回调 → 服务端再跳到
`/ssologin/index.html?<参数>`，这时页面上才有参数可用。

**已改为** `LOGIN_ENTRY_URL = 'http://42.247.25.165:19996/login/login/xxxylogin?appId=1000335'`。

---

## 2. 顺带把「自动登录」补完整了

光改 URL 还不够：登录页跑在原生第二层 WebView 里，页面自己不会通知 App，
所以登录完 App 仍然什么都没拿到。我从官方前端挖出了确切的存储格式：

```js
setSession(e, t="") { sessionStorage.setItem("com.hnzkya." + e, JSON.stringify(t)) }
```

即 token 在 **`sessionStorage["com.hnzkya.token"]`**，且值是 **JSON 字符串化的**。

**所以现在做了三件事：**

1. 点「尝试自动登录」→ 打开 CAS 入口 → 同时每 1.2 秒轮询登录层，读取
   `sessionStorage["com.hnzkya.token"]`（兼容 JSON 包裹 / 原始值 / 前后缀两种写法，
   并带全量关键词兜底扫描）；
2. 一旦拿到 token → 自动收起登录层、填入 Token；
3. 再调 `/api/app/newapp/public/9/getuserrooms` 取你账号绑定的房间，
   自动填入 **roomid** 和 **wcode**。

> 💡 **注意**：`wcode` 不是学号，而是房间对象里的 **`roomcode2`**。
> 这是官方 UI 自己开锁时传的值（`{ type:2, roomid:t.roomid, wcode:t.roomcode2 }`），
> 所以它是权威来源——之前手动填的 `2046101026` 那种学号格式其实是猜的。

取到房间后界面会提示「已自动配置：<房间位置>」，你核对一下是不是自己宿舍即可。
如果接口没返回房间，会自动打开手动配置弹窗，让你补齐（Token 已经填好了）。

**改回纯手动**：把 `startCredentialWatch()` 那个调用删掉即可，其余逻辑不受影响。

---

## 3. ⚠️ 重要发现：开锁是**异步订单**，现在的成功判定是错的

官方 UI 的开锁实现（`list.a5f5b716.js`）是这样的：

```js
k.serverTask("/app/newapp/public/m/opendoorbyserver",          // ① 提交开锁
             "/app/newapp/public/q/getserveractionresult",      // ② 轮询结果
             { type: 2, roomid: t.roomid, wcode: t.roomcode2 },
             u => layer.msg(u.orderbei || "开门成功", "success"),
             u => layer.msg(u.orderbei || "开门失败"),
             () => layer.msg("开门超时"));

// serverTask: ① 拿到 result.orderid
//             ② 每 1500ms POST { orderid, wcode, roomid } 查 orderstate
//                1  → 成功      -1 → 失败      最多轮询 20 次 → 超时
```

**也就是说：`opendoorbyserver` 返回 HTTP 200 只代表「订单已受理」，
真正的成功信号是轮询 `getserveractionresult` 得到的 `result.orderstate == 1`。**

这正好解释了我前两次交付时标记的那个问题——你现在的判定：

```js
isUnlockSuccess: function (data, response) {
    ...
    return true;      // ← 任何 HTTP 200 都算成功
}
```

会让界面在**根本没开门**的情况下也显示「已开锁」。真实提示文案在
`result.orderbei` 里，接口还有 `开门超时` 这种状态。

**要不要我按这个两步协议改 `doUnlock`？** 这是你课设里很值得写的一块
（异步任务 + 轮询 + 状态机），但也确实会改变「开锁」按钮的显示语义
（会出现「开门失败 / 开门超时」），所以我没擅自动，等你说。

---

## 4. ⚠️ 全流程都要校园网

| 域名 | 解析结果 | 用途 |
|---|---|---|
| `42.247.25.165:19996` | 公网 IP | CAS 入口（但它立刻 302 到下面那个） |
| `sso.hnuit.edu.cn` | **10.128.3.12** | 统一身份认证（CAS 登录页） |
| `ms.hnuit.edu.cn` | **10.128.3.12** | 物联智锁前端 + 所有接口 |

入口虽然是公网地址，但它一进去就跳内网的 `sso.hnuit.edu.cn`，
**所以登录和开锁都必须连校园 Wi-Fi 或学校 VPN**。在校外只会看到跳转失败或超时。

---

## 5. 安装与使用

```bash
adb install -r DormUnlock-v1.1-debug.apk
```

1. 首次启动 → 引导页 → 点 **尝试自动登录**（推荐）；
2. 登录页会跳到学校 CAS，用校园账号登录；
3. 登录成功后 App 自动获取 Token / roomid / wcode，跳到开锁面板；
4. 之后每次打开只需点大按钮。长按按钮 = 清除凭证。

**登录页怎么退出**：按手机返回键（原生侧：登录层可见时先退登录层，再退应用）。
如果一直没检测到登录结果，轮询会在约 6 分钟后停止并提示你改用手动配置。

---

## 6. 打包时对页面做的必要修复

除了上面的功能改动，还有一处**必须修**的桥接 bug（1.0 / 1.1 都有）：

```js
AndroidBridge.httpRequest(JSON.stringify({...}), function (respRaw) { ... });
```

Java 的 `@JavascriptInterface` **只能接收基本类型**，函数会被转成源码文本传过去，
回调永远不会触发 —— 结果是**点开锁后永远卡在「正在开锁...」、按钮一直禁用**。

已改为回调 ID 分发：

```js
window.__dlCallback = function (id, result) { ... };   // 原生执行完回调这里
function __nativeCall(method, args, cb) {
    var id = 'cb' + (++__cbSeq);
    if (cb) __cbMap[id] = cb;
    AndroidBridge[method].apply(AndroidBridge, (args || []).concat([id]));
}
```

同时给 `Bridge` 补了 `evalJs()`（读登录层存储）和 `hideLogin()`（收起登录层），
这两个能力原生侧 `MainActivity` 本来就提供。**`CONFIG`、接口地址、UI、文案其余部分保持你 1.1 原样。**

---

## 7. 重新构建

不需要 Android Studio。SDK 压缩包在 `dl/`，离线可构建：

```powershell
cd E:\dsh工作区\dorm-unlock-apk
powershell -ExecutionPolicy Bypass -File build.ps1 -SkipDownload
powershell -ExecutionPolicy Bypass -File build.ps1 -SkipDownload -VersionName 1.2 -VersionCode 4
```

流程：`aapt2 compile` → `aapt2 link` → `javac` → `d8` → 注入 `classes.dex` → `zipalign` → `apksigner`。

> ⚠️ 改版本号要**两处同步**：`build.ps1` 的 `-VersionCode/-VersionName`（传给 aapt2）
> 和 `project/AndroidManifest.xml` 的 `versionCode/versionName`。只有 versionCode 严格递增才能覆盖安装。

**踩过的 3 个环境坑（脚本已处理）：**

1. **aapt2 打不开含中文的路径** —— 工程在 `E:\dsh工作区\...` 会让它报 `No such file or directory`，
   所以脚本先把源工程复制到纯 ASCII 临时目录（默认 `%TEMP%\dormbuild`）再编译；`-WorkRoot` 也必须纯 ASCII。
2. **本机 HTTPS 出网被拦**（`schannel: SEC_E_NO_CREDENTIALS`），但 `http://dl.google.com/...` 可用，故统一走 HTTP。
3. **`build.ps1` 必须存成 UTF-8 with BOM** —— PowerShell 5.1 会按 GBK 解析无 BOM 脚本，中文注释直接语法报错。

`android-studio-project/` 是等价的 Gradle 工程（AGP 8.5.2 / Gradle 8.7），可直接用
Android Studio 打开。它的清单用 `namespace` 声明包名，所以**不能**再写 `package="..."`。

---

## 8. 使用范围

调的是学校自己的 `opendoorbyserver` 接口，不含任何破解、爆破或绕过认证的逻辑——
某间宿舍的门能不能开，最终由学校服务器鉴权决定。请只配置自己宿舍的
`roomid` / `wcode`（自动获取拿到的就是你账号绑定的房间）。

---

## 9. 目录说明

```
dorm-unlock-apk/
├─ DormUnlock-v1.1-debug.apk      ← 当前版本（versionCode 3），直接装
├─ DormUnlock-v1.0-debug.apk      ← 最初版本，保留备查
├─ build.ps1                      ← 一键重建（-VersionName / -VersionCode）
├─ debug.keystore                 ← 签名，留着才能覆盖升级
├─ README.md
├─ versions/                      ← 你的原始 HTML 归档
│  ├─ 开锁软件1.1-原始.html          （你发来的 1.1，未改动）
│  └─ index-1.0-已适配.html          （1.0 适配原生后的页面）
├─ project/                       ← 手工管线用的源工程
│  ├─ AndroidManifest.xml
│  ├─ assets/index.html           ← 1.1 + 桥接修复 + 入口URL修复 + 凭证自动获取
│  ├─ res/values/strings.xml
│  ├─ res/drawable/ic_launcher.xml
│  └─ src/com/example/dormunlock/MainActivity.java   ← 原生壳（双层 WebView + JS 桥）
├─ android-studio-project/        ← 等价的 Gradle 工程
└─ dl/                            ← SDK 压缩包（可删）
```

`MainActivity.java` 无需改动：它已提供 `loadUrl` / `httpRequest(cbId)` /
`evaluateJavascript(cbId)` / `getCurrentUrl` / `clearCookies` / `hideLogin`，
本次页面新增用到的正是后两个之外已有的能力。`window.__doorlock` 回调带 `&&` 保护，
页面不定义也不会报错。
