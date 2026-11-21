/*
 * ACEGEM - speed limit for fast machines (gem/speed.c)
 * GPL v2 or later.
 */
#ifndef SPEED_H
#define SPEED_H

void speed_set(int on);         /* stubs in front of the kernel's handlers */
int  speed_on(void);
void speed_frame(void);         /* every 50 Hz frame */

#endif
