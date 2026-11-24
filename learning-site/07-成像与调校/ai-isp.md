# 7.9 AI ISP 的输入契约与性能代价

<script setup>
import exampleFile from '../examples/aiisp-tradeoff-demo.awk?url'
</script>

看到 SDK 里有 AI ISP 节点、模型文件和 NPU 驱动，首先要问这三个证据分别属于哪一层。真实算法需要有正确的输入、成功的执行、可关联的输出，以及对照后的画质收益。

## 本地 SDK 的能力可以确认到哪一层

| 层 | 这次能核对的证据 | 用于实板的下一项证据 |
| --- | --- | --- |
| 内核构建 | 本地候选配置启用了 AIISP、ISP V35 和 RKNPU | 对照烧录版本及运行态配置 |
| 设备初始化 | 历史 dmesg 有 rkaiisp 及 RKNPU probe 日志 | 核对节点可用和启动异常，分清 probe 与实际逐帧任务 |
| 应用运行库 | 本地有 AArch64 的 `libRkAIISP_64bit.so`，可见 init/proc/deinit 符号 | 记录目标进程实际映射的库及版本，核对 ABI |
| 模型和校准 | SDK 有带 rk3576、IMX415 命名的 BNR/TNR 示例文件 | 查 RV1126B 当前路径支持的模型、格式、标定与版本 |
| 执行 | 源码可跟读加载、配置、分配和提交 | 核对开始、完成、丢弃、降级和是否在用 |
| 成效 | 可以离线模拟平坦区噪声及运动残影 | 对同曝光 A/B，验证耗时、画质和内存 |

历史启动同时有 AIISP 缺 GRF 属性及 NPU 请求资源一类信息。保留原日志和驱动返回，避免仅根据 probe 字样判断工作正常。两种 SoC 的示例文件名也不能做模型迁移承诺。

## 同一 SDK 中有不同的 AI ISP 路径

`aiq_aiIspLoader.c` 加载 `libRkAIISP.so` 并查函数符号。 `rk_aiisp_param` 包含 ISP 采集尺寸、有效 RAW 位数、输入输出 fd、gain map、ISO、AWB 和 Bayer 等信息。另一套 AIBNR 路径可在 `RkAibnrManager.c` 看到 post-BNR 运行库，再通过 `RKAIISP_CMD_*` 管理缓冲等。两套接口需要明确所用宏、运行库和消息路径。

~~~c
obj->ops_.aiisp_proc = (rkaiq_aiisp_proc)dlsym(obj->handle_, "rk_aiisp_proc");
~~~

加载成功只拿到函数地址。之后仍要确认初始化按当前 sensor 模式通过，并在循环里将匹配的缓冲交给实际后处理。运行态证明可由执行计数、帧号、输入和输出时间，以及故障或降级记录构成。不需以程序名是否包含 AI 代替验证。

<Sdk id="aiisp-library-loader" />
<Sdk id="aiisp-queue-command" />

## 输入格式与物理内存为什么要重新核对

`AiqCamHw_setAiispMode()` 从 sensor descriptor 取 ISP 采集尺寸，再填 AI 路径的参数。示例代码设置 `rawBit = 12` 指定这一接口的有效位数；本板历史 sensor 传输却是 RAW10。两者处于不同环节，需要确认在哪一阶段、按什么容器和位位置得到后段数据。读取数据前要核对下列契约。

- **模型输入域**　Bayer 相位、有效位数和对齐、线性或已处理数据、尺寸、归一化与噪声参数。
- **缓冲描述**　stride、分配大小、fd、offset、内存可映射性、谁负责回收和等待硬件完成。
- **时序**　输入帧号、历史参考、输出对应关系、队列深度、时间戳及帧缺口。
- **回退**　初始化失败、超时、格式变化或拿不到缓冲时的清理和传统 ISP 路径恢复。

V35 的示例分配分支除了其它增益或时域状态，还给 AI ISP 循环分配缓冲并记录 fd。这里 w32 是该分支用于分配的对齐宽度。

~~~c
stride = w32 * 2;
size = stride * h;
~~~

未对齐的 3840×2160 每像素 2 字节容器，单缓冲约 16.59 MB，三块约 49.77 MB（47.46 MiB）。如果 30 fps 下确实完整读写一次，每秒有效数据约 995.33 MB。实际池大小要用分配返回、对齐、是否绕过内存和各中间面计算。DMA-BUF fd 只是句柄，源、加速器和 ISP 间还要处理生命周期、同步与导入可见性。 [3.15 DMA-BUF 导出、导入与同步](../03-Linux内核/dmabuf.md)

<Sdk id="aiisp-mode-raw-contract" />
<Sdk id="isp35-aiisp-allocation" />

## 宿主复现对照并保留证据

在 WSL 仓库根目录执行。可<a :href="exampleFile" download="aiisp-tradeoff-demo.awk">下载 aiisp-tradeoff-demo.awk</a>。模型复用同一组完全相同的曝光数据，唯一变化是是否在前后帧之间做平均。

~~~bash
LC_ALL=C awk -f learning-site/examples/aiisp-tradeoff-demo.awk
sdk=atk_dlrv1126b_linux6.1_sdk
rg 'CONFIG_VIDEO_ROCKCHIP_(AIISP|ISP_VERSION_V35)=|CONFIG_ROCKCHIP_RKNPU=' "$sdk/output/kernel-baseline/normal/.config"
rg -in 'rkaiisp.*probe end|Initialized RKNPU driver' output/camera-check/dmesg-before.log
lib="$sdk/external/camera_engine_rkaiq/rkaiq/algos/aiisp/aiisp_relate/imx415/libRkAIISP_64bit.so"
readelf -h "$lib" | grep -E 'Class:|Machine:'
readelf --dyn-syms -W "$lib" | awk '$7 != "UND" && $8 ~ /^rk_aiisp_(init|proc|deinit)$/ {print $8}'
~~~

平坦样本标准差由 5.24 降到 3.85，刚过运动边界的像素由当前帧 0.10、前一帧 0.80 混出 0.45。这一反例说明降噪与拖影需要同测。脚本实现的是普通时域平均，没有调用模型，也没有测 NPU 性能。本轮状态为构建、历史初始化和本地 ABI 核对，运行时功能未验证。

实机 off/on 比较应固定曝光、增益、内容、温度、频率和其它处理配置。看平坦区帧间噪声、细纹损伤和运动拖影，同时收集稳定帧率、sequence 缺口、分阶段耗时 P50/P95/P99、池占用峰值和功耗。绑定上板执行权限和服务归属后，再做有限对照。若状态缺证，先补模型加载、调用和帧级关联，再解释截图差异。

## 本节复盘

1. **驱动启动与 AI ISP 实际执行之间缺什么？** 当前固件、库与模型相容，运行态有调用、完成和输出关联。
2. **sensor RAW10 与加速路径 rawBit=12 能同时成立吗？** 可以是两个阶段的输入约定。要查变换及缓冲的有效位位置。
3. **为什么只报告降噪标准差不足以验收？** 还要比较纹理、运动残影、延迟、缓冲及功耗，确认代价在预算内。

下一节用固定的输入序列看 ePTZ 与自动取景，区分 ROI 平移、数字放大和真实光学变焦。 [7.10 光学变焦、数字变焦与自动取景](./advanced.md)
