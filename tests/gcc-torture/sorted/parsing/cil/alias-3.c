#include "cerberus.h"
/* Generated by CIL v. 1.7.3 */
/* print_CIL_Input is false */

static int a  =    0;
extern int b  __attribute__((__alias__("a"))) ;
static int ( __attribute__((__noinline__)) inc)(void) 
{ 


  {
  b ++;
  return (0);
}
}
extern int ( /* missing proto */  __builtin_abort)() ;
int main(void) 
{ 


  {
  a = 0;
  inc();
  if (a != 1) {
    __builtin_abort();
  }
  return (0);
}
}
