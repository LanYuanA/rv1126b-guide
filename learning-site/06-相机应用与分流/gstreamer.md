# GStreamer 学习入口与 WSL 环境

- [6.1 GStreamer 元素、pad 与 caps](./gst-elements.md)
- [6.2 pipeline 状态、时钟、PTS 与 bus](./gst-timing.md)
- [6.3 v4l2src、appsink 与内存协商](./gst-appsink.md)

<a id="local-runtime"></a>

## WSL 宿主运行环境

本工作区在 WSL 中将已缓存的 Ubuntu deb 包解压到实验目录。若当前终端没有 gst-launch，在工作区根目录执行下面整段，保留该终端供后续实验使用，无需安装系统包。依赖系统已有 GStreamer core、GLib 和 coreelements。换主机可用发行版提供的 `gstreamer1.0-tools`、`gstreamer1.0-plugins-base`、`gstreamer1.0-plugins-good` 提供对应命令与绑定。

~~~bash
gstroot="$PWD/output/textbook-check/gst"
mkdir -p "$gstroot"
for pkg in gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good libgstreamer-plugins-base1.0-0 liborc-0.4-0t64 gir1.2-gstreamer-1.0; do
  for deb in /var/cache/apt/archives/"$pkg"_*.deb; do
    if test -f "$deb"; then dpkg-deb -x "$deb" "$gstroot"; fi
  done
done
export PATH="$gstroot/usr/bin:$PATH"
export LD_LIBRARY_PATH="$gstroot/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export GST_PLUGIN_PATH="$gstroot/usr/lib/x86_64-linux-gnu/gstreamer-1.0"
export GI_TYPELIB_PATH="$gstroot/usr/lib/x86_64-linux-gnu/girepository-1.0"
export GST_REGISTRY="$gstroot/registry.bin"
gst-launch-1.0 --version
gst-inspect-1.0 videotestsrc >/dev/null
~~~

若这里显示命令或插件缺失，在进入实验前先核对上面相应软件包。首次运行可能报告其他无关插件缺少动态库，可以用 `gst-inspect-1.0 元素名` 单独确认实际使用的每个元素。

<a id="local-build-env"></a>

## WSL 解包式 C 构建环境

仓库根目录下的 `output/textbook-check/gst` 已放入这次使用的运行库和开发头文件。Ubuntu 24.04 x86_64 上，如果需建立同样的本地环境，在仓库根目录下载并解包。命令不需要管理员权限。其他架构使用对应发行版的运行包和开发包。

~~~bash
gstroot="$PWD/output/textbook-check/gst"
mkdir -p "$gstroot" output/gst-dev-debs
(
  cd output/gst-dev-debs
  apt-get download pkgconf-bin libpkgconf3 libglib2.0-dev libglib2.0-0t64 \
    libgstreamer1.0-dev libgstreamer1.0-0 libgstreamer-plugins-base1.0-dev \
    libgstreamer-plugins-base1.0-0 gstreamer1.0-tools gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good liborc-0.4-0t64 liborc-0.4-dev libdrm-dev libdrm2 \
    libpcre2-dev libffi-dev libunwind-dev libdw-dev libelf-dev zlib1g-dev libbz2-dev liblzma-dev libzstd-dev
)
for deb in output/gst-dev-debs/*.deb; do dpkg-deb -x "$deb" "$gstroot"; done
~~~

在同一终端按上一节导出运行环境。然后让 pkgconf 从解包路径读 `.pc` 并用该目录作为 sysroot。若已用发行版包安装开发环境，可直接用系统 pkg-config。

~~~bash
export PKG_CONFIG_LIBDIR="$gstroot/usr/lib/x86_64-linux-gnu/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$gstroot"
gst_pc="$gstroot/usr/bin/pkgconf"
"$gst_pc" --modversion gstreamer-app-1.0
~~~

<a id="local-codecs"></a>

## WSL 的 H.264 与 H.265 实验插件

已经使用发行版标准安装的环境，可先检查 x264enc、x265enc、h264parse、h265parse、openh264dec 和 libde265dec。Ubuntu 24.04 x86_64 的解包式环境可在上述运行目录基础上增加插件和对应库。

~~~bash
gstroot="$PWD/output/textbook-check/gst"
mkdir -p "$gstroot" output/gst-codec-debs
(
  cd output/gst-codec-debs
  apt-get download gstreamer1.0-plugins-ugly gstreamer1.0-plugins-bad \
    libgstreamer-plugins-bad1.0-0 libx264-164 libx265-199 libopenh264-7 libde265-0
)
for deb in output/gst-codec-debs/*.deb; do dpkg-deb -x "$deb" "$gstroot"; done
for element in x264enc x265enc h264parse h265parse openh264dec libde265dec; do
  gst-inspect-1.0 "$element" >/dev/null || break
done
~~~

这组软件编解码插件用于宿主实验。若插件扫描打印其他插件的库缺失，优先逐条确认此次命令使用的元素。板端硬件解码和编码沿 Rockchip 的运行库单独确认。
