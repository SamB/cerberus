open Extra
open Panic
open Coq_ast
open Coq_pp

type typed_ail = GenTypes.genTypeCategory AilSyntax.ail_program
type ail_expr  = GenTypes.genTypeCategory AilSyntax.expression
type c_type    = Ctype.ctype
type i_type    = Ctype.integerType
type type_cat  = GenTypes.typeCategory
type loc       = Location_ocaml.t

let to_type_cat : GenTypes.genTypeCategory -> type_cat = fun tc ->
  let loc = Location_ocaml.unknown in
  let impl = Ocaml_implementation.hafniumIntImpl in
  let m_tc = GenTypesAux.interpret_genTypeCategory loc impl tc in
  match ErrorMonad.runErrorMonad m_tc with
  | Either.Right(tc) -> tc
  | Either.Left(_,_) -> assert false (* FIXME possible here? *)

let not_impl loc fmt = panic loc ("Not implemented: " ^^ fmt)

(* Short names for common functions. *)
let sym_to_str : Symbol.sym -> string =
  Pp_symbol.to_string_pretty

let id_to_str : Symbol.identifier -> string =
  fun Symbol.(Identifier(_,id)) -> id

(* Extract attributes with namespace ["rc"]. *)
let collect_rc_attrs : Annot.attributes -> Coq_ast.rc_attr list =
  let fn acc Annot.{attr_ns; attr_id; attr_args} =
    match Option.map id_to_str attr_ns with
    | Some("rc") -> let rc_attr_id = id_to_str attr_id in
                    {rc_attr_id; rc_attr_args = attr_args} :: acc
    | _          -> acc
  in
  fun (Annot.Attrs(attrs)) -> List.rev (List.fold_left fn [] attrs)

let translate_int_type : loc -> i_type -> Coq_ast.int_type = fun loc i ->
  let open Ctype in
  let open Ocaml_implementation in
  let size_of_base_type signed i =
    match i with
    (* Things defined in the standard libraries *)
    | IntN_t(_)                              -> not_impl loc "size_of_base_type (IntN_t)"
    | Int_leastN_t(_)                        -> not_impl loc "size_of_base_type (Int_leastN_t)"
    | Int_fastN_t(_)                         -> not_impl loc "size_of_base_type (Int_fastN_t)"
    | Intmax_t                               -> not_impl loc "size_of_base_type (Intmax_t)"
    | Intptr_t                               -> ItSize_t(signed)
    (* normal integer types *)
    | Ichar | Short | Int_ | Long | LongLong ->
       match HafniumImpl.sizeof_ity (if signed then Signed(i) else Unsigned i) with
       | Some 1 -> ItI8(signed)
       | Some 2 -> ItI16(signed)
       | Some 4 -> ItI32(signed)
       | Some 8 -> ItI64(signed)
       | Some p -> not_impl loc "unknown integer precision: %i" p
       | None -> assert false
  in
  match i with
  | Char        -> size_of_base_type (hafniumIntImpl.impl_signed Char)  Ichar
  | Bool        -> ItBool
  | Signed(i)   -> size_of_base_type true  i
  | Unsigned(i) -> size_of_base_type false i
  | Enum(_)     -> not_impl loc "layout_of (Enum)"
  (* Things defined in the standard libraries *)
  | Wchar_t     -> not_impl loc "layout_of (Wchar_t)"
  | Wint_t      -> not_impl loc "layout_of (Win_t)"
  | Size_t      -> ItSize_t(false)
  | Ptrdiff_t   -> not_impl loc "layout_of (Ptrdiff_t)"

(** [layout_of fa c_ty] translates the C type [c_ty] into a layout.  Note that
    argument [fa] must be set to [true] when in function arguments, since this
    requires a different tranlation for arrays (always pointers). *)
let layout_of : bool -> c_type -> Coq_ast.layout = fun fa c_ty ->
  let rec layout_of Ctype.(Ctype(annots, c_ty)) =
    let loc = Annot.get_loc_ annots in
    match c_ty with
    | Void                -> LVoid
    | Basic(Integer(i))   -> LInt (translate_int_type loc i)
    | Basic(Floating(_))  -> not_impl loc "layout_of (Basic float)"
    | Array(_,_) when fa  -> LPtr
    | Array(c_ty,None )   -> not_impl loc "layout_of (Array[])"
    | Array(c_ty,Some(n)) -> LArray(layout_of c_ty, Z.to_string n)
    | Function(_,_,_,_)   -> not_impl loc "layout_of (Function)"
    | Pointer(_,_)        -> LPtr
    | Atomic(_)           -> not_impl loc "layout_of (Atomic)"
    | Struct(sym)         -> LStruct(sym_to_str sym, false)
    | Union(syn)          -> LStruct(sym_to_str syn, true )
  in
  layout_of c_ty

(* Hashtable of local variables to distinguish global ones. *)
let local_vars = Hashtbl.create 17

let (fresh_ret_id, reset_ret_id) =
  let counter = ref (-1) in
  let fresh () = incr counter; Printf.sprintf "$%i" !counter in
  let reset () = counter := -1 in
  (fresh, reset)

let (fresh_block_id, reset_block_id) =
  let counter = ref (-1) in
  let fresh () = incr counter; Printf.sprintf "#%i" !counter in
  let reset () = counter := -1 in
  (fresh, reset)

let rec ident_of_expr (AilSyntax.AnnotatedExpression(_,_,_,e)) =
  let open AilSyntax in
  match e with
  | AilEident(sym)        -> Some(sym_to_str sym)
  | AilEfunction_decay(e) -> ident_of_expr e
  | _                     -> None

let layout_of_tc : GenTypes.typeCategory -> Coq_ast.layout = fun tc ->
  match tc with
  | GenTypes.LValueType(_,c_ty,_) -> layout_of false c_ty
  | GenTypes.RValueType(c_ty)     -> layout_of false c_ty

let translate_gen_type ty = layout_of_tc (to_type_cat ty)

let tc_of (AilSyntax.AnnotatedExpression(ty,_,_,_)) = to_type_cat ty

let is_const_0 (AilSyntax.AnnotatedExpression(_, _, _, e)) =
  let open AilSyntax in
  match e with
  | AilEconst(c) ->
      begin
        match c with
        | ConstantInteger(IConstant(i,_,_)) -> Z.equal Z.zero i
        | _                                 -> false
      end
  | _            -> false

let op_type_of loc Ctype.(Ctype(_, c_ty)) =
  match c_ty with
  | Void                -> not_impl loc "op_type_of (Void)"
  | Basic(Integer(i))   -> OpInt(translate_int_type loc i)
  | Basic(Floating(_))  -> not_impl loc "op_type_of (Basic float)"
  | Array(_,_)          -> not_impl loc "op_type_of (Array)"
  | Function(_,_,_,_)   -> not_impl loc "op_type_of (Function)"
  | Pointer(_,c_ty)     -> OpPtr(layout_of false c_ty)
  | Atomic(_)           -> not_impl loc "op_type_of (Atomic)"
  | Struct(_)           -> not_impl loc "op_type_of (Struct)"
  | Union(_)            -> not_impl loc "op_type_of (Union)"

let op_type_of_tc : GenTypes.typeCategory -> Coq_ast.op_type = fun tc ->
  match tc with
  | GenTypes.LValueType(_,c_ty,_) -> op_type_of Location_ocaml.unknown c_ty
  | GenTypes.RValueType(c_ty)     -> op_type_of Location_ocaml.unknown c_ty

(* We need similar function returning options for casts. *)
let op_type_opt loc Ctype.(Ctype(_, c_ty)) =
  match c_ty with
  | Void                -> None
  | Basic(Integer(i))   -> Some(OpInt(translate_int_type loc i))
  | Basic(Floating(_))  -> None
  | Array(_,_)          -> None
  | Function(_,_,_,_)   -> None
  | Pointer(_,c_ty)     -> Some(OpPtr(layout_of false c_ty))
  | Atomic(_)           -> None
  | Struct(_)           -> None
  | Union(_)            -> None

let op_type_tc_opt tc =
  match tc with
  | GenTypes.LValueType(_,c_ty,_) -> op_type_opt Location_ocaml.unknown c_ty
  | GenTypes.RValueType(c_ty)     -> op_type_opt Location_ocaml.unknown c_ty

let struct_data : ail_expr -> string * bool = fun e ->
  let AilSyntax.AnnotatedExpression(gtc,_,_,_) = e in
  let open GenTypes in
  match gtc with
  | GenRValueType(GenPointer(_,Ctype(_,Struct(s))))
  | GenLValueType(_,Ctype(_,Struct(s)),_)           -> (sym_to_str s, false)
  | GenRValueType(GenPointer(_,Ctype(_,Union(s) )))
  | GenLValueType(_,Ctype(_,Union(s) ),_)           ->(sym_to_str s, true )
  | GenRValueType(_                               ) -> assert false
  | GenLValueType(_,_                 ,_)           -> assert false

let strip_expr (AilSyntax.AnnotatedExpression(_,_,_,e)) = e

let rec will_decay : ail_expr -> bool = fun e ->
  let open AilSyntax in
  match strip_expr e with
  | AilEarray_decay(_) -> true
  | AilEbinary(e,_,_)  -> will_decay e
  | _                  -> false (* FIXME *)

let rec find_function_decl fname decls =
  let open AilSyntax in
  match decls with
  | []                         -> assert false
  | (id_decl, (_, d)) :: decls ->
  if sym_to_str id_decl <> fname then find_function_decl fname decls else
  match d with
  | Decl_function(_,(_, ty),args,_,_,_) -> (ty, args)
  | Decl_object(_,_,_)                  -> assert false

let global_decls = ref []

let rec translate_expr lval goal_ty e =
  let open AilSyntax in
  let res_ty = op_type_tc_opt (tc_of e) in
  let AnnotatedExpression(_, _, loc, e) = e in
  let translate = translate_expr lval None in
  let (e, l) as res =
    match e with
    | AilEunary(Address,e)         ->
        let (e, l) = translate_expr true None e in
        (AddrOf(e), l)
    | AilEunary(Indirection,e)     ->
        if will_decay e then translate e else
        let layout = layout_of_tc (tc_of e) in
        let (e, l) = translate e in
        (Deref(layout, e), l)
    | AilEunary(op,e)              ->
        let ty = op_type_of_tc (tc_of e) in
        let (e, l) = translate e in
        let op =
          match op with
          | Address     -> assert false (* Handled above. *)
          | Indirection -> assert false (* Handled above. *)
          | Plus        -> not_impl loc "unary operator (Plus)"
          | Minus       -> not_impl loc "unary operator (Minus)"
          | Bnot        -> not_impl loc "unary operator (Bnot)"
          | PostfixIncr -> not_impl loc "unary operator (PostfixIncr)"
          | PostfixDecr -> not_impl loc "unary operator (PostfixDecr)"
        in
        (UnOp(op, ty, e), l)
    | AilEbinary(e1,op,e2)         ->
        let ty1 = op_type_of_tc (tc_of e1) in
        let ty2 = op_type_of_tc (tc_of e2) in
        let op =
          match op with
          | Eq             -> EqOp
          | Ne             -> NeOp
          | Lt             -> LtOp
          | Gt             -> GtOp
          | Le             -> LeOp
          | Ge             -> GeOp
          | And            -> not_impl loc "nested && operator"
          | Or             -> not_impl loc "nested || operator"
          | Comma          -> not_impl loc "binary operator (Comma)"
          | Arithmetic(op) ->
          match op with
          | Mul  -> MulOp | Div  -> DivOp | Mod  -> ModOp | Add  -> AddOp
          | Sub  -> SubOp | Shl  -> ShlOp | Shr  -> ShrOp | Band -> AndOp
          | Bxor -> XorOp | Bor  -> OrOp
        in
        let (goal_ty, ty1, ty2) =
          match (ty1, ty2, res_ty) with
          | (OpInt(_), OpInt(_), Some((OpInt(_) as res_ty))) ->
              (Some(res_ty), res_ty, res_ty)
          | (_       , _       , _                         ) ->
              (None        , ty1   , ty2   )
        in
        let (e1, l1) = translate_expr lval goal_ty e1 in
        let (e2, l2) = translate_expr false goal_ty e2 in
        (BinOp(op, ty1, ty2, e1, e2), l1 @ l2)
    | AilEassign(e1,e2)            -> not_impl loc "nested assignment"
    | AilEcompoundAssign(e1,op,e2) -> not_impl loc "expr compound assign"
    | AilEcond(e1,e2,e3)           -> not_impl loc "expr cond"
    | AilEcast(q,c_ty,e)           ->
        begin
          match c_ty with
          | Ctype(_,Pointer(_,Ctype(_,Void))) when is_const_0 e ->
              (Val(Null), [])
          | _                                                   ->
          let ty = op_type_of_tc (tc_of e) in
          let op_ty = op_type_of Location_ocaml.unknown c_ty in
          let (e, l) = translate e in
          (UnOp(CastOp(op_ty), ty, e), l)
        end
    | AilEcall(e,es)               ->
        let fun_id =
          match ident_of_expr e with
          | None     -> not_impl loc "expr complicated call"
          | Some(id) -> id
        in
        let (_, args) = find_function_decl fun_id !global_decls in
        let (es, l) =
          let fn i e =
            let (_, ty, _) = List.nth args i in
            match op_type_opt Location_ocaml.unknown ty with
            | Some(OpInt(_)) as goal_ty -> translate_expr lval goal_ty e
            | _                         -> translate e
          in
          let es_ls = List.mapi fn es in
          (List.map fst es_ls, List.concat (List.map snd es_ls))
        in
        let ret_id = Some(fresh_ret_id ()) in
        let call = (ret_id, Var(Some(fun_id), true), es) in
        (Var(ret_id, false), l @ [call])
    | AilEassert(e)                -> not_impl loc "expr assert nested"
    | AilEoffsetof(c_ty,is)        -> not_impl loc "expr offsetof"
    | AilEgeneric(e,gas)           -> not_impl loc "expr generic"
    | AilEarray(b,c_ty,oes)        -> not_impl loc "expr array"
    | AilEstruct(sym,fs)           -> not_impl loc "expr struct"
    | AilEunion(sym,id,eo)         -> not_impl loc "expr union"
    | AilEcompound(q,c_ty,e)       -> not_impl loc "expr compound"
    | AilEmemberof(e,id)           ->
        if not lval then assert false;
        let (struct_name, from_union) = struct_data e in
        let (e, l) = translate e in
        (GetMember(e, struct_name, from_union, id_to_str id), l)
    | AilEmemberofptr(e,id)        ->
        let (struct_name, from_union) = struct_data e in
        let (e, l) = translate e in
        (GetMember(Deref(LPtr, e), struct_name, from_union, id_to_str id), l)
    | AilEbuiltin(b)               -> not_impl loc "expr builtin"
    | AilEstr(s)                   -> not_impl loc "expr str"
    | AilEconst(c)                 ->
        let c =
          match c with
          | ConstantIndeterminate(c_ty) -> assert false
          | ConstantNull                -> Null
          | ConstantInteger(i)          ->
              begin
                match i with
                | IConstant(i,_,_) ->
                    let it =
                      match res_ty with
                      | Some(OpInt(it)) -> it
                      | _               -> assert false
                    in
                    Int(Z.to_string i, it)
                | _                -> not_impl loc "weird integer constant"
              end
          | ConstantFloating(_)         -> not_impl loc "constant float"
          | ConstantCharacter(_)        -> not_impl loc "constant char"
          | ConstantArray(_,_)          -> not_impl loc "constant array"
          | ConstantStruct(_,_)         -> not_impl loc "constant struct"
          | ConstantUnion(_,_,_)        -> not_impl loc "constant union"
        in
        (Val(c), [])
    | AilEident(sym)               ->
        let id = sym_to_str sym in
        (Var(Some(id), not (Hashtbl.mem local_vars id)), [])
    | AilEsizeof(q,c_ty)           -> not_impl loc "expr sizeof"
    | AilEsizeof_expr(e)           -> not_impl loc "expr sizeof_expr"
    | AilEalignof(q,c_ty)          -> not_impl loc "expr alignof"
    | AilEannot(c_ty,e)            -> not_impl loc "expr annot"
    | AilEva_start(e,sym)          -> not_impl loc "expr va_start"
    | AilEva_arg(e,c_ty)           -> not_impl loc "expr va_arg"
    | AilEva_copy(e1,e2)           -> not_impl loc "expr va_copy"
    | AilEva_end(e)                -> not_impl loc "expr va_end"
    | AilEprint_type(e)            -> not_impl loc "expr print_type"
    | AilEbmc_assume(e)            -> not_impl loc "expr bmc_assume"
    | AilEreg_load(r)              -> not_impl loc "expr reg_load"
    | AilErvalue(e) when lval      -> translate e
    | AilErvalue(e)                ->
        let layout = layout_of_tc (tc_of e) in
        let (e, l) = translate_expr true None e in
        (Use(layout, e), l)
    | AilEarray_decay(e)           -> translate e (* FIXME ??? *)
    | AilEfunction_decay(e)        -> not_impl loc"expr function_decay"
  in
  match (goal_ty, res_ty) with
  | (None         , _           )
  | (_            , None        ) -> res
  | (Some(goal_ty), Some(res_ty)) ->
      if goal_ty = res_ty then res
      else (UnOp(CastOp(goal_ty), res_ty, e), l)

type bool_expr =
  | BE_leaf of ail_expr
  | BE_neg  of bool_expr
  | BE_and  of bool_expr * bool_expr
  | BE_or   of bool_expr * bool_expr

let rec bool_expr : ail_expr -> bool_expr = fun e ->
  match strip_expr e with
  | AilEbinary(e1,And,e2) -> BE_and(bool_expr e1, bool_expr e2)
  | AilEbinary(e1,Or ,e2) -> BE_or(bool_expr e1, bool_expr e2)
  | AilEbinary(e1,Eq ,e2) ->
      begin
        let be1 = bool_expr e1 in
        let be2 = bool_expr e2 in
        match (is_const_0 e1, be1, is_const_0 e2, be2) with
        | (false, _         , false, _         )
        | (true , _         , true , _         )
        | (false, BE_leaf(_), true , _         )
        | (true , _         , false, BE_leaf(_)) -> BE_leaf(e)
        | (false, _         , true , _         ) -> BE_neg(be1)
        | (true , _         , false, _         ) -> BE_neg(be2)
      end
  | _                     -> BE_leaf(e)

type op_ty_opt = Coq_ast.op_type option

let trans_expr : ail_expr -> op_ty_opt -> (expr -> stmt) -> stmt =
    fun e goal_ty e_stmt ->
  let (e, calls) = translate_expr false goal_ty e in
  let fn (id, e, es) stmt = Call(id, e, es, stmt) in
  List.fold_right fn calls (e_stmt e)

let trans_bool_expr : ail_expr -> (expr -> stmt) -> stmt = fun e e_stmt ->
  trans_expr e (Some(OpInt(ItBool))) e_stmt

let trans_lval e : expr =
  let (e, calls) = translate_expr true None e in
  if calls <> [] then assert false; e

(* Insert local variables. *)
let insert_bindings bindings =
  let fn (id, ((loc, _, _), _, c_ty)) =
    let id = sym_to_str id in
    if Hashtbl.mem local_vars id then
      not_impl loc "Variable name collision with [%s]." id;
    Hashtbl.add local_vars id c_ty;
    (id, layout_of false c_ty)
  in
  List.map fn bindings

let translate_block stmts blocks ret_ty =
  let rec trans break continue final stmts blocks =
    let open AilSyntax in
    let resume goto = match goto with None -> assert false | Some(s) -> s in
    (* End of the block reached. *)
    match stmts with
    | []                                           -> (resume final, blocks)
    | (AnnotatedStatement(loc, attrs, s)) :: stmts ->
    let attrs = collect_rc_attrs attrs in
    let attrs_used = ref false in
    let res =
      match s with
      (* Nested block. *)
      | AilSblock(bs, ss)   -> ignore (insert_bindings bs);
                               trans break continue final (ss @ stmts) blocks
      (* End of block stuff, assuming [stmts] is empty. *)
      | AilSgoto(l)         -> (Goto(sym_to_str l), blocks)
      | AilSreturnVoid      -> (Return(Val(Void)) , blocks)
      | AilSbreak           -> (resume break      , blocks)
      | AilScontinue        -> (resume continue   , blocks)
      | AilSreturn(e)       ->
          let goal_ty =
            match ret_ty with
            | Some(OpInt(_)) -> ret_ty
            | _              -> None
          in
          (trans_expr e goal_ty (fun e -> Return(e)), blocks)
      (* All the other constructors. *)
      | AilSskip            -> trans break continue final stmts blocks
      | AilSexpr(e)         ->
          let (stmt, blocks) = trans break continue final stmts blocks in
          let stmt =
            match strip_expr e with
            | AilEassert(e)     ->
                trans_bool_expr e (fun e -> Assert(e, stmt))
            | AilEassign(e1,e2) ->
                let e1 = trans_lval e1 in
                let layout = layout_of_tc (tc_of e) in
                let goal_ty =
                  let ty = op_type_of_tc (tc_of e) in
                  match ty with
                  | OpInt(_) -> Some(ty)
                  | _        -> None
                in
                trans_expr e2 goal_ty (fun e2 -> Assign(layout, e1, e2, stmt))
            | AilEcall(e,es)    ->
                let translate = translate_expr false None in
                let fun_id =
                  match ident_of_expr e with
                  | None     -> not_impl loc "expr complicated call"
                  | Some(id) -> id
                in
                let (es, l) =
                  let es_ls = List.map translate es in
                  (List.map fst es_ls, List.concat (List.map snd es_ls))
                in
                let stmt = Call(None, Var(Some(fun_id), true), es, stmt) in
                let fn (id, e, es) stmt = Call(id, e, es, stmt) in
                List.fold_right fn l stmt
            | _                 ->
                attrs_used := true;
                trans_expr e None (fun e -> ExprS(attrs, e, stmt))
          in
          (stmt, blocks)
      | AilSif(e,s1,s2)     ->
          let (final, blocks) =
            (* Last statement, keep the final goto. *)
            if stmts = [] then (final, blocks) else
            (* Statements after the if in their own block. *)
            let (stmt, blocks) = trans break continue final stmts blocks in
            let block_id = fresh_block_id () in
            (Some(Goto(block_id)), SMap.add block_id ([], stmt) blocks)
          in
          let (s1, blocks) = trans break continue final [s1] blocks in
          let (s2, blocks) = trans break continue final [s2] blocks in
          begin
            match bool_expr e with
            | BE_leaf(e) ->
                (trans_bool_expr e (fun e -> If(e, s1, s2)), blocks)
            | _          ->
                not_impl loc "conditional with || or &&" (* TODO *)
          end
      | AilSwhile(e,s)      ->
          let id_body = fresh_block_id () in
          let id_cont = fresh_block_id () in
          (* Translate the continuation. *)
          let blocks =
            let (stmt, blocks) = trans break continue final stmts blocks in
            SMap.add id_cont ([], stmt) blocks
          in
          (* Translate the body. *)
          let blocks =
            let break    = Some(Goto(id_cont)) in
            let continue = Some(Goto(id_body)) in
            let (stmt, blocks) = trans break continue continue [s] blocks in
            let e =
              match bool_expr e with
              | BE_leaf(e) -> e
              | _          -> not_impl loc "while with || or &&" (* TODO *)
            in
            let stmt =
              trans_bool_expr e (fun e -> If(e, stmt, Goto(id_cont)))
            in
            SMap.add id_body ([], stmt) blocks
          in
          (Goto(id_body), blocks)
      | AilSdo(s,e)         ->
          let id_body = fresh_block_id () in
          let id_cont = fresh_block_id () in
          (* Translate the continuation. *)
          let blocks =
            let (stmt, blocks) = trans break continue final stmts blocks in
            SMap.add id_cont ([], stmt) blocks
          in
          (* Translate the body. *)
          let blocks =
            let break    = Some(Goto(id_cont)) in
            let continue = Some(Goto(id_body)) in
            let stmt =
              let e =
                match bool_expr e with
                | BE_leaf(e) -> e
                | _          -> not_impl loc "do with || or &&" (* TODO *)
              in
              trans_bool_expr e (fun e -> If(e, Goto(id_body), Goto(id_cont)))
            in
            let (stmt, blocks) =
              trans break continue (Some stmt) [s] blocks
            in
            SMap.add id_body ([], stmt) blocks
          in
          (Goto(id_body), blocks)
      | AilSswitch(_,_)     -> not_impl loc "statement switch"
      | AilScase(_,_)       -> not_impl loc "statement case"
      | AilSdefault(_)      -> not_impl loc "statement default"
      | AilSlabel(l,s)      ->
          let (stmt, blocks) =
            trans break continue final (s :: stmts) blocks
          in
          (Goto(sym_to_str l), SMap.add (sym_to_str l) ([], stmt) blocks)
      | AilSdeclaration(ls) ->
          let (stmt, blocks) = trans break continue final stmts blocks in
          let add_decl (id, e) stmt =
            let id = sym_to_str id in
            let ty =
              try Hashtbl.find local_vars id with Not_found -> assert false
            in
            let layout = layout_of false ty in
            let goal_ty =
              let ty = op_type_of Location_ocaml.unknown ty in
              match ty with
              | OpInt(_) -> Some(ty)
              | _        -> None
            in
            let fn e = Assign(layout, Var(Some(id), false), e, stmt) in
            trans_expr e goal_ty fn
          in
          (List.fold_right add_decl ls stmt, blocks)
      | AilSpar(_)          -> not_impl loc "statement par"
      | AilSreg_store(_,_)  -> not_impl loc "statement store"
    in
    if not !attrs_used then
      begin
        let pp_rc oc {rc_attr_id = id; rc_attr_args = args} =
          Printf.fprintf oc "%s(" id;
          match args with
          | arg :: args -> Printf.fprintf oc "%s" arg;
                           List.iter (Printf.fprintf oc ", %s") args;
                           Printf.fprintf oc ")"
          | []          -> Printf.fprintf oc ")"
        in
        let fn = Printf.eprintf "Ignored attribute [%a]\n%!" pp_rc in
        List.iter fn attrs;
      end;
    res
  in
  trans None None (Some(Return(Val(Void)))) stmts blocks

(** [translate fname ail] translates typed Ail AST to Coq AST. *)
let translate : string -> typed_ail -> Coq_ast.t = fun source_file ail ->
  (* Get the entry point. *)
  let (entry_point, sigma) =
    match ail with
    | (None    , sigma) -> (None               , sigma)
    | (Some(id), sigma) -> (Some(sym_to_str id), sigma)
  in

  (* Extract the different parts of the AST. *)
  let decls      = sigma.declarations         in
  (*let obj_defs   = sigma.object_definitions   in*)
  let fun_defs   = sigma.function_definitions in
  (*let assertions = sigma.static_assertions    in*)
  let tag_defs   = sigma.tag_definitions      in
  (*let ext_idmap  = sigma.extern_idmap         in*)

  (* Give global access to declarations. *)
  global_decls := decls;

  (* Get the global variables. *)
  let global_vars =
    let fn (id, (_, decl)) acc =
      match decl with
      | AilSyntax.Decl_object _ -> sym_to_str id :: acc
      | _                       -> acc
    in
    List.fold_right fn decls []
  in

  (* Get the definition of structs/unions. *)
  let structs =
    let build (id, (attrs, def)) =
      let struct_attrs = collect_rc_attrs attrs in
      let struct_name = sym_to_str id in
      let (struct_members, struct_is_union) =
        let (l, is_union) =
          match def with
          | Ctype.UnionDef(l)  -> (l, true )
          | Ctype.StructDef(l) -> (l, false)
        in
        let fn (id, (attrs, _, c_ty)) =
          let attrs = collect_rc_attrs attrs in
          (id_to_str id, (attrs, layout_of false c_ty))
        in
        (List.map fn l, is_union)
      in
      let struct_deps =
        let fn acc (_, (_, layout)) =
          let rec extend acc layout =
            match layout with
            | LVoid         -> acc
            | LPtr          -> acc
            | LStruct(id,_) -> id :: acc
            | LInt(_)       -> acc
            | LArray(l,_)   -> extend acc l
          in
          extend acc layout
        in
        List.rev (List.fold_left fn [] struct_members)
      in
      let struct_ =
        { struct_name ; struct_attrs ; struct_deps
        ; struct_is_union ; struct_members }
      in
      (struct_name, struct_)
    in
    List.map build tag_defs
  in

  (* Get the definition of functions. *)
  let functions =
    let open AilSyntax in
    let build (id, (_, attrs, args, AnnotatedStatement(loc, s_attrs, stmt))) =
      Hashtbl.reset local_vars; reset_ret_id (); reset_block_id ();
      let func_name = sym_to_str id in
      let func_attrs = collect_rc_attrs attrs in
      let (ret_ty, args_decl) = find_function_decl func_name decls in
      let func_args =
        let fn i (_, c_ty, _) =
          let id = sym_to_str (List.nth args i) in
          Hashtbl.add local_vars id c_ty;
          (id, layout_of true c_ty)
        in
        List.mapi fn args_decl
      in
      let func_vars =
        match stmt with
        | AilSblock(bindings, _) -> insert_bindings bindings
        | _                      -> not_impl loc "Body not a block."
      in
      let func_init = fresh_block_id () in
      let func_blocks =
        let stmts =
          match stmt with
          | AilSblock(_, stmts) -> stmts
          | _                   -> not_impl loc "Body not a block."
        in
        let ret_ty = op_type_opt Location_ocaml.unknown ret_ty in
        let (stmt, blocks) = translate_block stmts SMap.empty ret_ty in
        SMap.add func_init (collect_rc_attrs s_attrs, stmt) blocks
      in
      let func =
        {func_name; func_attrs; func_args; func_vars; func_init; func_blocks}
      in
      (func_name, func)
    in
    List.map build fun_defs
  in

  { source_file ; entry_point ; global_vars ; structs ; functions }

(** [run fname ail] translates typed ail AST to Coq AST and then pretty prints
    the result on the standard output. *)
let run : string -> typed_ail -> unit = fun fname ail ->
  let coq = translate fname ail in
  Format.printf "%a@." Coq_pp.pp_ast coq
