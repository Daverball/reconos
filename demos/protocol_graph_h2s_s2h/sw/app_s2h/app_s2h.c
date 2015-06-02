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

#define DEFAULT_BUFFER_SIZE 2048

#define DEFAULT_PACKET_SIZE 64

struct reconos_resource res[NUM_SLOTS][2];
struct reconos_hwt hwt[NUM_SLOTS];
struct mbox mb_in[NUM_SLOTS];
struct mbox mb_out[NUM_SLOTS];

unsigned char *shared_mem_h2s;
unsigned char *shared_mem_s2h;

unsigned int buffer_size = DEFAULT_BUFFER_SIZE;

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
	shared_mem_h2s = malloc(buffer_size); 
	memset(shared_mem_h2s, 0, buffer_size);
	shared_mem_s2h = malloc(buffer_size); 
	memset(shared_mem_s2h, 0, buffer_size);
	mbox_put(&mb_in[HWT_H2S], (unsigned int) shared_mem_h2s);
	mbox_put(&mb_in[HWT_S2H], (unsigned int) shared_mem_s2h);
	config_eth(0xabababab, 0xabababab, 3, TO_H2S); // SW
	config_eth(0xcdcdcdcd, 0xcdcdcdcd, 2, TO_FB1); // HW
	//mbox_put(&mb_in[HWT_ETH], TO_H2S );
}



// MAIN ////////////////////////////////////////////////////////////////////
int main(int argc, char *argv[])
{
	int i, msg_len, cnt=0, max_cnt=5;
	unsigned char * ptr;
	unsigned int * ptr_int;
	unsigned int packet_size = DEFAULT_PACKET_SIZE;
	unsigned int aligned_size;
	unsigned int num_packets;

	printf( "-------------------------------------------------------\n"
		    "APP DEMO\n"
		    "(" __FILE__ ")\n"
		    "Compiled on " __DATE__ ", " __TIME__ ".\n"
		    "-------------------------------------------------------\n\n" );
	if(argc > 1 && atoi(argv[1])>0 && atoi(argv[1])<65 )
	{
		buffer_size *= atoi(argv[1]);
	} else {
		printf("[app] Received no valid buffer size in KB for argument 1 using default.\n");
	}
	
	if(argc > 2 && atoi(argv[2])>63 && atoi(argv[2])<1501 )
	{
		packet_size = atoi(argv[2]);
	} else {
		printf("[app] Received no valid packet size for argument 2 using default.\n");
	}
	aligned_size = 4*((packet_size+3)/4); //round up to next word boundary
	assert((aligned_size & 3) == 0); // make sure size is aligned
	num_packets = (buffer_size-1500-4)/aligned_size + 1; // make this a bit more robust maybe, good estimate for now though
	
	printf("[app] Sending packets of size %d with a buffer of size %d with %d packets per buffer.\n", packet_size, buffer_size, num_packets);

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

	ptr = (unsigned char *) shared_mem_s2h;
	ptr_int = (unsigned int *) ptr;
	printf("[app] Sending packets...\n");

	// generate packet
	unsigned char * packet = malloc(packet_size);
	struct noc_header * noc_header = (struct noc_header *) packet;
	noc_header->hw_addr_switch = 1;
	noc_header->hw_addr_block = 0;
	noc_header->priority = 0;
	noc_header->direction = 0;
	noc_header->latency_critical = 0;
	noc_header->reserved = 0;
	noc_header->payload_len = packet_size-12;
	noc_header->src_idp = 3;
	noc_header->dst_idp = 2;

	// set packet payload, start at byte 12
	for(i=12;i<packet_size;i++)
	{
		packet[i] = (unsigned char) (i-11);
	}

	printf("\n\n");
	
	// copy packets into buffer
	for(i=0;i<num_packets;i++)
	{
		memcpy(ptr+4+i*aligned_size, packet, packet_size);
	}

	printf("\n\n[app] print buffer");
	*ptr_int = num_packets;
	for (i=0;i<((buffer_size)/4);i++)
	{
		if (i%4==0)
		{ 
			printf("\n\t");
		}
		printf("0x%08x  ",ptr_int[i]);
	}
	printf("\n");

	// flush cache
	reconos_cache_flush();

	// send packets
	while(cnt < max_cnt) 
	{
		// flush cache
		//reconos_cache_flush();

		// 1. send length
		mbox_put(&mb_in[HWT_S2H], (unsigned int) aligned_size*num_packets);

		// 2. wait for ack
		msg_len = mbox_get(&mb_out[HWT_S2H]);

		// 3. set next s2h shared mem addr
		mbox_put(&mb_in[HWT_S2H], (unsigned int) ptr);

		cnt++;
		printf("sent buffer no. %05d\n", cnt);

	}
	printf("\n");
	return 0;
}

