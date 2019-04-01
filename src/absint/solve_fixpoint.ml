open Cfg
open Core

open Apron

module N = Nat_big_num

module type STATE_MONAD =
sig
  type state
  type 'a t
  val return: 'a -> 'a t
  val bind: 'a t -> ('a -> 'b t) -> 'b t
  val (>>=): 'a t -> ('a -> 'b t) -> 'b t
  val run: 'a t -> state -> 'a * state
  val mapM: ('a -> 'b t) -> 'a list -> ('b list) t
  val get: state t
  val put: state -> unit t
  val update: (state -> state) -> unit t
  val modify: (state -> 'a * state) -> 'a t
end

module MakeStateMonad(S: sig type t end): STATE_MONAD with type state = S.t =
struct
  type state = S.t
  type 'a t = state -> 'a * state
  let return x = fun s -> (x, s)
  let bind m f = fun s ->
    let (x, s') = m s in f x s'
  let (>>=) = bind
  let run m = m
  let sequence ms =
    let m =
      List.fold_left (fun acc m ->
          m   >>= fun x ->
          acc >>= fun xs ->
          return (x::xs)
        ) (return []) ms
    in fun s ->
      let (xs, s') = m s in
      (List.rev xs, s')
  let mapM f xs = sequence (List.map f xs)
  let get = fun s -> (s, s)
  let put s = fun _ -> ((), s)
  let update f = fun s -> ((), f s)
  let modify f = fun s -> f s
end

(* TODO: delete this later *)
type info =
  { mutable counter: int;
  }

let empty_env = Environment.make [||] [||]

type absvalue =
  | ATunit
  | ATtrue
  | ATfalse
  | ATctype of Core_ctype.ctype0 (* C type as value *)
  | ATtuple of absvalue list
  | ATexpr of Texpr1.t
  | ATpointer of int (* TODO: naive pointer at the moment *)
  | ATsym of Symbol.sym
  | ATunspec
  | ATtop

type absstate =
  { abs_scalar: Box.t Abstract1.t; (* integers and floats *)
    abs_term: absvalue SMap.t;
    mem_counter: int;
    man: Box.t Manager.t;
  }

module StateMonad = MakeStateMonad(struct type t = absstate option end)
open StateMonad

let get_env = get >>= function
  | None -> assert false
  | Some s -> return @@ Abstract1.env s.abs_scalar

let add_env man sym e = update @@ function
  | None -> None
  | Some s ->
    let var = Var.of_string (Sym.show sym) in
    let env0 = Abstract1.env s.abs_scalar in
    let env =
      if Environment.mem_var env0 var then env0
      else Environment.add env0 [| var |] [||]
    in
    let abs_scalar =
      Abstract1.assign_texpr man
        (Abstract1.change_environment man s.abs_scalar env true)
        var e None
    in Some { s with abs_scalar }

let add_env_pointed man n e = update @@ function
  | None -> None
  | Some s ->
    let var = Var.of_string ("@" ^ string_of_int n) in
    let env0 = Abstract1.env s.abs_scalar in
    let env =
      if Environment.mem_var env0 var then env0
      else Environment.add env0 [| var |] [||]
    in
    let abs_scalar =
      Abstract1.assign_texpr man
        (Abstract1.change_environment man s.abs_scalar env true)
        var e None
    in Some { s with abs_scalar }


let show_abs_scalar st =
  Abstract1.print Format.str_formatter st;
  Format.flush_str_formatter ()

let show_absstate = function
  | None -> "top"
  | Some s ->
    (* TODO/NOTE: ignoring non scalar terms *)
    show_abs_scalar s.abs_scalar
    (*
    SMap.fold (fun k v acc -> 
        acc ^ Sym.show k ^ "; \n")
      s.abs_term
      (show_abs_scalar s.abs_scalar)
       *)

(* Lift states to a common environment *)
let lift_common_env man (s1, s2) =
  let env1 = Abstract1.env s1.abs_scalar in
  let env2 = Abstract1.env s2.abs_scalar in
  match Environment.compare env1 env2 with
  | -2 -> (* incomparable environments *)
    assert false
  | -1 ->
    let abs_scalar = Abstract1.change_environment man s1.abs_scalar env2 true
    in ({ s1 with abs_scalar }, s2)
  | 0 -> (* equal *)
    (s1, s2)
  | 1 ->
    let abs_scalar = Abstract1.change_environment man s2.abs_scalar env1 true
    in (s1, { s2 with abs_scalar })
  | _ ->
    assert false

let is_leq man s1 s2 =
  match s1, s2 with
  | _, None -> true
  | None, _ -> false
  | Some s1, Some s2 ->
    (* TODO/NOTE: this is wrong, it ignores non scalar terms *)
    let (s1, s2) = lift_common_env man (s1, s2) in
    Abstract1.is_leq man s1.abs_scalar s2.abs_scalar

let join man s1 s2 =
  match s1, s2 with
  | _, None | None, _ -> None
  | Some s1, Some s2 ->
    (* TODO/NOTE: this is wrong, it ignores non scalar terms *)
    let (s1, s2) = lift_common_env man (s1, s2) in
    Some { abs_scalar = Abstract1.join man s1.abs_scalar s2.abs_scalar;
           abs_term =
             SMap.union (fun k v _ -> Some v) (* TODO *)
               s1.abs_term s2.abs_term;
           mem_counter = max s1.mem_counter s2.mem_counter;
           man = s1.man;
      }

let bot man =
  Some { abs_scalar = Abstract1.bottom man empty_env;
         abs_term = SMap.empty;
         mem_counter = 0;
         man;
       }

let top =
  None

let init_state man =
  Some { abs_scalar = Abstract1.top man empty_env;
         abs_term = SMap.empty;
         mem_counter = 0;
         man;
       }

let is_bottom man = function
  | Some s -> Abstract1.is_bottom man s.abs_scalar
  | None -> false


let rec absvalue_of_texpr = function
  | TEsym x ->
    get >>= (function
        | None -> assert false
        | Some s ->
          if SMap.is_empty s.abs_term then print_endline "is_empty";
          begin match SMap.find_opt x s.abs_term with
            | Some _ ->
              return @@ ATsym x
            | None ->
              let env = Abstract1.env s.abs_scalar in
              let var = Var.of_string (Sym.show x) in
              return @@ ATexpr (Texpr1.var env var)
          end)
  | TEval v ->
    get_env >>= fun env ->
    begin match v with
      | Vobject (OVinteger i)
      | Vloaded (LVspecified (OVinteger i)) ->
        let n = Ocaml_mem.case_integer_value i
          (fun n -> Coeff.s_of_int (N.to_int n))
          (fun _ -> assert false)
        in
        return @@ ATexpr (Texpr1.cst env n)
      | Vunit ->
        return @@ ATunit
      | _ ->
        assert false
    end
  | TEcall (Sym (Symbol.Symbol (_, _, Some "catch_exceptional_condition")), [_; te])
  | TEcall (Sym (Symbol.Symbol (_, _, Some "conv_int")), [_; te])
  | TEcall (Sym (Symbol.Symbol (_, _, Some "conv_loaded_int")), [_; te])
    ->
    absvalue_of_texpr te
  | TEcall (Sym sym, _) ->
    print_endline @@ Sym.show sym;
    assert false
  | TEcall _ ->
    assert false
  | TEundef _ ->
    assert false
  | TEctor (ctor, tes) ->
    begin match ctor, tes with
      | Ctuple, _ ->
        mapM absvalue_of_texpr tes >>= fun tes' ->
        return @@ ATtuple tes'
      | Cspecified, [te] ->
        absvalue_of_texpr te
      | _ ->
        assert false
    end
  | TEop (bop, te1, te2) ->
    absvalue_of_texpr te1 >>= fun t1 ->
    absvalue_of_texpr te2 >>= fun t2 ->
    begin match t1, t2 with
    | ATexpr e1, ATexpr e2 ->
      let bop = match bop with
        | OpAdd -> Texpr1.Add
        | OpSub -> Texpr1.Sub
        | OpMul -> Texpr1.Mul
        | OpDiv -> Texpr1.Div
        | OpRem_t -> Texpr1.Mod
        | OpRem_f -> Texpr1.Mod (* TODO *)
        | _ -> assert false
      in
      return @@ ATexpr (Texpr1.binop bop e1 e2 Texpr1.Int Texpr1.Rnd)
    end
  | TEaction act ->
    absvalue_of_action act
  | _ ->
    assert false

and absvalue_of_action = function
  | TAcreate ->
    modify (function
        | None ->
          (ATpointer 0, None)
        | Some s ->
          (ATpointer s.mem_counter,
           Some { s with mem_counter = s.mem_counter + 1 })
      )
  | TAalloc ->
    assert false
  | TAstore (te_p, te_v) ->
    absvalue_of_texpr te_p >>= fun av_p ->
    absvalue_of_texpr te_v >>= fun av_v ->
    begin match av_p with
      | ATsym sym ->
        let rec aux sym =
          get >>= function
          | None -> assert false
          | Some s ->
            match SMap.find_opt sym s.abs_term with
            | None -> assert false
            | Some (ATpointer p) ->
              begin match av_v with
                | ATexpr e ->
                  add_env_pointed s.man p e >>= fun () ->
                  return @@ ATunit
                | _ ->
                  assert false
              end
            | Some (ATsym sym) ->
              aux sym
            | _ -> assert false
        in aux sym
      | ATpointer p ->
        assert false
      | _ ->
        assert false
    end
  | TAload te_p ->
    absvalue_of_texpr te_p >>= fun av_p ->
    get >>= begin function
      | None -> assert false
      | Some s ->
        match av_p with
        | ATsym sym ->
          let rec aux sym =
            match SMap.find_opt sym s.abs_term with
            | None -> assert false
            | Some (ATpointer p) ->
              let env = Abstract1.env s.abs_scalar in
              let var = Var.of_string ("@" ^ string_of_int p) in
              return @@ ATexpr (Texpr1.var env var)
            | Some (ATsym sym) ->
              aux sym
            | _ -> assert false
          in aux sym
        | ATpointer p ->
          let env = Abstract1.env s.abs_scalar in
          let var = Var.of_string ("@" ^ string_of_int p) in
          return @@ ATexpr (Texpr1.var env var)
        | _ ->
          assert false
    end
  | TAkill p ->
    (* TODO *)
    return ATunit

let rec match_pattern pat te =
  match pat, te with
  | Pattern (_, CaseBase (None, _)), _
  | Pattern (_, CaseBase (Some _, _)), _ ->
    true
  | Pattern (_, CaseCtor (Cspecified, [pat])), te ->
    match_pattern pat te
  | Pattern (_, CaseCtor (Ctuple, pats)), TEctor (Ctuple, tes) ->
    if List.length pats = List.length tes then
      List.for_all (fun (pat, te) -> match_pattern pat te)
        @@ List.combine pats tes
    else
      false
  | _ -> false

let assign man pat te =
  let rec aux v = function
    | Pattern (_, CaseBase (None, _)) ->
      return ()
    | Pattern (_, CaseBase (Some sym, _)) ->
      begin match v with
        | ATexpr e -> add_env man sym e
        | _ ->
          print_endline @@ "adding term: " ^ Sym.show sym;
          update (function
            | None -> None
            | Some s ->
              print_endline "ok";
              Some { s with abs_term = SMap.add sym v s.abs_term }
          )
      end
    | Pattern (_, CaseCtor (Cspecified, [pat])) ->
      aux v pat
    | Pattern (_, CaseCtor (Ctuple, pats)) ->
      begin match v with
        | ATtuple es ->
          List.fold_left (fun acc (e, pat) ->
              acc >>= fun () ->
              aux e pat
            ) (return ()) (List.combine es pats) >>= fun _ ->
          return ()
        | _ ->
          assert false
      end
    | _ -> assert false
  in match te with
  | TEundef _ -> update (fun _ -> top)
  | _ ->
    absvalue_of_texpr te >>= fun v ->
    aux v pat

let apply man psh he st_arr =
  let tr = PSHGraph.attrhedge psh he in
  let st_opt = st_arr.(0) in
  print_endline @@ Cfg.show_transfer tr;
  print_endline @@ show_absstate st_opt;
  match tr with
  | Tskip -> st_opt
  | Tcond c ->
    let rec aux = function
      | Cmatch (pat, te) -> match_pattern pat te
      | Cnot c -> not @@ aux c
      | _ ->
        print_endline "TODO: cond";
        assert false
    in
    if aux c then st_opt else bot man
  | Tcall _ ->
    print_endline "TODO: call";
    st_opt
  | Tassign (pat, te) ->
    let s = snd @@ run (assign man pat te) st_opt in
    begin match s with
      | None -> assert false
      | Some s ->
        (if SMap.is_empty s.abs_term then print_endline "empty" else
           print_endline "non_empty"); Some s
    end

let make_fpmanager man psh =
  let open Fixpoint in
  { bottom = (fun vtx -> bot man);
    canonical = (fun vtx abs -> ());
    is_bottom = (fun vtx -> is_bottom man);
    is_leq = (fun vtx -> is_leq man);
    join = (fun vst -> join man);
    join_list = (fun vtx abs_s -> List.fold_left (join man) (bot man) abs_s);
    widening = (fun vtx abs1 abs2 -> assert false);
    odiff = None;
    abstract_init = (fun vtx -> init_state man);
    arc_init = (fun edge -> ());
    apply = (fun he st_arr -> ((), apply man psh he st_arr));
    print_vertex = (fun _ _ -> ());
    print_hedge = (fun _ _ -> ());
    print_abstract = (fun _ _ -> ());
    print_arc = (fun _ _ -> ());
    accumulate = false;
    print_fmt = Format.err_formatter;
    print_analysis = false;
    print_component = false;
    print_step = false;
    print_state = false;
    print_postpre = false;
    print_workingsets = false;
    dot_fmt = None;
    dot_vertex = (fun _ _ -> ());
    dot_hedge = (fun _ _ -> ());
    dot_attrvertex = (fun _ _ -> ());
    dot_attrhedge = (fun _ _ -> ());
  }

(* TODO: this should be gone when I eliminate PSH stuff *)

let add_vertex (graph) (torg) (transfer) (dest) : unit =
  Array.iter
    (begin fun var ->
      if not (PSHGraph.is_vertex graph var) then PSHGraph.add_vertex graph var ()
    end)
    torg;
  if not (PSHGraph.is_vertex graph dest) then PSHGraph.add_vertex graph dest ();
  let info = PSHGraph.info graph in
  PSHGraph.add_hedge graph info.counter transfer ~pred:torg ~succ:[|dest|];
  info.counter <- info.counter + 1

let gcompare = {
  PSHGraph.hashv = {
    Hashhe.hash = (fun x -> abs x);
    Hashhe.equal = (=);
  };
  PSHGraph.hashh = {
    Hashhe.hash = (fun x -> abs x);
    Hashhe.equal = (==)
  };
  PSHGraph.comparev = Cfg.Graph.compare_vertex;
  PSHGraph.compareh = compare
}

let convert_graph g =
  let psh = PSHGraph.create gcompare 20 { counter = 0 } in
  Cfg.Graph.iter_edges g (fun v1 v2 d ->
      add_vertex psh [|v1|] d v2
    );
  let open Format in
  PSHGraph.print_dot
    (fun fmt v -> pp_print_text fmt @@ Cfg.Graph.string_of_vertex v)
    (fun fmt e -> pp_print_text fmt @@ string_of_int e)
    (fun fmt v _ -> pp_print_text fmt @@ Cfg.Graph.string_of_vertex v)
    (fun fmt _ tf -> pp_print_text fmt @@ Cfg.show_transfer tf)
    (Format.formatter_of_out_channel (open_out "c.dot"))
    psh;
  psh

let solve core =
  try (
  (* TODO: we fix box (intervals) at the moment *)
  let man = Box.manager_alloc () in
  let cfg = Cfg.mk_main ~sequentialise:true core in
  let psh = convert_graph cfg in
  let fpman = make_fpmanager man psh in
  let init = Pset.singleton (Cfg.Graph.compare_vertex) 1 in
  let fp_strategy = Fixpoint.make_strategy_default ~vertex_dummy:(-1) ~hedge_dummy:(-1) psh init in
  let fp = Fixpoint.analysis_std fpman psh init fp_strategy in
  let open Format in
  PSHGraph.print_dot
    (fun fmt v -> pp_print_text fmt @@ Cfg.Graph.string_of_vertex v)
    (fun fmt e -> pp_print_text fmt @@ string_of_int e)
    (fun fmt _ s -> pp_print_text fmt @@ show_absstate s)
    (fun fmt _ tf -> ())
    Format.err_formatter
    fp
  ) with
    | Manager.Error e ->
      print_endline e.Manager.msg;
      assert false