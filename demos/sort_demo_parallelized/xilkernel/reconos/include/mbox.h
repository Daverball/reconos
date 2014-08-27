#ifndef MBOX_H
#define MBOX_H

#include <semaphore.h>
#include <pthread.h>
#include <stdint.h>

struct mbox {
	pthread_mutex_t mutex_read;
	pthread_mutex_t mutex_write;
	uint32_t *messages;
	off_t read_idx;
	off_t write_idx;
	int fill;
	size_t size;
};

extern int mbox_init(struct mbox *mb, size_t size);
extern void mbox_destroy(struct mbox *mb);
extern void mbox_put(struct mbox *mb, uint32_t msg);
extern uint32_t mbox_get(struct mbox *mb);

#endif /* MBOX_H */
