///
/// \file packetgen.c
/// generate packets of fixed size at fixed data rate
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
#include <semaphore.h>

#include "packetgen.h"
#include "timing.h"

#define MAX_PACKET_SIZE 1500

void *generate_packets(void * context)
{
	unsigned char * ptr;
	unsigned int * word_ptr;
	int i;
	struct noc_header * head_ptr;
	struct generate_packets_context * c = (struct generate_packets_context *) context;
	us_t period = 0;
	us_t timeout = 1000*c->timeout_ms;
	us_t time_taken = 0, surplus = 0;
	timing_t period_start;

	unsigned int payload_size = c->packet_size-12;
	unsigned int aligned_size = 4*((c->packet_size+3)/4);
	unsigned int num_packets = ((c->buffer_size-1504) + (aligned_size-1))/aligned_size;
	if(c->buffer_size < MAX_PACKET_SIZE) //if we specified less than max packet size we want to use single packet buffering
	{
		num_packets = 1;
	}
	num_packets = max(num_packets, 1); //always write at least one packet
	struct noc_header header = {1, 0, 0, 0, 0, 0, payload_size, 3, 2};
	unsigned char * payload = malloc(payload_size);
	for(i=0; i<payload_size; i++)
	{
		payload[i] = 0xA0 + i%4;
	}
	payload[payload_size-1] += 0x50; //mark last byte with A+5 = F

	if(c->data_rate > 0) //only set a period > 0 for a data_rate > 0
	{
		double packet_rate = 128.0*((double) c->data_rate)/((double) c->packet_size); //packets/s
		period = (us_t) (num_packets*(1000000.0/packet_rate)); //usecs/buffer
	}

	//adjust period and number of packets sent per buffer if period is too long
	if(period > timeout)
	{
		printf("did the thing\n");
		unsigned int num_packets_new = (unsigned int) (((double) num_packets) * ((double) timeout) / ((double) period));
		period = (period*num_packets_new)/num_packets;
		num_packets = num_packets_new;
	}

	for(;;)
	{
		period_start = gettime();
		sem_wait(c->buffer_ready);
		time_taken = 0;
		*c->bytes_written = 0;

		//setup write pointers
		word_ptr = (unsigned int *) *(c->base_address);
		head_ptr = (struct noc_header *) (word_ptr + 1);
		ptr = ((unsigned char *) head_ptr) + 12;

		//fill buffer with packets
		for(i=0; i < num_packets; i++)
		{
			//write packet
			*head_ptr = header;
			memcpy(ptr, payload, payload_size);
			*c->bytes_written += aligned_size;

			//advance pointers
			ptr = ((unsigned char *) head_ptr) + aligned_size;
			head_ptr = (struct noc_header *) ptr;
			ptr += 12;
		}
		
		//write num_packets written
		*word_ptr = i;

		//calculate time taken so far
		time_taken = calc_timediff_us(period_start, gettime());

		//throttle to desired data rate, would like to use usleep/nanosleep but microblaze does not handle it well
		while(time_taken + surplus < period)
		{
			time_taken = calc_timediff_us(period_start, gettime());
		}

		//we took too long, so make up for it in the following iteration
		if(time_taken + surplus > period)
		{
			surplus += time_taken - period;
		} else {
			surplus = 0;
		}

		//signal main thread
		sem_post(c->packet_written);
	}

	return c;
}
