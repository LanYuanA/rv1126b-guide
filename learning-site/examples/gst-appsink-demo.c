/* 宿主合成源实验。拉取有限样本，观察布局、时间戳和内存类型。 */
#include <gst/allocators/gstdmabuf.h>
#include <gst/app/gstappsink.h>
#include <gst/video/video.h>
#include <string.h>

static gboolean inspect_sample(GstSample *sample, guint number)
{
	GstBuffer *buffer = gst_sample_get_buffer(sample);
	GstCaps *caps = gst_sample_get_caps(sample);
	GstVideoInfo info;
	GstVideoFrame frame;
	guint dmabuf_blocks = 0;

	if (!buffer || !caps || !gst_video_info_from_caps(&info, caps) ||
	    GST_VIDEO_INFO_FORMAT(&info) != GST_VIDEO_FORMAT_NV12)
		return FALSE;
	if (number == 1) {
		gchar *description = gst_caps_to_string(caps);
		g_print("caps=%s\n", description);
		g_free(description);
	}
	for (guint i = 0; i < gst_buffer_n_memory(buffer); i++) {
		if (gst_is_dmabuf_memory(gst_buffer_peek_memory(buffer, i)))
			dmabuf_blocks++;
	}
	if (!gst_video_frame_map(&frame, &info, buffer, GST_MAP_READ))
		return FALSE;

	const guint8 *y = GST_VIDEO_FRAME_PLANE_DATA(&frame, 0);
	g_print("frame=%u pts=%" GST_TIME_FORMAT " bytes=%" G_GSIZE_FORMAT
		" y_stride=%d uv_stride=%d first_Y=%u memories=%u dmabuf=%u\n",
		number, GST_TIME_ARGS(GST_BUFFER_PTS(buffer)),
		gst_buffer_get_size(buffer),
		GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0),
		GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 1),
		(unsigned int)y[0], gst_buffer_n_memory(buffer), dmabuf_blocks);
	gst_video_frame_unmap(&frame);
	return TRUE;
}

static gboolean report_terminal(GstMessage *message)
{
	if (!message) {
		g_printerr("等待 bus 终止消息超时\n");
		return FALSE;
	}
	gboolean eos = GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS;

	if (eos) {
		g_print("bus EOS\n");
	} else {
		GError *error = NULL;

		gst_message_parse_error(message, &error, NULL);
		g_printerr("bus ERROR [%s] %s\n", GST_OBJECT_NAME(GST_MESSAGE_SRC(message)),
			   error->message);
		g_clear_error(&error);
	}
	gst_message_unref(message);
	return eos;
}

int main(int argc, char **argv)
{
	static const gchar *source =
		"videotestsrc num-buffers=3 ! "
		"video/x-raw,format=NV12,width=320,height=240,framerate=30/1 ! ";
	GError *error = NULL;
	guint count = 0;
	int result = 1;

	gst_init(NULL, NULL);
	if (argc > 2 || (argc == 2 && strcmp(argv[1], "--error"))) {
		g_printerr("用法：%s [--error]\n", argv[0]);
		return 2;
	}
	gchar *description = g_strconcat(source,
		argc == 2 ? "identity name=failure error-after=2 ! " : "",
		"appsink name=out sync=false max-buffers=2", NULL);
	GstElement *pipeline = gst_parse_launch(description, &error);
	g_free(description);
	if (error || !pipeline) {
		g_printerr("构建 pipeline 失败：%s\n", error ? error->message : "空对象");
		g_clear_error(&error);
		if (pipeline)
			gst_object_unref(pipeline);
		return 1;
	}

	GstElement *sink = gst_bin_get_by_name(GST_BIN(pipeline), "out");
	GstBus *bus = gst_element_get_bus(pipeline);
	GstMessageType end_types = GST_MESSAGE_ERROR | GST_MESSAGE_EOS;
	GstMessage *terminal = NULL;

	if (gst_element_set_state(pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
		report_terminal(gst_bus_timed_pop_filtered(bus, GST_SECOND, end_types));
		goto finished;
	}

	const gint64 deadline = g_get_monotonic_time() + 3 * G_TIME_SPAN_SECOND;
	while (g_get_monotonic_time() < deadline) {
		GstSample *sample = gst_app_sink_try_pull_sample(GST_APP_SINK(sink), 100 * GST_MSECOND);

		if (!sample) {
			terminal = gst_bus_timed_pop_filtered(bus, 0, end_types);
			if (terminal)
				break;
			if (gst_app_sink_is_eos(GST_APP_SINK(sink))) {
				terminal = gst_bus_timed_pop_filtered(bus, GST_SECOND, end_types);
				break;
			}
			continue;
		}
		gboolean valid = inspect_sample(sample, ++count);
		gst_sample_unref(sample);
		if (!valid) {
			g_printerr("样本的格式或映射无效\n");
			goto finished;
		}
	}
	if (report_terminal(terminal) && count == 3 && argc == 1)
		result = 0;

finished:
	gst_element_set_state(pipeline, GST_STATE_NULL);
	gst_object_unref(bus);
	gst_object_unref(sink);
	gst_object_unref(pipeline);
	return result;
}
