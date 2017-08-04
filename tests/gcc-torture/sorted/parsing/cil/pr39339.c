#include "cerberus.h"
/* Generated by CIL v. 1.7.3 */
/* print_CIL_Input is false */

struct D {
   unsigned int columns : 4 ;
   unsigned int fore : 12 ;
   unsigned int back : 6 ;
   unsigned int fragment : 1 ;
   unsigned int standout : 1 ;
   unsigned int underline : 1 ;
   unsigned int strikethrough : 1 ;
   unsigned int reverse : 1 ;
   unsigned int blink : 1 ;
   unsigned int half : 1 ;
   unsigned int bold : 1 ;
   unsigned int invisible : 1 ;
   unsigned int pad : 1 ;
};
struct C {
   unsigned int c ;
   struct D attr ;
};
struct A {
   struct C *data ;
   unsigned int len ;
};
struct B {
   struct A *cells ;
   unsigned char soft_wrapped : 1 ;
};
struct E {
   long row ;
   long col ;
   struct C defaults ;
};
/* compiler builtin: 
   void *__builtin_memset(void * , int  , int  ) ;  */
void ( __attribute__((__noinline__)) foo)(struct E *screen , unsigned int c , int columns , struct B *row ) 
{ 
  struct D attr ;
  long col ;
  int i ;

  {
  col = screen->col;
  attr = screen->defaults.attr;
  attr.columns = columns;
  ((row->cells)->data + col)->c = c;
  ((row->cells)->data + col)->attr = attr;
  col ++;
  attr.fragment = 1;
  i = 1;
  while (i < columns) {
    ((row->cells)->data + col)->c = c;
    ((row->cells)->data + col)->attr = attr;
    col ++;
    i ++;
  }
  return;
}
}
extern int ( /* missing proto */  __builtin_abort)() ;
extern int ( /* missing proto */  __builtin_memcmp)() ;
int main(void) 
{ 
  struct E e ;
  struct C c[4] ;
  struct A a ;
  struct B b ;
  struct D d ;
  int tmp ;
  int tmp___0 ;

  {
  e.row = 5;
  e.col = 0;
  e.defaults.c = 6;
  e.defaults.attr.columns = -1;
  e.defaults.attr.fore = -1;
  e.defaults.attr.back = -1;
  e.defaults.attr.fragment = 1;
  e.defaults.attr.standout = 0;
  e.defaults.attr.underline = 1;
  e.defaults.attr.strikethrough = 0;
  e.defaults.attr.reverse = 1;
  e.defaults.attr.blink = 0;
  e.defaults.attr.half = 1;
  e.defaults.attr.bold = 0;
  e.defaults.attr.invisible = 1;
  e.defaults.attr.pad = 0;
  a.data = c;
  a.len = 4;
  b.cells = & a;
  b.soft_wrapped = 1;
  __builtin_memset(& c, 0, sizeof(c));
  foo(& e, 65, 2, & b);
  d = e.defaults.attr;
  d.columns = 2;
  tmp = __builtin_memcmp(& d, & c[0].attr, sizeof(d));
  if (tmp) {
    __builtin_abort();
  }
  d.fragment = 1;
  tmp___0 = __builtin_memcmp(& d, & c[1].attr, sizeof(d));
  if (tmp___0) {
    __builtin_abort();
  }
  return (0);
}
}
