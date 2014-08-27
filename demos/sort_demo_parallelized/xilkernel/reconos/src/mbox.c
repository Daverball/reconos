#include "xmk.h"
#include "sys/init.h"
#include "mb_interface.h"

#include <stdlib.h>
#include <stdio.h>
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include "mbox.h"
#include "logging.h"
#include "reconos_utils.h"

//#define DEBUG logging_debug

int mbox_init(struct mbox *mb, size_t size)
{
	int ret;

	mb->read_idx = 0;
	mb->write_idx = 0;
	mb->size = size;
	mb->fill = 0;

	ret = pthread_mutex_init(&mb->mutex_read, NULL);
	if (ret)
		goto out_err;
	ret = pthread_mutex_init(&mb->mutex_write, NULL);
	if (ret)
		goto out_err;

	mb->messages = xmalloc_aligned(mb->size * sizeof(*mb->messages),
				       sizeof(void *) * 8);
	return 0;
out_err:
	return -EIO;
}

void mbox_destroy(struct mbox *mb)
{
	free(mb->messages);

	pthread_mutex_destroy(&mb->mutex_read);
	pthread_mutex_destroy(&mb->mutex_write);
}

void mbox_put(struct mbox *mb, uint32_t msg)
{
	DEBUG("%i: mbox_put (1): 0x%x\r\n", pthread_self(), msg);
	pthread_mutex_lock(&mb->mutex_write);
	DEBUG("mbox_put (2)\r\n", pthread_self());

	while(mb->fill >= mb->size){
		yield();
	}

	DEBUG("%i: mbox_put (3)\r\n", pthread_self());

	mb->messages[mb->write_idx] = msg;
	mb->write_idx = (mb->write_idx + 1)  % mb->size;
	mb->fill++;

	pthread_mutex_unlock(&mb->mutex_write);
	DEBUG("%i: mbox_put (4)\r\n", pthread_self());
}

uint32_t mbox_get(struct mbox *mb)
{
	uint32_t msg;

	DEBUG("%i: mbox_get (1)\r\n", pthread_self());
	pthread_mutex_lock(&mb->mutex_read);
	DEBUG("%i: mbox_get (2)\r\n", pthread_self());

	while(mb->fill <= 0){
		yield();
	}

	DEBUG("%i: mbox_get (3)\r\n", pthread_self());

	msg = mb->messages[mb->read_idx];
	mb->read_idx = (mb->read_idx + 1) % mb->size;
	mb->fill--;

	pthread_mutex_unlock(&mb->mutex_read);
	DEBUG("%i: mbox_get (4): 0x%x\r\n", pthread_self(), msg);
	return msg;
}
