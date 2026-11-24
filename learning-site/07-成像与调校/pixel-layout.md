# 7.2 RAW10、RAW12、NV12 与色彩解释

<script setup>
import exampleFile from '../examples/nv12-layout-demo.c?url'
</script>

同一份帧刚好有 12,441,600 字节，却可能显示成正确画面、错行或严重偏色。先认清数据在哪一层，再查内存布局，最后决定颜色怎样换算。

## 位深、Bayer 和传输打包分别描述什么

RAW10 的一份采样有 10 个有效位，RAW12 有 12 个有效位。理想的码范围分别是 0…1023 和 0…4095。Bayer 格式还要知道采样点的颜色相位。 `SGBRG10_1X10` 是媒体总线代码，说明了 Bayer 次序与总线上的样本宽度。用户态要怎样读内存，仍由该视频节点返回的 FourCC 与步长约定。

| 层 | 查什么 | 例子 |
| --- | --- | --- |
| 采样阵列 | 2×2 Bayer 排列、裁剪起点与有效位数 | GBRG 10 位 |
| CSI-2 传输 | 包的数据类型与负载打包 | 4 个 RAW10 样本占 5 字节负载 |
| 内存格式 | V4L2 FourCC、stride、plane、有效长度 | packed RAW10 或按 16 位字存放的 10 位有效样本 |
| 成像输出 | 已经经过 ISP 的像素表示 | 8 位 4:2:0 NV12 |

packed RAW10 的四个高 8 位分别写到前四字节，最后一字节依次装四份低 2 位。例如 `00 55 aa ff e4` 还原为 0、341、682、1023。packed RAW12 则以两个一组，例如 `0x123, 0xabc` 编为 `12 ab c3`，因为最后一字节低半放首个样本的 3，高半放第二个样本的 c。含行填充的布局还得每行按 stride 走。每样本使用 16 位容器时，不沿用上述 packed 解包。相机的数据类型和端到端打包细节见[卷五 CSI-2](../05-相机驱动实践/csi2-packets.md)。 [Linux packed RAW10](https://docs.kernel.org/6.1/userspace-api/media/v4l/pixfmt-srggb10p.html) · [Linux packed RAW12](https://docs.kernel.org/6.1/userspace-api/media/v4l/pixfmt-srggb12p.html)

## 4×4 NV12 有几个 plane

四行亮度、两行色度。假定 stride 为 6，则包含下列字节，`·` 表示对齐填充。NV12 的 U、V 是 Cb、Cr，颜色差分每个 2×2 亮度块共享一对。NV21 把同一位置的顺序换成 V、U。

~~~text
Y   16  36  68  88  ·  ·
Y   96 116 148 168  ·  ·
Y   48  68 100 120  ·  ·
Y  156 176 208 235  ·  ·
UV 128 128 170  94  ·  ·   对应上面两行
UV 100 180 128 128  ·  ·   对应下面两行
~~~

图像格式有 Y 和交错 UV 两个分量区域，两者可连续存于同一个映射。V4L2 的 MPLANE 表达 ABI 形态，`num_planes=1` 时仍可以用一个 memory plane 交付整张 NV12。NV12M 允许 Y/UV 分成各自 memory plane。查像素时结合映射起点、data_offset 和有效长度，确保读到的位置还属于当前帧。

~~~c
const uint8_t *luma = frame + y * layout->stride;
const uint8_t *chroma = frame + HEIGHT * layout->stride +
                        (y / 2) * layout->stride + (x / 2) * 2;
~~~

本实验的 `frame` 从有效载荷开头算，已知 Y 与 UV 具有相同步长。x/2 定位 2 像素共用的色度块，乘 2 定位交错字节。实际应用要优先用驱动返回值验证尺寸与偏移。SDK 的 `rkisp_set_fmt` 路径按对齐计算 bytesperline 和每个图像区域的大小，只有一个 memory plane 时汇总总大小，说明 width 只是最少的有效行内容。 [Linux NV12 与连续平面布局](https://docs.kernel.org/6.1/userspace-api/media/v4l/pixfmt-yuv-planar.html)

<Sdk id="rkisp-image-layout" />

## 把 YUV 换成可显示的 RGB，还需要哪些信息

| 元数据 | 作用 |
| --- | --- |
| colorspace | 色度基色、白点和默认解释；同分辨率可有不同 colorspace |
| xfer_func | 线性光与带撇号码值之间的传递关系 |
| ycbcr_enc | Y′、Cb、Cr 和 R′G′B′ 的矩阵关系，如 BT.601 或 BT.709 |
| quantization | 8 位 limited 亮度通常映射到 16…235，色度 16…240；full 用更宽的码范围 |
| chroma siting | 共享色度采样相对亮度网格的位置，影响上采样 |

色度中心通常位于 128。把 limited 的 Y=16 当作 full，会把本应是黑的中性点看成 16 级灰，Y=235 也到不了纯白。若只交换 UV，亮度数据一点也没变，颜色却可能从蓝倾向变成红。BT.601 和 BT.709 的权重不同，即使范围和步长都正确，颜色也能有差异。 [Linux colorspace 与矩阵说明](https://docs.kernel.org/6.1/userspace-api/media/v4l/colorspaces-details.html)

## 保持字节不变，每次改一个解释参数

在 WSL 仓库根目录构建和运行。示例把 4×4 结果最近邻放大到 128×128 的 PPM，便于看色块。可<a :href="exampleFile" download="nv12-layout-demo.c">下载 nv12-layout-demo.c</a>。

~~~bash
mkdir -p output
lab=$(mktemp -d "$PWD/output/nv12-layout.XXXXXX")
cc -std=c11 -Wall -Wextra -Werror learning-site/examples/nv12-layout-demo.c -o "$lab/nv12-layout-demo"
(cd "$lab" && ./nv12-layout-demo)
file "$lab/"*.ppm
~~~

| 解释 | 左上中性点 RGB | 第一行右侧色块一个点的 RGB |
| --- | --- | --- |
| 正确，stride 6、UV、BT.601 limited | 0/0/0 | 6/72/145 |
| 行步长错填 4 | 176/0/222 | 137/11/117 |
| 交换 UV | 0/0/0 | 128/40/0 |
| 按 full 解 limited | 16/16/16 | 20/78/142 |
| 同格式用 709 矩阵 | 0/0/0 | 0/70/149 |

切换步长后，UV 区也被算成从错误起点开始。仅交换 UV，中心色度为 128 的中性点保持原样而有色位置变化。这两种结果有助于区分地址错与颜色解释错。示例使用最近邻色度和简单值域处理，用于观察方向与差异。精确色彩管理还要按照实机元数据处理取样位置、传递函数和基色。

## 用历史样本复查一帧的说明表

~~~bash
wc -c output/camera-check/frame.nv12
rg -n 'SGBRG10|smpte170m|quantization' output/camera-check/isp-before.log
file output/camera-check/preview.png
~~~

历史记录为 3840×2160、NV12、stride 3840、一个内存 plane，文件大小 12,441,600 字节。历史媒体图的 ISP 输出 pad 报 SMPTE170M 与 full-range。它是该 pad 的元数据，应用还应在当前视频节点用 G_FMT 逐项核对 `colorspace/ycbcr_enc/quantization/xfer_func`。已有预览是按 full-range BT.601 的观察性转换，静态样本无需调整硬件。真实输出要由当前节点的布局、颜色字段及实拍色卡交叉确认。

## 本节复盘

1. **RAW10 提供十位，为什么驱动可能每样本用两个字节？** 有效位数描述码值宽度，内存格式可选紧位打包或较宽容器。按 FourCC、stride 和有效范围解析。
2. **MPLANE 下一块 memory plane，为什么仍能读 Y 和 UV？** 两个分量区域连续放入一块内存，API 内的 plane 数目只描述映射。
3. **保存大小对且亮度正常，偏色先查哪里？** 先确认 UV 顺序、矩阵、量化范围和色度位置。也要区分输出解释造成的偏色与设备的白平衡设置。

下一节从输入 RAW 到输出 NV12，依照 ISP 各模块的职责解释哪些变化发生在图像生成之前。 [7.3 ISP 图像处理流程](./isp-pipeline.md)
