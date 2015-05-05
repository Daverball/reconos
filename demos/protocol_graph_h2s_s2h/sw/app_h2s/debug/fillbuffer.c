///
/// \file fillbuffer.c
/// Fill the shared memory buffer
/// \author     David Salvisberg   <davidsa@student.ethz.ch>
/// \date       05.05.2015

#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <assert.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <math.h>

#include "fillbuffer.h"

#define PACKET_SIZE_1 64
#define PACKET_SIZE_2 129

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

struct noc_header noc_header_1 = {1, 0, 0, 0, 0, 0, PACKET_SIZE_1, 3, 2};

struct noc_header noc_header_2 = {1, 0, 0, 0, 0, 0, PACKET_SIZE_2, 3, 2};

void print_buffer(void * buffer, size_t size) //for debugging purposes
{
	assert(size % 4 == 0); // make sure we're working with a buffer of multiple word size
	unsigned int * ptr = (unsigned int *)buffer;
	int i;
	for(i = 0; i < (size/4); i++)
	{
		printf("0x%08x  ",*(ptr++));
		if ((i+1)%4==0){ 
			printf("\n");
		}
	}
}

void fill_buffer(void * buffer, size_t size)
{
	assert((PACKET_SIZE_1+PACKET_SIZE_2)*NUM_PACKETS_IN_BUFFER<2*size); //make sure we won't overflow the buffer
	assert(NUM_PACKETS_IN_BUFFER%2 == 0); //make sure we have an even number of packets for now
	void * buffer_orig = buffer;
	unsigned char * ptr;
	int i, j;
	struct noc_header * head_ptr;
	for(i = 0; i < NUM_PACKETS_IN_BUFFER; i+=2)
	{
		head_ptr = (struct noc_header *)buffer;
		*(head_ptr++) = noc_header_1;
		ptr = (unsigned char *)head_ptr;
		for(j = 12; j < PACKET_SIZE_1; j++)
		{
			*(ptr++) = 0xa0 + j % 4;
		}

		buffer = (unsigned int *)buffer + (PACKET_SIZE_1+3)/4; //advance forward in the buffer word aligned

		head_ptr = (struct noc_header *)buffer;
		*(head_ptr++) = noc_header_2;
		ptr = (unsigned char *)head_ptr;
		for(j = 12; j < PACKET_SIZE_2; j++)
		{
			*(ptr++) = 0xb0 + j % 4;
		}

		buffer = (unsigned int *)buffer + (PACKET_SIZE_2+3)/4; //advance forward in the buffer word aligned
	}
	
	//print_buffer(buffer_orig, size);
}