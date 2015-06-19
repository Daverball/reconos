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

// ReconOS
#include "reconos.h"
#include "mbox.h"

#include "timing.h"

#define NUM_SLOTS 4

#define HWT_S2H 0
#define HWT_H2S 1
#define HWT_ETH 2
#define HWT_FB1 3

#define TO_H2S 5
#define TO_ETH 4
#define TO_FB1 1

#define DEFAULT_BUFFER_SIZE 64*1024
#define DEFAULT_TIMEOUT_MS 10
#define DEFAULT_PACKETS_TO_RECEIVE 16*1024

#define MAX_LINES_PER_PACKET 4

// Debug
#if DEBUG > 0
#include "fillbuffer.h"
#endif

struct reconos_resource res[NUM_SLOTS][2];
struct reconos_hwt hwt[NUM_SLOTS];
struct mbox mb_in[NUM_SLOTS];
struct mbox mb_out[NUM_SLOTS];

unsigned char *shared_mem_h2s;
unsigned char *shared_mem_s2h;

unsigned int buffer_size = DEFAULT_BUFFER_SIZE;
unsigned int timeout_ms = DEFAULT_TIMEOUT_MS;
unsigned int max_cnt = DEFAULT_PACKETS_TO_RECEIVE;


void config_eth(unsigned int hash_1, unsigned int hash_2, unsigned int idp, int addr)
{
	int ret = 0;
	unsigned int config_eth_hash_1 = hash_1;
	unsigned int config_eth_hash_2 = hash_2;
	unsigned int config_eth_idp = idp;
	unsigned int config_eth_address = addr; //global 4 bits, local 2 bits 
	mbox_put(&mb_in[HWT_ETH], config_eth_hash_1 );
	mbox_put(&mb_in[HWT_ETH], config_eth_hash_2);
	mbox_put(&mb_in[HWT_ETH], config_eth_idp);
	mbox_put(&mb_in[HWT_ETH], config_eth_address);
	ret = mbox_get(&mb_out[HWT_ETH]);
}

void setup_noc(void)
{
	shared_mem_h2s = malloc(max(buffer_size, 2048)); 
	memset(shared_mem_h2s, 0, max(buffer_size, 2048));
	shared_mem_s2h = malloc(max(buffer_size, 2048)); 
	memset(shared_mem_s2h, 0, max(buffer_size, 2048));
	mbox_put(&mb_in[HWT_H2S], buffer_size); //set buffer size at most the synthesised size
	mbox_put(&mb_in[HWT_H2S], timeout_ms); //set timeout in ms
	mbox_put(&mb_in[HWT_S2H], (unsigned int) shared_mem_s2h);
	config_eth(0xabababab, 0xabababab, 3, TO_H2S); // SW
	config_eth(0xcdcdcdcd, 0xcdcdcdcd, 2, TO_FB1); // HW
	#if DEBUG > 0
	fill_buffer(shared_mem_h2s, max(buffer_size, 2048));
	#endif
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

// MAIN ////////////////////////////////////////////////////////////////////
int main(int argc, char *argv[])
{
	int i, k, cnt=1, buf_cnt=1, packet_count;
	unsigned int * ptr = (unsigned int *) shared_mem_h2s;
	unsigned short msg_len;
	unsigned int checksum=0;
	unsigned int total_bytes_received=0;

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
		printf("Usage: ./app_h2s [buffer_size] [timeout] [num_packets]\n");
		printf("\tbuffer_size:\tbuffer size in KB (default value %d)\n", DEFAULT_BUFFER_SIZE/1024);
		printf("\t\t\t(note:) 1 turns on single packet buffering.\n\n");
		printf("\ttimeout:\ttimeout in ms (default value: %d)\n", DEFAULT_TIMEOUT_MS);
		printf("\tnum_packets:\thow many packets to receive (default value: %d)\n", DEFAULT_PACKETS_TO_RECEIVE);
		return 0;
	}
	
	if(argc > 1 && atoi(argv[1])>0)// 1KB -> single packet buffering
	{
		buffer_size = 1024*atoi(argv[1]);
	} else {
		printf("[app] Received no valid buffer size in KB for argument 1, using default.\n");
	}

	if(argc > 2 && atoi(argv[2])>0)
	{
		timeout_ms = atoi(argv[2]);
	} else {
		printf("[app] Timeout needs to be bigger than zero, using default.\n");
	}

	if(argc > 3 && atoi(argv[3])>0)
	{
		max_cnt = atoi(argv[3]);
	} else {
		printf("[app] Number of packets to receive needs to be bigger than zero, using default.\n");
	}
	
	printf("[app] Receving %d packets ", max_cnt);
	if(buffer_size >= 2048)
	{
		printf("with a buffer of size %dKB ", buffer_size/1024); 
	}
	else //single packet buffering
	{
		printf("with single packet buffering "); 
	}
	printf("and a timeout of %dms.\n", timeout_ms);

	printf("[app] Initialize ReconOS.\n");
	reconos_init_autodetect();

	printf("[app] Creating delegate threads.\n\n");
	for (i=0; i<NUM_SLOTS; i++){
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

	printf("[app] Waiting for packets...\n");
	#ifdef USE_DCR_TIMEBASE
	init_timebase();
	#endif
	// receive packets
	while(1) {
		start = gettime();
		// send ack to h2s
		mbox_put(&mb_in[HWT_H2S],(unsigned int) shared_mem_h2s);
		
		// receive message from h2s
		packet_count = mbox_get(&mb_out[HWT_H2S]);
		
		//printf("\n\n[app] Buffer no. %03d with %d packets.\n",buf_cnt, packet_count);

		// flush cache
		reconos_cache_flush();
		k=0;

		ptr = (unsigned int *) shared_mem_h2s;
		while(k < packet_count && cnt <= max_cnt){
			msg_len = *(((unsigned short *) ptr) + 1); //get msg_len out of packet header
			msg_len += 12; //expand message length by length of header
			total_bytes_received += msg_len;

			//printf("\n\n[app] Packet no. %04d of size %d bytes\n",cnt,msg_len);

			// compute checksum
			for (i=0;i<(msg_len/4);i++){
				checksum += *(ptr++);
			}
			switch(msg_len%4) //add final non word bytes to checksum
			{
			  case 1: checksum += *(ptr++) & 0xFF000000; break;
			  case 2: checksum += *(ptr++) & 0xFFFF0000; break;
			  case 3: checksum += *(ptr++) & 0xFFFFFF00; break;
			  default: break;
			}
			//printf("Checksum = 0x%08x\n",checksum);
			cnt++;
			k++;
		}
		time_taken = calc_timediff_us(start, gettime());
		latency_total += time_taken;
		latency_max = max(latency_max, time_taken);
		latency_min = min(latency_min, time_taken);

		// stop after max_cnt packets
		if(cnt >= max_cnt)
			break;
		buf_cnt++;
	}
	latency_avg = latency_total / buf_cnt;
	double data_rate_achieved = ((double) (total_bytes_received))/((double) latency_total);
	data_rate_achieved *= 1000.0*8.0/(1.024); //convert from bytes/us to KBit/s
	printf("\n\n[app] Performance results:\n\tData Rate: %.1f KBit/s\n\tLatency:\n\t\tavg: %dus \n\t\tmin: %dus \n\t\tmax: %dus", data_rate_achieved, (int) latency_avg, (int) latency_min, (int) latency_max);

	printf("\n\n[app] Print first KB of final buffer");
	print_buffer(shared_mem_h2s, 1024);
	
	#ifdef USE_DCR_TIMEBASE
	close_timebase();
	#endif
	return 0;
}

