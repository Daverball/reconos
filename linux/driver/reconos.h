/*
 *                                                        ____  _____
 *                            ________  _________  ____  / __ \/ ___/
 *                           / ___/ _ \/ ___/ __ \/ __ \/ / / /\__ \
 *                          / /  /  __/ /__/ /_/ / / / / /_/ /___/ /
 *                         /_/   \___/\___/\____/_/ /_/\____//____/
 *
 * ======================================================================
 *
 *   title:        Linux Driver - ReconOS
 *
 *   project:      ReconOS
 *   author:       Christoph Rüthing, University of Paderborn
 *   description:  Driver for the ReconOS system. It includes the drivers
 *                 for the OSIFs (AXI FIFO), the interrupt controller and
 *                 the proc control.
 *
 * ======================================================================
 */

#ifndef RECONOS_DRV_H
#define RECONOS_DRV_H

//#define __printk(...) printk(__VA_ARGS__)
#define __printk(...) 

#include "include/reconos.h"

#include <linux/module.h>

// global variables available in the entire module
extern int NUM_HWTS;

#endif /* RECONOS_DRV_H */
