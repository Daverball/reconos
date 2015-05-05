///
/// \file reconos.h
/// Dummy header for debug build on a generic linux distro
/// \author     David Salvisberg   <davidsa@student.ethz.ch>
/// \date       05.05.2015

#ifndef __RECONOS_H__
#define __RECONOS_H__

#include <pthread.h>
#include <stdint.h>

#define RECONOS_TYPE_MBOX			0x00000001
#define RECONOS_TYPE_SEM			0x00000002
#define RECONOS_TYPE_MUTEX			0x00000004
#define RECONOS_TYPE_COND			0x00000008
#define RECONOS_TYPE_RQ				0x00000010

typedef uint32_t uint32;

struct reconos_resource {
	void *ptr;
	uint32_t type;
};

struct reconos_hwt {
	pthread_t delegate;
	int slot;
	struct reconos_resource* resources;
	size_t num_resources;
	void *init_data;
};

extern int reconos_init_autodetect(void) { return 0; }
extern void reconos_cache_flush(void) {}

extern void reconos_hwt_setresources(struct reconos_hwt *hwt,
				     struct reconos_resource *res,
				     size_t num_resources) {}
extern int reconos_hwt_create(struct reconos_hwt *hwt, int slot, void *arg) { return 0; }

#endif