#include "cerberus.h"

void
f (long long a)
{
  if ((a & 0xffffffffLL) != 0)
    abort ();
}

long long a = 0x1234567800000000LL;

int 
main (void)
{
  f (a);
  return 0;
}
