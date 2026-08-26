# Tiktok-MJ-for-Wechat

独立的微信 MJ 彩蛋插件-在微信实现抖音Mj蜘蛛侠彩蛋。

插件管理中注册独立开关“MJ 彩蛋”。开启后，自己发送或收到精准匹配的 `mj`、`mjmj` 等连续组合时，每次交替播放一段来自 TikTok 的 Spider-Man 动画。动画窗口点击穿透，不抢占输入法和聊天手势。

<p>
  <img width="49%" alt="MJ 彩蛋播放效果 1" src="https://github.com/user-attachments/assets/ef8c83ab-d5e9-4f89-bbe0-6d39b6a79422" />
  <img width="49%" alt="MJ 彩蛋播放效果 2" src="https://github.com/user-attachments/assets/735dc9ac-4264-484b-bcef-867aa345c973" />
</p>

## 动画素材

仓库保留两段体积较小的原始双画面蒙版素材，便于追溯和重新制作：

- [`Assets/source/mj-drop-dual-mask.mp4`](Assets/source/mj-drop-dual-mask.mp4)
- [`Assets/source/mj-swing-dual-mask.mp4`](Assets/source/mj-swing-dual-mask.mp4)

这两段源素材不会加入 Theos 安装包。插件实际播放的是带透明通道的 `mj-drop-alpha.mov` 与 `mj-swing-alpha.mov`；首次开启开关时会从网络下载，并保存到微信数据目录的 `Library/Application Support/MJ/`。后续开启直接复用本地文件，关闭开关时可选择保留或删除。

透明 MOV 文件体积明显大于插件代码，因此不直接携带在 deb 中，避免安装包增加约 70 MB。首次初始化所需时间取决于网络速度，下载完成且文件校验通过后才会真正启用。

### 透明素材如何制作

仓库中的源视频采用左右双画面布局：左半边是灰度 Alpha 蒙版，右半边是对应的彩色蜘蛛侠画面。蒙版中白色表示完全显示，黑色表示完全透明，灰色表示半透明。将两部分裁开并使用 `alphamerge` 合并，即可生成带真实 Alpha 通道的 ProRes 4444 MOV：

```sh
ffmpeg -i mj-drop-dual-mask.mp4 \
  -filter_complex "[0:v]split=2[color_src][mask_src]; \
    [color_src]crop=iw/2:ih:iw/2:0[color]; \
    [mask_src]crop=iw/2:ih:0:0,format=gray[alpha]; \
    [color][alpha]alphamerge,format=yuva444p10le[out]" \
  -map "[out]" -map 0:a? \
  -c:v prores_ks -profile:v 4 -pix_fmt yuva444p10le \
  -c:a aac -movflags +faststart \
  mj-drop-alpha.mov
```

第二段素材使用同样命令，将输入和输出名称替换为 `mj-swing-dual-mask.mp4`、`mj-swing-alpha.mov`。可以通过以下命令确认输出包含 Alpha 像素格式：

```sh
ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,pix_fmt,width,height \
  -of default=noprint_wrappers=1 mj-drop-alpha.mov
```

ProRes 4444 真透明视频体积较大，但播放时无需逐帧执行双画面裁切和蒙版合成，能明显降低手机端实时渲染压力。生成后的两段 MOV 上传至下载源即可；即使下载链接以 `.txt` 结尾，插件也会按文件头而不是扩展名判断内容。

## 实现思路

### 消息触发

1. 发送端 Hook 微信文字发送入口，仅接受精准匹配的 `mj`、`mjmj` 等连续组合。
2. 接收端覆盖微信的同步和异步消息入口，但只登记文字消息的稳定身份，不直接播放。
3. 消息身份由会话名称与 `m_uiMesLocalID`、`m_n64MesSvrID` 组合生成，避免相同文字在不同会话间串播。
4. `CommonMessageCellView` 绑定 `viewModel` 并真正出现在前台窗口后，才消费对应的待触发身份并播放。
5. 待触发身份仅保存在内存中并设置数量上限；微信进程结束后自然清空，不会在重启后补播很久以前的消息。

这种方式不遍历整棵聊天视图、不按 UILabel 文本猜测消息，也不依赖持续轮询。后台收到的消息会保留到相应气泡在前台可见时触发，其他聊天不会误播。

### 素材初始化

1. 首次开启插件时，通过 `https://ovoy.cc/lzy.php?url=` 解析两条蓝奏云分享链接。
2. 下载内容先写入 `.download` 临时文件。
3. 检查文件大小，并校验 ISO Base Media/QuickTime 的 `ftyp` 文件头；校验成功后才移动为最终 `.mov`。
4. 两段文件全部有效后才允许启用，失败会关闭开关并显示具体错误。
5. 文件永久保存在微信沙盒的 `Library/Application Support/MJ/`，下次开启直接复用；关闭插件时可选择保留或删除。

### 透明播放与后台恢复

- 每次触发在独立的点击穿透 `UIWindow` 中创建 `AVPlayerLayer`，不会拦截键盘、聊天手势或页面点击。
- 两段动画通过内存索引交替选择，每次只播放其中一段。
- 微信进入后台时立即停止播放器并销毁活动 Session，消息待触发记录则继续保留。
- 回到前台后重新检查仍然可见的消息 Cell，避免锁后台时间过长后失效。
- 启动失败会立即清理；若系统没有返回播放结束或失败通知，还有 30 秒超时保险回收僵尸 Session。
- 普通微信页面切换不会主动中断已经开始的动画。

## 构建

```sh
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

GitHub Actions 最终只输出三个文件：

- `TiktokMJ.dylib`：同时包含 arm64 与 arm64e slice 的通用动态库
- `TiktokMJ_iphoneos-arm64.deb`：rootless/无根安装包
- `TiktokMJ_iphoneos-arm64e.deb`：RootHide/隐根安装包

rootless 包使用官方 Theos 构建，RootHide 包使用 `roothide/theos` 与 `THEOS_PACKAGE_SCHEME=roothide` 构建。deb 名称中的 `iphoneos-arm64`、`iphoneos-arm64e` 是对应生态采用的包架构标签；两份安装包内的插件二进制均同时支持 arm64 与 arm64e。
