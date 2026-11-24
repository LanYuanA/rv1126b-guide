# RV1126B 驱动开发笔记

[在线阅读](https://lanyuana.github.io/rv1126b-guide/) · [八卷 84 章学习大纲](learning-site/导航/学习大纲.md) · [实验源码](learning-site/examples/)

以 RV1126B 与 IMX415 为例，从 C 和字符设备读到 Linux 内核机制、设备树与驱动子系统，再沿着 V4L2、ISP 和 GStreamer 跟踪一帧图像。后几卷讨论多路分流、成像调校、内核裁剪与性能诊断。

- `learning-site/` 下按八卷组织 Markdown 正文，`导航/` 提供学习大纲与参考资料。
- `learning-site/examples/` 包含配套 C 程序、设备树示例和实验脚本。各章列出运行环境、命令与预期现象。
- `learning-site/.vitepress/` 和 `.github/workflows/learning-site.yml` 分别维护网站配置及 GitHub Pages 部署。

## 本地预览

使用 Node.js 22 和 npm，在仓库根目录执行。

```bash
cd learning-site
npm ci
npm run dev -- --host 127.0.0.1 --port 5173
```

打开 [本地站点](http://127.0.0.1:5173/rv1126b-guide/)。静态构建使用 `npm run build`，产物在 `learning-site/.vitepress/dist/`。

阅读网页与构建网站均可独立进行。需要追读厂商驱动或运行板端实验时，按章节说明准备对应 SDK、板卡和工具。网页展示源码位置及短片段，具体行号以所用 SDK 版本为准。
