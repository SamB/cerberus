#include "cerberus.h"
f (unsigned char x)
{
  return (0x50 | (x >> 4)) ^ 0xff;
}

int 
main (void)
{
  if (f (0) != 0xaf)
    abort ();
  exit (0);
}
