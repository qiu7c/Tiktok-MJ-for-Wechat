# Tiktok-MJ-for-Wechat

独立的微信 MJ 彩蛋插件-在微信实现抖音Mj蜘蛛侠彩蛋。

插件管理中注册独立开关“MJ 彩蛋”。开启后，自己发送或收到精准匹配的 `mj`、`mjmj` 等连续组合时，每次交替播放一段来自 TikTok 的 Spider-Man 动画。动画窗口点击穿透，不抢占输入法和聊天手势。

<p>
  <img width="49%" alt="MJ 彩蛋播放效果 1" src="https://github.com/user-attachments/assets/ef8c83ab-d5e9-4f89-bbe0-6d39b6a79422" />
  <img width="49%" alt="MJ 彩蛋播放效果 2" src="https://github.com/user-attachments/assets/735dc9ac-4264-484b-bcef-867aa345c973" />
</p>

## 构建

```sh
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```
