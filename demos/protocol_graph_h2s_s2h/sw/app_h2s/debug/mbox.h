///
/// \file mbox.h
/// Dummy header for debug build on a generic linux distro
/// \author     David Salvisberg   <davidsa@student.ethz.ch>
/// \date       05.05.2015

#ifndef __MBOX_H__
#define __MBOX_H__

#include <semaphore.h>
#include <pthread.h>
#include <stdint.h>

#include "fillbuffer.h"

struct mbox {
	sem_t sem_read;
	sem_t sem_write;
	pthread_mutex_t mutex_read;
	pthread_mutex_t mutex_write;	
	uint32_t *messages;
	off_t read_idx;
	off_t write_idx;
	size_t size;
};

extern int mbox_init(struct mbox *mb, size_t size) { return 0; }
extern void mbox_destroy(struct mbox *mb) {}
extern void mbox_put(struct mbox *mb, uint32_t msg) {}
extern uint32_t mbox_get(struct mbox *mb) { return NUM_PACKETS_IN_BUFFER; }

#endif 
