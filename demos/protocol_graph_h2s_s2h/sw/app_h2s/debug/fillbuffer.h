///
/// \file fillbuffer.h
/// Dummy header for debug build on a generic linux distro
/// \author     David Salvisberg   <davidsa@student.ethz.ch>
/// \date       05.05.2015

#ifndef __FILLBUFFER_H__
#define __FILLBUFFER_H__

#define NUM_PACKETS_IN_BUFFER 16

void fill_buffer(void * buffer, size_t size);

#endif 
