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

// ReconOS
#include "reconos.h"
#include "mbox.h"

#include "timing.h"
#include "packetgen.h"


#define NUM_SLOTS 4

#define HWT_S2H 0
#define HWT_H2S 1
#define HWT_ETH 2
#define HWT_FB1 3

#define TO_H2S 5
#define TO_ETH 4
#define TO_FB1 1

#define DEFAULT_DATA_RATE -1
#define DEFAULT_PACKET_SIZE 64
#define DEFAULT_BUFFER_SIZE 64*1024

#define MAX_PACKET_SIZE 1500

struct reconos_resource res[NUM_SLOTS][2];
struct reconos_hwt hwt[NUM_SLOTS];
struct mbox mb_in[NUM_SLOTS];
struct mbox mb_out[NUM_SLOTS];

unsigned char *shared_mem_h2s;
unsigned char *shared_mem_s2h;

unsigned int buffer_size = DEFAULT_BUFFER_SIZE;
signed int data_rate = DEFAULT_DATA_RATE;

void config_eth(unsigned int hash_1, unsigned int hash_2, unsigned int idp, int addr)
{
	unsigned int config_eth_hash_1 = hash_1;
	unsigned int config_eth_hash_2 = hash_2;
	unsigned int config_eth_idp = idp;
	unsigned int config_eth_address = addr; //global 4 bits, local 2 bits 
	mbox_put(&mb_in[HWT_ETH], config_eth_hash_1 );
	mbox_put(&mb_in[HWT_ETH], config_eth_hash_2);
	mbox_put(&mb_in[HWT_ETH], config_eth_idp);
	mbox_put(&mb_in[HWT_ETH], config_eth_address);
	mbox_get(&mb_out[HWT_ETH]);
}

void setup_noc(void)
{
	shared_mem_h2s = malloc(buffer_size); 
	memset(shared_mem_h2s, 0, buffer_size);
	shared_mem_s2h = malloc(buffer_size); 
	memset(shared_mem_s2h, 0, buffer_size);
	mbox_put(&mb_in[HWT_H2S], (unsigned int) shared_mem_h2s);
	mbox_put(&mb_in[HWT_S2H], (unsigned int) shared_mem_s2h);
	config_eth(0xabababab, 0xabababab, 3, TO_H2S); // SW
	config_eth(0xcdcdcdcd, 0xcdcdcdcd, 2, TO_FB1); // HW
}

void print_buffer(void * buffer, size_t size) //for debugging
{
	assert(size % 4 == 0); // make sure we're working with a buffer of multiple word size
	unsigned int * ptr = (unsigned int *)buffer;
	int i;
	for(i=0; i<(size/4); i++)
	{
		if (i%8==0){ 
			printf("\n\t");
		}
		printf("0x%08x  ",*(ptr++));
	}
	printf("\n");
}

// setup synchronization variables
volatile void ** base_address;
sem_t packet_written;
sem_t buffer_ready;


// MAIN ////////////////////////////////////////////////////////////////////
int main(int argc, char *argv[])
{
	int i, msg_len, cnt=0, max_cnt=5;
	unsigned int * ptr;
	unsigned int packet_size = DEFAULT_PACKET_SIZE;
	unsigned int aligned_size;
	unsigned int bytes_written;
	unsigned int num_packets;
	pthread_t packetgen_thread;

	//performance timing variables
	us_t time_taken, latency_total=0, latency_avg, latency_max=0, latency_min=1000000;
	timing_t start;

	printf( "-------------------------------------------------------\n"
		    "APP DEMO\n"
		    "(" __FILE__ ")\n"
		    "Compiled on " __DATE__ ", " __TIME__ ".\n"
		    "-------------------------------------------------------\n\n" );
	if(argc > 1 && ( strcmp("--help", 	argv[1])==0 ||
					 strcmp("-h", 		argv[1])==0 ||
					 strcmp("help", 	argv[1])==0
				   )
	  )
	{
		printf("Usage: ./app_s2h [packet_size] [buffer_size] [data_rate]\n");
		printf("\tpacket_size:\tpacket size in Bytes\t(default value %d)\n", DEFAULT_PACKET_SIZE);
		printf("\tbuffer_size:\tbuffer size in KBytes\t(default value %d)\n", DEFAULT_BUFFER_SIZE/1024);
		printf("\tdata_rate:\tdata rate in KBit/s\t(default value: %d, unlimited)\n", DEFAULT_DATA_RATE);
		return 0;
	}
	
	if(argc > 1 && atoi(argv[1])>63 && atoi(argv[1])<1501 )
	{
		packet_size = atoi(argv[1]);
	} else {
		printf("[app] Received no valid packet size for argument 1 using default.\n");
	}

	aligned_size = 4*((packet_size+3)/4); //round up to next word boundary
	assert((aligned_size & 3) == 0); // make sure size is aligned

	if(argc > 2 && atoi(argv[2])>1 && atoi(argv[2])<65 )
	{
		buffer_size = 1024*atoi(argv[2]);
	} else {
		printf("[app] Received no valid buffer size in KBytes for argument 2 using default.\n");
	}

	if(argc > 3 && atoi(argv[3])>-2)
	{
		data_rate = atoi(argv[3]);
		printf("[app] Sending packets of size %d with a buffer of size %dKB at %.3f MBit/s.\n", packet_size, buffer_size/1024, ((float) data_rate)/1024.0f);
	} else {
		printf("[app] Received no valid data rate for argument 3 using unlimited mode.\n");
		printf("[app] Sending packets of size %d with a buffer of size %d at max throughput.\n", packet_size, buffer_size);
	}

	#ifdef USE_DCR_TIMEBASE
	init_timebase();
	#endif

	printf("[app] Initialize ReconOS.\n");
	reconos_init_autodetect();

	printf("[app] Creating delegate threads.\n\n");
	for (i=0; i<NUM_SLOTS; i++)
	{
		// mbox init
		mbox_init(&mb_in[i],  10);
		mbox_init(&mb_out[i], 10);
		// define resources
		res[i][0].type = RECONOS_TYPE_MBOX;
		res[i][0].ptr  = &mb_in[i];	  	
		res[i][1].type = RECONOS_TYPE_MBOX;
		res[i][1].ptr  = &mb_out[i];
		// start delegate threads
		reconos_hwt_setresources(&hwt[i],res[i],2);
		reconos_hwt_create(&hwt[i],i,NULL);
	}

	printf("[app] Setup NoC\n");
	setup_noc();

	printf("[app] Creating packet generation thread.\n\n");

	// allocate synchronization variables
	base_address = malloc(sizeof(void*));
	sem_init(&packet_written, 0, -1);
	sem_init(&buffer_ready, 0, -1);

	struct generate_packets_context packetgen_context = {packet_size, data_rate, base_address, &packet_written, &buffer_ready};
	pthread_create(&packetgen_thread, NULL, generate_packets, &packetgen_context);

	printf("[app] Sending packets...\n");

	// flush cache
	reconos_cache_flush();

	// send packets
	ptr = (unsigned int *) shared_mem_s2h; //location of num_packets in buffer
	while(cnt < max_cnt) 
	{
		start = gettime();

		bytes_written = 4;
		num_packets = 0;
		*base_address = ((char *) shared_mem_s2h) + 4;

		// as long as there is still space write packets to buffer
		while((bytes_written + MAX_PACKET_SIZE) < buffer_size)
		{
			//synchronize worker thread
			sem_post(&buffer_ready);

			//wait on worker thread to finish
			sem_wait(&packet_written);
			*base_address = ((char *) *base_address) + aligned_size;
			num_packets++;
			bytes_written += aligned_size;
		}
		*ptr = num_packets;

		// 1. send length
		mbox_put(&mb_in[HWT_S2H], (unsigned int) bytes_written);

		// 2. wait for ack
		msg_len = mbox_get(&mb_out[HWT_S2H]);

		// 3. set next s2h shared mem addr
		mbox_put(&mb_in[HWT_S2H], (unsigned int) ptr);

		cnt++;
		time_taken = calc_timediff_us(start, gettime());
		latency_total += time_taken;
		latency_max = max(latency_max, time_taken);
		latency_min = min(latency_min, time_taken);
		printf("Sent buffer no. %05d\n", cnt);

	}

	latency_avg = latency_total/cnt;
	double data_rate_achieved = ((double) (cnt*(bytes_written-4)))/((double) latency_total);
	data_rate_achieved *= 8.0/(1.024*1.024); //convert from bytes/us to MBit/s
	printf("\n\n[app] Performance results:\n\tData Rate: %.3f MBit/s\n\tLatency:\n\t\tavg: %dus \n\t\tmin: %dus \n\t\tmax: %dus", data_rate_achieved, (int) latency_avg, (int) latency_min, (int) latency_max);

	printf("\n\n[app] Print first KB of final buffer");
	print_buffer(shared_mem_s2h, 1024);

	#ifdef USE_DCR_TIMEBASE
	close_timebase();
	#endif

	return 0;
}
