///
/// \file packetgen.h
/// generate packets of fixed size at fixed data rate
/// \author     David Salvisberg   <davidsa@student.ethz.ch>
/// \date       05.05.2015

#ifndef __PACKETGEN_H__
#define __PACKETGEN_H__

#include <stdbool.h>

struct noc_header {
	unsigned char hw_addr_switch:4,
	   hw_addr_block:2,
	   priority:2;
	unsigned char direction:1,
	   latency_critical:1,
	   reserved:6;
	unsigned short payload_len;
	unsigned int src_idp;
	unsigned int dst_idp;
};

struct generate_packets_context {
	unsigned int packet_size;
	unsigned int buffer_size;
	unsigned int timeout_ms;
	signed int data_rate;
	volatile void ** base_address; // read-only for thread
	volatile unsigned int * bytes_written;
	sem_t * packet_written; // exclusive write for thread
	sem_t * buffer_ready; // read-only for thread
};

void *generate_packets(void * arg);

#endif
