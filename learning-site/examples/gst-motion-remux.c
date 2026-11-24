/* 此实验只接收固定 10 fps、无 B 帧的 AVC 访问单元。 */
#include <gst/app/gstappsrc.h>
#include <stdio.h>

static gboolean push_clip(GstAppSrc *src, const gchar *dir, guint start, guint end)
{
	for (guint index = start; index <= end; index++) {
		gchar *path = g_strdup_printf("%s/au-%02u.h264", dir, index);
		gchar *bytes = NULL;
		gsize length = 0;
		gboolean ok = g_file_get_contents(path, &bytes, &length, NULL);

		if (!ok || !length) {
			g_printerr("无法读取访问单元 %s\n", path);
			g_free(path);
			g_free(bytes);
			return FALSE;
		}
		g_free(path);

		GstBuffer *buffer = gst_buffer_new_wrapped(bytes, length);
		GST_BUFFER_PTS(buffer) = (index - start) * (GST_SECOND / 10);
		GST_BUFFER_DTS(buffer) = GST_BUFFER_PTS(buffer);
		GST_BUFFER_DURATION(buffer) = GST_SECOND / 10;
		if (gst_app_src_push_buffer(src, buffer) != GST_FLOW_OK)
			return FALSE;
	}
	return gst_app_src_end_of_stream(src) == GST_FLOW_OK;
}

static gboolean wait_for_eos(GstBus *bus)
{
	GstMessage *message = gst_bus_timed_pop_filtered(bus, 5 * GST_SECOND,
						       GST_MESSAGE_ERROR | GST_MESSAGE_EOS);
	if (!message) {
		g_printerr("等待 MP4 封装结束超时\n");
		return FALSE;
	}
	gboolean eos = GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS;
	if (!eos) {
		GError *error = NULL;

		gst_message_parse_error(message, &error, NULL);
		g_printerr("封装失败 [%s] %s\n", GST_OBJECT_NAME(GST_MESSAGE_SRC(message)), error->message);
		g_clear_error(&error);
	}
	gst_message_unref(message);
	return eos;
}

int main(int argc, char **argv)
{
	guint start, end;
	char extra;
	GError *error = NULL;
	int result = 1;

	gst_init(NULL, NULL);
	if (argc != 5 || sscanf(argv[3], "%u%c", &start, &extra) != 1 ||
	    sscanf(argv[4], "%u%c", &end, &extra) != 1 || start > end || end >= 60) {
		g_printerr("用法：%s 访问单元目录 输出.mp4 首帧序号 末帧序号\n", argv[0]);
		return 2;
	}
	GstElement *pipe = gst_parse_launch(
		"appsrc name=input format=time caps=video/x-h264,stream-format=byte-stream,alignment=au,framerate=10/1 "
		"! h264parse ! mp4mux ! filesink name=output", &error);
	if (error || !pipe) {
		g_printerr("构建管线失败：%s\n", error ? error->message : "空对象");
		g_clear_error(&error);
		if (pipe)
			gst_object_unref(pipe);
		return 1;
	}
	GstElement *input = gst_bin_get_by_name(GST_BIN(pipe), "input");
	GstElement *output = gst_bin_get_by_name(GST_BIN(pipe), "output");
	GstBus *bus = gst_element_get_bus(pipe);

	g_object_set(output, "location", argv[2], NULL);
	if (gst_element_set_state(pipe, GST_STATE_PLAYING) != GST_STATE_CHANGE_FAILURE &&
	    push_clip(GST_APP_SRC(input), argv[1], start, end) && wait_for_eos(bus))
		result = 0;
	gst_element_set_state(pipe, GST_STATE_NULL);
	gst_object_unref(bus);
	gst_object_unref(output);
	gst_object_unref(input);
	gst_object_unref(pipe);
	return result;
}
