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

#define BUFFER_SIZE 4*2048

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
	shared_mem_h2s = malloc(BUFFER_SIZE); 
	memset(shared_mem_h2s, 0, BUFFER_SIZE);
	shared_mem_s2h = malloc(BUFFER_SIZE); 
	memset(shared_mem_s2h, 0, BUFFER_SIZE);
	mbox_put(&mb_in[HWT_H2S], (unsigned int) shared_mem_h2s);
	mbox_put(&mb_in[HWT_S2H], (unsigned int) shared_mem_s2h);
	config_eth(0xabababab, 0xabababab, 3, TO_H2S); // SW
	config_eth(0xcdcdcdcd, 0xcdcdcdcd, 2, TO_FB1); // HW
	//mbox_put(&mb_in[HWT_ETH], TO_H2S );
	#if DEBUG > 0
	fill_buffer(shared_mem_h2s, BUFFER_SIZE);
	#endif
}



// MAIN ////////////////////////////////////////////////////////////////////
int main(int argc, char *argv[])
{
	int i, k, cnt=1, buf_cnt=1, packet_count;
	int max_cnt = 2; //print up to max_cnt filled buffers
	unsigned int * ptr = (unsigned int *) shared_mem_h2s;
	unsigned short msg_len;

	printf( "-------------------------------------------------------\n"
		    "APP DEMO\n"
		    "(" __FILE__ ")\n"
		    "Compiled on " __DATE__ ", " __TIME__ ".\n"
		    "-------------------------------------------------------\n\n" );

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

	// receive packets
	while(1) {
		// receive message from h2s
		packet_count = mbox_get(&mb_out[HWT_H2S]);

		// flush cache
		reconos_cache_flush();
		k=0;

		ptr = (unsigned int *) shared_mem_h2s;
		while(k < packet_count){
			printf("\n\n[app] Packet no. %04d\n",cnt);
			
			msg_len = *(((unsigned short *) ptr) + 1); //get msg_len out of packet header

			// print packet
			for (i=0;i<((msg_len+3)/4);i++){
				printf("0x%08x  ",*(ptr++));
				if ((i+1)%4==0){ 
					printf("\n");
				}
			}
			cnt++;
			k++;
		} 

		// send ack to h2s
		mbox_put(&mb_in[HWT_H2S],(unsigned int) shared_mem_h2s);

		// stop after max_cnt packets
		if(buf_cnt == max_cnt)
			break;
		buf_cnt++;
	}
	printf("\n");
	return 0;
}

