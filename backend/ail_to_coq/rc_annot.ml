open Earley_core
open Earley
open Extra

(** {3 Combinators and tokens} *)

(** [well_bracketed c_op c_cl] is a grammar that accepts strings starting with
    character [c_op], and ending with character [c_cl]. Moreover, strings with
    non-well-bracketed occurences of [c_op] and [c_cl] are rejected. The input
    ["(aa(b)(c))"] is hence accepted by [well_bracketed '(' ')'], and this has
    the effect of producing ["aa(b)(c)"] as semantic action. However, with the
    same parameters the input ["(aa(b)(c)"] would be rejected. *)
let well_bracketed : char -> char -> string Earley.grammar = fun c_op c_cl ->
  let fn buf pos =
    let str = Buffer.create 20 in
    let rec loop nb_op buf pos =
      let c = Input.get buf pos in
      if c = '\255' then
        Earley.give_up ()
      else if c = c_op then
        (Buffer.add_char str c; loop (nb_op + 1) buf (pos+1))
      else if c = c_cl then
        if nb_op = 1 then (buf, pos+1) else
        (Buffer.add_char str c; loop (nb_op - 1) buf (pos+1))
      else
        (Buffer.add_char str c; loop nb_op buf (pos+1))
    in
    let (buf, pos) = loop 1 buf (pos + 1) in
    (Buffer.contents str, buf, pos)
  in
  let name = Printf.sprintf "<%cwell-bracketed%c>" c_op c_cl in
  Earley.black_box fn (Charset.singleton c_op) false name

let list_sep : char -> 'a Earley.grammar -> 'a list Earley.grammar =
  fun c gr -> parser {e:gr es:{_:CHR(c) gr}* -> e::es}?[[]]

type ident     = string
type iris_term = string
type coq_term  = string
type layout    = coq_term

(** Identifier token (regexp ["[A-Za-z_]+"]). *)
let ident : ident Earley.grammar =
  let cs = Charset.from_string "A-Za-z_" in
  let fn buf pos =
    let nb = ref 1 in
    while Charset.mem cs (Input.get buf (pos + !nb)) do incr nb done;
    (String.sub (Input.line buf) pos !nb, buf, pos + !nb)
  in
  Earley.black_box fn cs false "<ident>"

(** Arbitrary ("well-bracketed") string delimited by ['['] and [']']. *)
let iris_term : iris_term Earley.grammar =
  well_bracketed '[' ']'

(** Arbitrary ("well-bracketed") string delimited by ['{'] and ['}']. *)
let coq_term : coq_term Earley.grammar =
  well_bracketed '{' '}'

  (** Synonym of [coq_term]. *)
let layout : layout Earley.grammar =
  coq_term

(** {3 Main grammars} *)

type ptr_kind = Own | Shr | Frac of coq_term

type constr =
  | Constr_Iris  of string
  | Constr_exist of string * constr
  | Constr_own   of string * type_expr
  | Constr_Coq   of string

and type_expr =
  | Ty_refine of coq_term * type_expr
  | Ty_ptr    of ptr_kind * type_expr
  | Ty_opt1   of type_expr
  | Ty_opt2   of type_expr * type_expr
  | Ty_uninit of layout
  | Ty_dots
  | Ty_exists of ident * type_expr
  | Ty_constr of type_expr * constr
  | Ty_params of ident * type_expr list
  | Ty_direct of ident

let type_void : type_expr = Ty_direct "void"

let parser constr =
  | s:iris_term                                   -> Constr_Iris(s)
  | "∃" x:ident "." c:constr                      -> Constr_exist(x,c)
  | x:ident "@" "&own<" ty:type_expr ">"          -> Constr_own(x,ty)
  | s:coq_term                                    -> Constr_Coq(s)

and parser type_expr =
  | s:coq_term "@" ty:type_expr                   -> Ty_refine(s, ty)
  | "&own<" ty:type_expr ">"                      -> Ty_ptr(Own, ty)
  | "&shr<" ty:type_expr ">"                      -> Ty_ptr(Shr, ty)
  | "&frac<" s:coq_term "," ty:type_expr ">"      -> Ty_ptr(Shr, ty)
  | "!uninit<" l:layout ">"                       -> Ty_uninit(l) 
  | "..."                                         -> Ty_dots
  | "∃" x:ident "." ty:type_expr                  -> Ty_exists(x,ty)
  | ty:type_expr "&" c:constr                     -> Ty_constr(ty,c)
  | id:ident "<" tys:(list_sep ',' type_expr) ">" -> Ty_params(id,tys)
  | x:ident                                       -> Ty_direct(x)

(** {3 Entry points} *)

(** {4 Annotations on type definitions} *)

let parser annot_parameter : (ident * coq_term) Earley.grammar =
  | id:ident ":" s:coq_term

let parser annot_refine : (ident * coq_term) Earley.grammar =
  | id:ident ":" s:coq_term

let parser annot_ptr_type : (ident * type_expr) Earley.grammar =
  | id:ident ":" ty:type_expr

let parser annot_type : ident Earley.grammar =
  | id:ident

(** {4 Annotations on structs} *)

let parser annot_size : ident Earley.grammar =
  | id:ident

let parser annot_exist : (ident * coq_term) Earley.grammar =
  | id:ident ":" s:coq_term

let parser annot_constr : constr Earley.grammar =
  | c:constr

(** {4 Annotations on fields} *)

let parser annot_field : type_expr Earley.grammar =
  | ty:type_expr

(** {4 Annotations on functions} *)

let parser annot_arg : type_expr Earley.grammar =
  | ty:type_expr

let parser annot_requires : constr Earley.grammar =
  | c:constr

let parser annot_returns : type_expr Earley.grammar =
  | ty:type_expr

let parser annot_ensures : constr Earley.grammar =
  | c:constr

(** {4 Annotations on statement expressions (ExprS)} *)

let parser annot_subtype : type_expr Earley.grammar =
  | ty:type_expr

(** {4 Annotations on blocks} *)

let parser annot_inv : constr Earley.grammar =
  | c:constr

(** {3 Parsing of attributes} *)

type annot =
  | Annot_parameters of (ident * coq_term) list
  | Annot_refined_by of (ident * coq_term) list
  | Annot_ptr_type   of (ident * type_expr)
  | Annot_type       of ident
  | Annot_size       of ident
  | Annot_exist      of (ident * coq_term) list
  | Annot_constraint of constr list
  | Annot_immovable
  | Annot_tunion
  | Annot_field      of type_expr
  | Annot_args       of type_expr list
  | Annot_requires   of constr list
  | Annot_returns    of type_expr
  | Annot_ensures    of constr list
  | Annot_subtype    of type_expr
  | Annot_unlock
  | Annot_inv        of constr

exception Invalid_annot of string

let parse_attr : Coq_ast.rc_attr -> annot = fun attr ->
  let {Coq_ast.rc_attr_id = id; Coq_ast.rc_attr_args = args} = attr in
  let error msg =
    raise (Invalid_annot (Printf.sprintf "annotation [%s] %s" id msg))
  in

  let parse : type a.a grammar -> string -> a = fun gr s ->
    let parse_string = Earley.parse_string gr Blanks.default in
    try parse_string s with Earley.Parse_error(_,i) ->
      let msg = Printf.sprintf  "Parse error in \"%s\" at position %i" s i in
      raise (Invalid_annot msg)
  in

  let single_arg : type a.a grammar -> (a -> annot) -> annot = fun gr c ->
    match args with
    | [s] -> c (parse gr s)
    | _   -> error "should have exactly one argument"
  in

  let many_args : type a.a grammar -> (a list -> annot) -> annot = fun gr c ->
    match args with
    | [] -> error "should have at least one argument"
    | _  -> c (List.map (parse gr) args)
  in

  let no_args : annot -> annot = fun c ->
    match args with
    | [] -> c
    | _  -> error "should not have arguments"
  in

  match id with
  | "parameters" -> many_args annot_parameter (fun l -> Annot_parameters(l))
  | "refined_by" -> many_args annot_refine (fun l -> Annot_refined_by(l))
  | "ptr_type"   -> single_arg annot_ptr_type (fun e -> Annot_ptr_type(e))
  | "type"       -> single_arg annot_type (fun e -> Annot_type(e))
  | "size"       -> single_arg annot_size (fun e -> Annot_size(e))
  | "exist"      -> many_args annot_exist (fun l -> Annot_exist(l))
  | "constraint" -> many_args annot_constr (fun l -> Annot_constraint(l))
  | "immovable"  -> no_args Annot_immovable
  | "tunion"     -> no_args Annot_tunion
  | "field"      -> single_arg annot_field (fun e -> Annot_field(e))
  | "args"       -> many_args annot_arg (fun l -> Annot_args(l))
  | "requires"   -> many_args annot_requires (fun l -> Annot_requires(l))
  | "returns"    -> single_arg annot_returns (fun e -> Annot_returns(e))
  | "ensures"    -> many_args annot_ensures (fun l -> Annot_ensures(l))
  | "subtype"    -> single_arg annot_subtype (fun e -> Annot_subtype(e))
  | "unlock"     -> no_args Annot_unlock
  | "inv"        -> single_arg annot_inv (fun e -> Annot_inv(e))
  | _            -> error "undefined"

(** {3 High level parsing of attributes} *)

type function_annot =
  { fa_parameters : (ident * coq_term) list
  ; fa_args       : type_expr list
  ; fa_returns    : type_expr
  ; fa_requires   : constr list
  ; fa_ensures    : constr list }

let function_annots : Coq_ast.rc_attr list -> function_annot = fun attrs ->
  let parameters = ref [] in
  let args = ref [] in
  let returns = ref None in
  let requires = ref [] in
  let ensures = ref [] in

  let handle_attr ({Coq_ast.rc_attr_id = id; _} as attr) =
    let error msg =
      raise (Invalid_annot (Printf.sprintf "annotation [%s] %s" id msg))
    in
    match (parse_attr attr, !returns) with
    | (Annot_parameters(l), _   ) -> parameters := !parameters @ l
    | (Annot_args(l)      , _   ) -> args := !args @ l
    | (Annot_returns(ty)  , None) -> returns := Some(ty)
    | (Annot_returns(ty)  , _   ) -> error "already specified"
    | (Annot_requires(l)  , _   ) -> requires := !requires @ l
    | (Annot_ensures(l)   , _   ) -> ensures := !ensures @ l
    | (_                  , _   ) -> error "is invalid for a function"
  in
  List.iter handle_attr attrs;

  { fa_parameters = !parameters
  ; fa_args       = !args
  ; fa_returns    = Option.get type_void !returns
  ; fa_requires   = !requires
  ; fa_ensures    = !ensures }

let field_annot : Coq_ast.rc_attr list -> type_expr = fun attrs ->
  let field = ref None in

  let handle_attr ({Coq_ast.rc_attr_id = id; _} as attr) =
    let error msg =
      raise (Invalid_annot (Printf.sprintf "annotation [%s] %s" id msg))
    in
    match (parse_attr attr, !field) with
    | (Annot_field(ty), None) -> field := Some(ty)
    | (Annot_field(ty), _   ) -> error "already specified"
    | (_              , _   ) -> error "is invalid for a field"
  in
  List.iter handle_attr attrs;

  match !field with
  | None     -> raise (Invalid_annot "a field annotation is required")
  | Some(ty) -> ty

