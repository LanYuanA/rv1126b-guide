/* 同一份 4×4 数据，逐项改变行步长、UV 次序、量化范围和矩阵。 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

enum { WIDTH = 4, HEIGHT = 4, STRIDE = 6, ZOOM = 32 };

static const uint8_t frame[] = {
	16,  36,  68,  88, 0xee, 0xee,
	96, 116, 148, 168, 0xee, 0xee,
	48,  68, 100, 120, 0xee, 0xee,
	156, 176, 208, 235, 0xee, 0xee,
	128, 128, 170,  94, 0xee, 0xee,
	100, 180, 128, 128, 0xee, 0xee,
};

struct interpretation {
	const char *name;
	int stride;
	bool swap_uv;
	bool limited;
	bool bt709;
};

static uint8_t code(double value)
{
	if (value < 0)
		return 0;
	if (value > 255)
		return 255;
	return (uint8_t)(value + 0.5);
}

static void to_rgb(const struct interpretation *layout, int x, int y, uint8_t rgb[3])
{
	const uint8_t *luma = frame + y * layout->stride;
	const uint8_t *chroma = frame + HEIGHT * layout->stride +
				(y / 2) * layout->stride + (x / 2) * 2;
	double y_value = luma[x];
	double cb = chroma[layout->swap_uv ? 1 : 0] - 128.0;
	double cr = chroma[layout->swap_uv ? 0 : 1] - 128.0;

	if (layout->limited) {
		y_value = (y_value - 16) * 255 / 219;
		cb *= 255.0 / 224;
		cr *= 255.0 / 224;
	}
	double kr = layout->bt709 ? 0.2126 : 0.299;
	double kb = layout->bt709 ? 0.0722 : 0.114;
	double r = y_value + 2 * (1 - kr) * cr;
	double b = y_value + 2 * (1 - kb) * cb;
	double g = (y_value - kr * r - kb * b) / (1 - kr - kb);

	rgb[0] = code(r);
	rgb[1] = code(g);
	rgb[2] = code(b);
}

static int render(const struct interpretation *layout)
{
	uint8_t rgb[3], neutral[3];
	FILE *file = fopen(layout->name, "wbx");

	if (!file)
		return -1;
	fprintf(file, "P6\n%d %d\n255\n", WIDTH * ZOOM, HEIGHT * ZOOM);
	for (int y = 0; y < HEIGHT * ZOOM; y++) {
		for (int x = 0; x < WIDTH * ZOOM; x++) {
			to_rgb(layout, x / ZOOM, y / ZOOM, rgb);
			fwrite(rgb, 1, sizeof(rgb), file);
		}
	}
	int failed = ferror(file);
	if (fclose(file) == EOF || failed)
		return -1;

	to_rgb(layout, 0, 0, neutral);
	to_rgb(layout, 2, 0, rgb);
	printf("%s 中性点=%u/%u/%u 色块点=%u/%u/%u\n", layout->name,
	       (unsigned)neutral[0], (unsigned)neutral[1], (unsigned)neutral[2],
	       (unsigned)rgb[0], (unsigned)rgb[1], (unsigned)rgb[2]);
	return 0;
}

int main(void)
{
	const struct interpretation cases[] = {
		{"correct-601-limited.ppm", STRIDE, false, true, false},
		{"wrong-stride.ppm", WIDTH, false, true, false},
		{"wrong-uv.ppm", STRIDE, true, true, false},
		{"wrong-range.ppm", STRIDE, false, false, false},
		{"different-matrix.ppm", STRIDE, false, true, true},
	};

	for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
		if (render(&cases[i]) < 0) {
			perror(cases[i].name);
			return 1;
		}
	}
	return 0;
}
