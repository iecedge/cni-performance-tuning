#!/bin/bash

set -o errexit
#set -o xtrace

#INTERFACE_NAME=enp12s0f1
#HARD_IRQ_FIRST_NUM=539
#HARD_IRQ_LAST_NUM=657

INTERFACE_NAME=${1:-enp5s0f1}
HARD_IRQ_FIRST_NUM=${2:-691}
HARD_IRQ_LAST_NUM=${3:-754}


for (( c=${HARD_IRQ_FIRST_NUM},i=0; c<=${HARD_IRQ_LAST_NUM}; c++,i++ ))
do
  block=`expr $i/32`
  left_shift=`expr $i%32`

   echo "block: $block left_shift: $left_shift "
   CPU_MASK=`printf "%x\n" $((1<<$left_shift))`
   for((j=0;j<block;j++))
   do
	   CPU_MASK="$CPU_MASK,0"
   done
   echo "CPU_MASK:$CPU_MASK"

   if [ -f /proc/irq/$c/smp_affinity ];then
	echo "ls /proc/irq/$c/smp_affinity"
	echo $CPU_MASK > /proc/irq/$c/smp_affinity
   fi

   if [ -f /sys/class/net/$INTERFACE_NAME/queues/rx-$i/rps_cpus ];then
	echo "ls /sys/class/net/$INTERFACE_NAME/queues/rx-$i/rps_cpus"	
	echo $CPU_MASK > /sys/class/net/$INTERFACE_NAME/queues/rx-$i/rps_cpus
   fi

done
