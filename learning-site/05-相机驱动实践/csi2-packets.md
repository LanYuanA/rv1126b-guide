# 5.6 CSI-2 的包、数据类型与虚拟通道

<script setup>
import exampleFile from '../examples/raw10-demo.c?url'
</script>

物理层接到数据以后，CSI-2 接收器还要找出帧边界、识别像素负载，并按虚拟通道交给下游。这一节先用四个样本验证字节布局，再区分同一帧在线上、pad 和应用内存里的三种描述。

## 先打包再解包四个 RAW10 样本

在 WSL 仓库根目录运行。示例只处理一组载荷字节，断言打包结果和解包往返。<a :href="exampleFile" download="raw10-demo.c">下载 RAW10 C 示例</a>。

~~~bash
mkdir -p output
cc -std=c11 -O2 -Wall -Wextra -Werror learning-site/examples/raw10-demo.c -o output/raw10-demo
./output/raw10-demo
~~~

样本是 000、155、2aa、3ff。前四字节分别取每个样本的高八位。第五字节从低到高按像素顺序拼低两位。本轮编码为 **00 55 aa ff e4**，解包返回原四值。若一行包含 3864 个样本，且每行完整传入一个 RAW10 长包，有效载荷为 3864 ÷ 4 × 5 = **4830 字节**。这个数无需加行步长或包校验。内存中的 packed Bayer 格式可以有同样的组内拼法，具体还要核对驱动给出的 FourCC 和 stride。[Linux packed Bayer 格式说明](https://docs.kernel.org/next/userspace-api/media/v4l/pixfmt-srggb10p.html)

## 帧和行怎样组织成包？

以经典 D-PHY 下的 CSI-2 基本包格式说明。帧开始与帧结束使用短包，像素和其他较长数据用长包承载。是否产生可选的行边界短包，要对照当前传感器输出。下图仅示意顺序，没有画每条 lane 的字节分配。

~~~text
帧：FS 短包 → 一组像素数据长包或其他数据包 → FE 短包
短包：数据标识 | 两字节短包数据 | 头部 ECC
长包：数据标识 | 两字节 Word Count | 头部 ECC | 有效载荷 | CRC
~~~

经典数据标识里的低 6 位是 DT，高 2 位是 VC 的基本部分。更高版本及扩展 VC 需按实际支持的标识规则解析。长包的 Word Count 表示载荷字节数。ECC 用于头部校验，长包末尾的 CRC 覆盖载荷。包数增加只能说明接收端见到了包，还要核对它们的类型、通道、帧边界和错误状态。[MIPI CSI-2 特性表](https://www.mipi.org/hubfs/Specification-Feature-Tables/MIPI-CSI-2-Version-History-Table-March-2026.pdf) · [MIPI 包结构示意](https://www.mipi.org/hubfs/Bangalore-Introspect-C-PHY-and-How-It-Enables-Next-Gen-Display-1.pdf)

## 从本地模式对上 DT、VC 与格式

在仓库根目录执行。第一条核对协议码，第二条查看不同模式给出的 VC。

~~~bash
k=atk_dlrv1126b_linux6.1_sdk/kernel-6.1
rg -n 'MIPI_CSI2_DT_(FS|FE|RAW10)\s' "$k/include/media/mipi-csi2.h"
rg -n -m8 '\.vc\[PAD' "$k/drivers/media/i2c/imx415.c"
~~~

线性模式选 PAD0 的 VC0。HDR 时先查这一模式的 VC 映射、曝光语义及接收端的路由。仅数 VC 的数量无法判断哪一路是长曝光。

| 观察位置 | 本例值 | 谁使用它 |
| --- | --- | --- |
| CSI-2 包 | RAW10 DT=0x2b、VC0 | CSI 接收器识别载荷类别并按通道区分 |
| sensor pad | SGBRG10_1X10 | 框架协商 Bayer 排列与位深，DT 值本身无法表达颜色排列 |
| 应用内存 | 历史 ISP mainpath 的 NV12 | 应用按 Y 与交错 UV 解释。若直接抓 RAW，另读实际 FourCC、packing 和 stride |

<Sdk id="csi-packet-types" />

## ECC 或 CRC 计数增长，先记录什么？

以下是本地接收器的一段错误分类。ERR1 有 CRC 标志时，驱动累加这一类计数，并提取相关 VC 提示。其他分支分别处理同步、帧边界和 ECC 等错误。

`drivers/media/platform/rockchip/cif/mipi-csi2.c:968`

~~~c
if (val & CSIHOST_ERR1_ERR_CRC) {
	err_list = &csi2->err_list[RK_CSI2_ERR_CRC];
	err_list->cnt++;
	is_add_cnt = true;
~~~

| 现象 | 进一步的区分证据 |
| --- | --- |
| 总包数增长，期待的曝光未到 | 核对模式、预期 VC/DT、过滤和实际每路帧边界 |
| SoT、ECC 或 CRC 随速率或线缆变化 | 固定模式和采样窗口，对照错误增量、上游开流及物理接收 |
| 输入完整，应用看到格式异常 | 检查 pad 的 Bayer 顺序、ISP 转换及应用内存平面和步长 |

一个错误计数可以对应多个事件，日志本身还可能限速。不能把告警行数当作丢帧数。此处仅做离线载荷与源码核对，未采集板端包。

## 本节复盘

1. RAW10 的第五字节怎样拼出来？说出 0xe4 的每两个比特来自哪一个像素。
2. 4830 字节在本例是哪一层的数？为什么应用的 bytesperline 可能另有取值？
3. 一个 VC 没进队列且没有看到 CRC 告警，下一步怎么缩小到路由或过滤？

下一节沿本板的接收端点向 CIF 和 ISP 验证路由。[5.7 Rockchip DPHY、CSI 接收器与 CIF](rockchip-receiver.md)
