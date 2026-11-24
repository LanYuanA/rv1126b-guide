# 6.5 Rockchip VI、VPSS、VENC 与 MPP

<script setup>
import exampleFile from '../examples/rockchip-media-audit.sh?url'
</script>

要把单颗 IMX415 的主图缩到 720p 再编码，应在哪一层改分辨率？先沿本地 SDK 样例核对 VI 输入、VPSS 输出、VENC 输入以及最后拿到的码流。样例中的三个通道都叫 0，属于不同模块。

## 从相机主路径到编码包，物理和逻辑各标一层

~~~text
IMX415 → CSI/CIF → ISP mainpath → VI 的采集通道
                                  ↓ SYS Bind
                              VPSS 组与输出通道 → 原始 YUV
                                  ↓ SYS Bind
                              VENC 编码通道 → 编码包 → 应用 → 文件或网络
~~~

| 模块 | 在本例中做什么 | 应用配置或取得什么 |
| --- | --- | --- |
| VI | 从 ISP 输出收图，连接 device、pipe 与 channel | 输入尺寸、YUV 布局、缓冲数量和内存模式 |
| VPSS | 给输入图像做处理，按组管理一个或多个输出通道 | 组的输入上限，通道的输出尺寸、格式、压缩模式 |
| VENC | 接收原始图像，产生 H.264/H.265/MJPEG 等编码数据 | 通道输入尺寸和格式、码控和输出缓冲。主动取码流并归还 |
| SYS | 初始化 Rockit 媒体系统并设置模块间绑定关系 | 按 `module, device, channel` 描述每端 |

本地 `simple_vi_bind_vpss_bind_venc.c` 的 RV1126B 分支说明 VI 0 对应 mainpath。这里的通道 0 是厂商 API 逻辑编号，历史 `/dev/video23` 是当时的 Linux 视频设备号，仍须通过媒体实体对应。样例默认 VI 输入 1920×1080、VPSS 输出 1280×720，VENC 创建时使用 VPSS 的输出尺寸。原厂实测的 4K NV12 属于此前的 V4L2 路径，规格与本样例的默认值分别记录。

## 配置尺寸和绑定是两个动作

VI 填 `stIspOpt.u32BufCount=2`，选择 `VI_V4L2_MEMORY_TYPE_DMABUF`，写输入宽高、`RK_FMT_YUV420SP` 与不压缩的内存布局。样例给绑定用的 VI 通道设 `u32Depth=0`。若应用想主动 GetChnFrame，还需检查队列深度和相应释放接口。 `RK_FMT_YUV420SP` 在 SDK 枚举注释里是 Y 后跟 UV，与单独的 VU 枚举不同。

VPSS 先 CreateGrp，再以组和输出通道为参数设置属性，随后 EnableChn、StartGrp。缩放要改的是输出通道的 `u32Width/u32Height`，VENC 的图片宽高和实际输入相匹配。buffer 的虚宽、虚高以及行对齐另行核对。RV1126B 样例还可设置 wrap line，默认禁用。若要开启，VPSS 和 VENC 侧均要确认对应属性、限制和效果。

<Sdk id="rockit-vpss-channel" />

~~~c
stvpssChn.enModId = RK_ID_VPSS;
stvpssChn.s32DevId = 0;
stvpssChn.s32ChnId = 0;
~~~

首次绑定从 `(VI, 0, s32chnlId)` 到 `(VPSS, 0, 0)`；第二次从 `(VPSS, 0, 0)` 到 `(VENC, 0, 0)`。和 V4L2 媒体图的 link 一样，端点写错会让链路无法按计划工作。二者属于不同接口层。SYS Bind 需要模块状态及格式成立，媒体图则表达内核子设备和 pad 的关系。绑定成功还要通过编码出包与解码文件验证。

<Sdk id="bind" />

## 编码包由谁持有、什么时候还

`RK_MPI_VENC_StartRecvFrame()` 让通道接收原始帧。应用再通过 `RK_MPI_VENC_GetStream()` 取得 `VENC_STREAM_S`，其中每个 `VENC_PACK_S` 描述媒体缓冲、有效长度、偏移和 PTS。样例取成功后写包，然后调用 ReleaseStream 归还。正式程序要按接口检查实际 pack 数、长度与 offset，处理失败仍应归还成功取得的包。

~~~c
s32Ret = RK_MPI_VENC_ReleaseStream(0, &stFrame);
~~~

归还后应用再访问映射得到的地址就可能读到下一次复用的数据。若备份文件写入慢，可考虑把码流安全移交到独立有限队列，量化保留原缓冲或复制压缩数据的成本。样例的等待参数 `-1` 会无限等输出，对关停敏感的实现应选择可响应的等待方案。样例计数还用 `loopCount > g_s32FrameCnt` 判断结束，复现实验时不能把此选项直接当成严格的包数断言。

<Sdk id="rockit-venc-pack" />

## MPP 的编码边界与 Rockit 的模块接口

SDK 里的 MPP `mpi_enc_test.c` 直接 `mpp_create`、`mpp_init(..., MPP_CTX_ENC, ...)` 创建编码上下文，通过 `MppFrame` 关联输入内存后提交给编码器。输出用 `MppPacket` 取得有效数据位置、长度和 EOS。从创建上下文到销毁，资源由这套 MPP 接口管理。

~~~c
ret = mpi->encode_put_frame(ctx, frame);
~~~

送进去的是待编码原始帧，出来的是压缩码流。若启用切片输出，一帧关联的多个产出还要按包的边界和元数据处理。Rockit 的 `RK_MPI_VENC_*` 面向整套媒体模块通道，MPP 的 `MppApi` 面向独立编解码上下文。两套 API 有不同的对象、返回和归还规则。当前 SDK 的 arm64 RV1126B `librockit.so` 在 ELF 的 NEEDED 中列出 `librockchip_mpp.so.1`。这条依赖能证明该库需要 MPP，单凭它仍无法证明某条路径是否复制或每帧具体走了哪个实现分支。 [Rockchip MPP 源码与架构](https://github.com/rockchip-linux/mpp)

<Sdk id="rockchip-mpp-encode" />

## 离线复现，以及上板前的检查

在 WSL 仓库根目录运行。脚本只读已有 SDK 的源码与 ELF，打印两次绑定和对应解绑、MPP 编码调用、AArch64 架构及 Rockit 的动态符号。可<a :href="exampleFile" download="rockchip-media-audit.sh">下载 rockchip-media-audit.sh</a>。

~~~bash
bash learning-site/examples/rockchip-media-audit.sh
~~~

本轮核对到 Bind 在样例 588、598 行，解绑顺序相反。SDK 的 arm64 Rockit 提供六个对应符号，库依赖中有 MPP。上板时再查看程序 ELF 架构、实际根文件系统中的 so 和 ABI，以及运行态摄像头归属。这个样例只有传 IQ 路径且编入 RKAIQ 条件时会启动自身 ISP 控制，已有 3A 服务时先核实初始化所有者。分支宏 `RV1126B` 控制通道说明和 wrap；编译时选用正确目标平台，方可把这些条件当成样例行为。

失败退出要以“成功获得过哪些资源”为依据。正常路径停止新任务、处理在途数据并归还已取输出，等待线程退出，再按成功绑定的逆序解绑，停通道/组并销毁，最终释放系统初始化。SDK 样例把多种错误跳到同一清理标签，部分失败时可能对尚未成功建立的端点执行 UnBind，且初始化调用未逐个检查返回值。产品实现要记录每一步成功状态，并定义超时与二次进入的行为。

## 本节复盘

1. **VPSS 给 720p，VENC 还填 1080p 会怎样？** 两端期待的实际图像规格不同。先对照输出通道和编码输入格式，再定位 Bind/收帧失败。通道存在只能证明它已注册。
2. **同一个 VI 帧给两个编码通道，成本可能在哪增加？** 两套编码资源、参考帧和码流缓冲会增加，独立缩放可能要更多内存流量，较慢的通道会延长输入引用寿命。按单支和并发对照测量。
3. **GetStream 成功后何时才能释放？** 用完有效数据、元数据或把数据安全交给其他持有者以后，按这个通道调用 ReleaseStream。失败路径同样要处理已取得的包。

下一节从 VENC 的压缩数据继续往下，拆 GOP、关键帧、封装以及怎样生成可以独立解码的切片。 [6.6 H.264/H.265、GOP、封装与分段](./video-segments.md)
