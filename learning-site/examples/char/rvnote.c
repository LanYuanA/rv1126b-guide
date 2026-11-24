// SPDX-License-Identifier: GPL-2.0
#include <linux/fs.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/uaccess.h>

struct note_file {
	char text[128];
	size_t len;
	loff_t cursor;
	struct mutex lock;
};

static int note_open(struct inode *inode, struct file *file)
{
	struct note_file *note = kzalloc(sizeof(*note), GFP_KERNEL);

	if (!note)
		return -ENOMEM;
	mutex_init(&note->lock);
	file->private_data = note;
	return nonseekable_open(inode, file);
}

static ssize_t note_write(struct file *file, const char __user *src,
			  size_t count, loff_t *pos)
{
	struct note_file *note = file->private_data;
	char tmp[sizeof(note->text)];

	if (!count)
		return 0;
	if (count > sizeof(tmp))
		return -EMSGSIZE;
	/* 先复制到临时区，错误时保留上一条完整消息。 */
	if (copy_from_user(tmp, src, count))
		return -EFAULT;
	mutex_lock(&note->lock);
	memcpy(note->text, tmp, count);
	note->len = count;
	note->cursor = 0;
	mutex_unlock(&note->lock);
	return count;
}

static ssize_t note_read(struct file *file, char __user *dst,
			 size_t count, loff_t *pos)
{
	struct note_file *note = file->private_data;
	ssize_t n;

	mutex_lock(&note->lock);
	n = simple_read_from_buffer(dst, count, &note->cursor, note->text, note->len);
	mutex_unlock(&note->lock);
	return n;
}

static int note_release(struct inode *inode, struct file *file)
{
	kfree(file->private_data);
	return 0;
}

static const struct file_operations note_ops = {
	.owner = THIS_MODULE,
	.open = note_open,
	.read = note_read,
	.write = note_write,
	.release = note_release,
	.llseek = no_llseek,
};

static struct miscdevice note_dev = {
	.minor = MISC_DYNAMIC_MINOR,
	.name = "rvnote",
	.fops = &note_ops,
	.mode = 0600,
};

module_misc_device(note_dev);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Per-open note character device");
