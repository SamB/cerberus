type t = LC of IndexTerms.t

let pp (LC c) = IndexTerms.pp c

let subst sym with_it (LC c) = 
  LC (IndexTerms.subst sym with_it c)

let syms_in (LC c) = IndexTerms.syms_in c
