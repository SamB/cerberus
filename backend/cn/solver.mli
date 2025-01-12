type solver
type model
type model_with_q = model * (Sym.t * LogicalSorts.t) option


val make : Memory.struct_decls -> solver

val push : solver -> unit
val pop : solver -> unit
val add : solver -> Global.t -> LogicalConstraints.t -> unit


val provable : 
  loc:Locations.t ->
  shortcut_false:bool -> 
  solver:solver -> 
  global:Global.t -> 
  trace_length:int ->
  assumptions:LogicalConstraints.t list -> 
  pointer_facts:IndexTerms.t list ->
  LogicalConstraints.t -> 
  [> `True | `False ]


val model : 
  unit -> 
  model_with_q



val eval : 
  Memory.struct_decls -> 
  model -> 
  IndexTerms.t -> 
  IndexTerms.t option
