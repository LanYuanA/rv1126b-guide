---
layout: home
hero:
  name: RV1126B 驱动开发笔记
  text: 从字符设备到一帧 4K 图像
  tagline: 用同一颗 IMX415 学习 Linux 内核、板级适配和相机应用。沿着实际代码做实验，再用数据回答故障发生在哪一层。
  actions:
    - theme: brand
      text: 浏览开发路线
      link: /导航/roadmap
    - theme: alt
      text: 从接手新板开始
      link: /01-开发环境/board
features:
  - title: Linux 底软
    details: 写字符驱动，追系统调用、GIC 中断、内存分配、DMA 和录像写回。
    link: /导航/kernel
  - title: 一帧怎样到达应用
    details: 从 DTS、I2C 和 probe 读到 CSI、VB2 与 GStreamer。
    link: /导航/camera
  - title: 成像与相机功能
    details: 把线性图像扩展到 3A、HDR、变焦、四路分流和动态照片。
    link: /07-成像与调校/imaging
  - title: 调试、裁剪与答辩
    details: 用真实日志计算帧间隔，做 Kconfig 对照，设计可验收的内核观测工具。
    link: /导航/observability
---
