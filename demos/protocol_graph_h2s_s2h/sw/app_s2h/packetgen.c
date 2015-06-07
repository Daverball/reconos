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

void *generate_packets(void * context)
{
	unsigned char * ptr;
	int i;
	struct noc_header * head_ptr;
	struct generate_packets_context * c = (struct generate_packets_context *) context;
	us_t period = 0;
	us_t time_taken = 0, surplus = 0;
	timing_t period_start;

	unsigned int payload_size = c->packet_size-12;
	struct noc_header header = {1, 0, 0, 0, 0, 0, payload_size, 3, 2};

	if(c->data_rate > 0) //only set a period > 0 for a data_rate > 0
	{
		double packet_rate = 128.0*((double) c->data_rate)/((double) c->packet_size); //packets/s
		period = (us_t) (1000000.0/packet_rate); //usecs/packet
	}
	for(;;)
	{
		period_start = gettime();
		sem_wait(c->buffer_ready);

		//setup write pointers
		head_ptr = (struct noc_header *) *(c->base_address);
		ptr = ((unsigned char *) head_ptr) + 12;

		//write packet
		*head_ptr = header;
		for(i=0; i<payload_size; i++)
		{
			ptr[i] = 0xA0 + i%4;
		}
		ptr[payload_size-1] += 0x50; //mark last byte with A+5 = F

		//take into account how much we missed the previous goal
		time_taken = calc_timediff_us(period_start, gettime()) + surplus;

		//sleep as many usecs as we need to throttle throughput to desired data rate
		if(time_taken < period)
		{
			usleep(period-time_taken);
			time_taken = calc_timediff_us(period_start, gettime());
		}

		//we took too long, so make up for it in the following iterations
		if(time_taken > period)
		{
			surplus = time_taken - period;
		}

		//signal main thread
		sem_post(c->packet_written);
	}

	return c;
}
