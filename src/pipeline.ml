open Prelude

external terminal_size: unit -> (int * int) option = "terminal_size"

(* Pipeline *)

let (>>=) = Exception.except_bind
let (>>) m f = m >>= fun _ -> f
let (<$>)  = Exception.except_fmap
let return = Exception.except_return

let run_pp with_ext doc =
  let (is_fout, oc) =
    match with_ext with
      | Some (filename, ext_str) ->
          (true, Pervasives.open_out (Filename.remove_extension (Filename.basename filename) ^ "." ^ ext_str))
      | None ->
          (false, Pervasives.stdout) in
  let saved = !Colour.do_colour in
  Colour.do_colour := not is_fout;
  let term_col = match terminal_size () with
    | Some (_, col) -> col
    | _ -> 80
  in
  PPrint.ToChannel.pretty 1.0 term_col oc doc;
  if is_fout then
    close_out oc;
  Colour.do_colour := saved

(* The path to the Core standard library *)
let core_stdlib_path =
  Filename.concat Global_ocaml.cerb_path "include/core"

(* == load the Core standard library ============================================================ *)
let load_core_stdlib () =
  let filepath = Filename.concat core_stdlib_path "std.core" in
  if not (Sys.file_exists filepath) then
    error ("couldn't find the Core standard library file\n (looked at: `" ^ filepath ^ "').")
  else
    Core_parser_driver.parse_stdlib filepath >>= function
    | Core_parser_util.Rstd (ailnames, std_funs) ->
      return (ailnames, std_funs)
    | _ ->
      error "while parsing the Core stdlib, the parser didn't recognise it as a stdlib."

(* == load the implementation file ============================================================== *)
let load_core_impl core_stdlib impl_name =
  let iname = Filename.concat core_stdlib_path ("impls/" ^ impl_name ^ ".impl") in
  if not (Sys.file_exists iname) then
    error ("couldn't find the implementation file\n (looked at: `" ^ iname ^ "').")
  else
    match Core_parser_driver.parse core_stdlib iname with
    | Exception.Result (Core_parser_util.Rimpl impl_map) ->
      return impl_map
    | _ ->
      error "while parsing the Core impl, the parser didn't recognise it as an impl ."

let (>|>) m1 m2 =
  m1 >>= fun z  ->
  m2 >>= fun () ->
  return z

let whenM cond m =
  if cond then m () else return ()

type language =
  | Cabs | Ail | Core

type pp_flag =
  | Annot | FOut

type configuration = {
  debug_level: int;
  pprints: language list;
  astprints: language list;
  ppflags: pp_flag list;
  typecheck_core: bool;
  rewrite_core: bool;
  sequentialise_core: bool;
  cpp_cmd: string;
}

type io_helpers = {
  pass_message: string -> (unit, Errors.error) Exception.exceptM;
  set_progress: string -> (unit, Errors.error) Exception.exceptM;
  run_pp: (string * string) option -> PPrint.document -> (unit, Errors.error) Exception.exceptM;
  print_endline: string -> (unit, Errors.error) Exception.exceptM;
  print_debug: int -> (unit -> string) -> (unit, Errors.error) Exception.exceptM;
  warn: (unit -> string) -> (unit, Errors.error) Exception.exceptM;
}

let read_entire_file filename =
  let ic = open_in filename in
  let n = in_channel_length ic in
  let bs = Bytes.create n in
  really_input ic bs 0 n;
  close_in ic;
  Bytes.to_string bs

let c_frontend (conf, io) (core_stdlib, core_impl) ~filename =
  Fresh.set_digest filename;
  let wrap_fout z = if List.mem FOut conf.ppflags then z else None in
  (* -- *)
  let parse filename =
    Cparser_driver.parse filename >>= fun cabs_tunit ->
    io.set_progress "CPARS" >>= fun () ->
    io.pass_message "C parsing completed!" >>= fun () ->
    whenM (List.mem Cabs conf.astprints) begin
      fun () -> io.run_pp None (Pp_cabs.pp_translation_unit true true cabs_tunit)
    end >>= fun () ->
    whenM (List.mem Cabs conf.pprints) begin
      fun () -> io.warn (fun () -> "TODO: Cabs pprint to yet supported")
    end >>= fun () -> return cabs_tunit in
  (* -- *)
  let desugar cabs_tunit =
    let (ailnames, core_stdlib_fun_map) = core_stdlib in
    Cabs_to_ail.desugar (ailnames, core_stdlib_fun_map, core_impl)
      "main" cabs_tunit >>= fun ail_prog ->
          io.set_progress "DESUG"
      >|> io.pass_message "Cabs -> Ail completed!"
          (* NOTE: if the debug level is lower the do the printing after the typing *)
      >|> whenM (conf.debug_level > 4 && List.mem Ail conf.astprints) begin
            fun () -> io.run_pp None (Pp_ail_ast.pp_program false false ail_prog)
          end
      >|> whenM (conf.debug_level > 4 && List.mem Ail conf.pprints) begin
            fun () -> io.run_pp (wrap_fout (Some (filename, "ail"))) (Pp_ail.pp_program false false ail_prog)
          end
      >>= fun () -> return ail_prog in
  (* -- *)
  let ail_typechecking ail_prog =
    ErrorMonad.to_exception (fun (loc, err) -> (loc, Errors.AIL_TYPING err))
      (GenTyping.annotate_program ail_prog) >>= fun (ailtau_prog, _) ->
    whenM (conf.debug_level <= 4 && List.mem Ail conf.astprints) begin
      fun () ->
        let doc = if conf.debug_level = 4 then
          (* (for debug 4) pretty-printing Ail with type annotations *)
          Pp_ail_ast.pp_program_with_annot ailtau_prog
        else
          Pp_ail_ast.pp_program false false ailtau_prog in
        io.run_pp None doc
    end >>= fun () ->
    whenM (conf.debug_level <= 4 && List.mem Ail conf.pprints) begin
      fun () ->
        let doc = if conf.debug_level = 4 then
          (* (for debug 4) pretty-printing Ail with type annotations *)
          Pp_ail.pp_program_with_annot ailtau_prog
        else
          Pp_ail.pp_program false false ailtau_prog in
        io.run_pp (wrap_fout (Some (filename, "ail"))) doc
    end >>= fun () -> return ailtau_prog in
  (* -- *)
  io.print_debug 2 (fun () -> "Using the C frontend") >>= fun () ->
  let processed_filename = Filename.(temp_file (basename filename) "") in
  io.print_debug 5 (fun () -> "C prepocessor outputed in: `" ^ processed_filename ^ "`") >>= fun () ->
  if Sys.command (conf.cpp_cmd ^ " " ^ filename ^ " 1> " ^ processed_filename ^ " 2> cpp_error") <> 0 then
    failwith @@ read_entire_file "cpp_error";
  (* -- *)
  parse processed_filename  >>= fun cabs_tunit  ->
  desugar cabs_tunit        >>= fun ail_prog    ->
  ail_typechecking ail_prog >>= fun ailtau_prog ->
  (* NOTE: the elaboration sets the struct/union tag definitions, so to allow the frontend to be
     used more than once, we need to do reset here *)
  (* TODO(someday): find a better way *)
  Tags.reset_tagDefs ();
  let core_file = Translation.translate core_stdlib core_impl ailtau_prog in
  io.set_progress "ELABO" >>= fun () ->
  io.pass_message "Translation to Core completed!" >>= fun () ->
  return (Some cabs_tunit, Some ailtau_prog, core_file)

let core_frontend (conf, io) (core_stdlib, core_impl) ~filename =
  Fresh.set_digest filename;
  io.print_debug 2 (fun () -> "Using the Core frontend") >>= fun () ->
  Core_parser_driver.parse core_stdlib filename >>= function
    | Core_parser_util.Rfile (sym_main, globs, funs, tagDefs) ->
        Tags.set_tagDefs tagDefs;
        return {
           Core.main=   Some sym_main;
           Core.tagDefs= tagDefs;
           Core.stdlib= snd core_stdlib;
           Core.impl=   core_impl;
           Core.globs=  Pmap.empty compare;(*globs*) (* FIXME VICTOR *)
           Core.funs=   funs;
           Core.extern=  Pmap.empty compare;
           Core.funinfo= Pmap.empty compare; (* TODO: need to parse funinfo! *)
         }
    | Core_parser_util.Rstd _ ->
        error "Found no main function in the Core program"
    | Core_parser_util.Rimpl _ ->
        failwith "core_frontend found a Rimpl"

let rewrite_core (conf, io) core_file =
  return (Core_rewrite.rewrite_file core_file) >|>
  whenM (conf.debug_level >= 6 && List.mem Core conf.astprints) begin
    fun () ->
      io.print_endline "BEGIN (before Core rewrite)" >>= fun () ->
      io.run_pp None (Ast_core.ast_file core_file)   >>= fun () ->
      io.print_endline "END"
  end
  >|> whenM (conf.debug_level >= 5 && List.mem Core conf.pprints) begin
    fun () ->
      io.print_endline "BEGIN (before Core rewrite)"   >>= fun () ->
      io.run_pp None (Pp_core.Basic.pp_file core_file) >>= fun () ->
      io.print_endline "END"
  end


let core_passes (conf, io) ~filename core_file =
  let wrap_fout z = if List.mem FOut conf.ppflags then z else None in
  whenM conf.typecheck_core begin
    fun () ->
      Core_typing.typecheck_program core_file >>= fun _ ->
      io.pass_message "Core typechecking completed!"
  end >>= fun () ->
  (* TODO: for now assuming a single order comes from indet expressions *)
  Core_indet.hackish_order <$> begin
    if conf.rewrite_core then rewrite_core (conf, io) core_file
    else return core_file
  end >>= fun core_file' ->
  (* NOTE: unlike the earlier call, this is typechecking after the rewriting and
     the indet passes *)
  Core_typing.typecheck_program core_file' >>= fun typed_core_file' ->
  let typed_core_file'' =
    if conf.sequentialise_core then
      Core_sequentialise.sequentialise_file typed_core_file'
    else
      typed_core_file' in
  whenM (List.mem Core conf.astprints) begin
    fun () ->
      io.run_pp (wrap_fout (Some (filename, "core"))) (Ast_core.ast_file typed_core_file'')
  end >>= fun () ->
  whenM (List.mem Core conf.pprints) begin
    fun () ->
      io.run_pp (wrap_fout (Some (filename, "core"))) (Pp_core.Basic.pp_file typed_core_file'')
  end >>= fun () -> return (core_file', typed_core_file'')


let interp_backend io core_file ~args ~batch ~fs ~driver_conf =
  let module D = Exhaustive_driver in
  let fs_state = if fs <> "" then Fs_ocaml.initialise fs else Sibylfs.fs_initial_state in
  (* TODO: temporary hack for the command name *)
  match batch with
  | (`Batch | `CharonBatch) as mode ->
    let executions = D.batch_drive mode core_file ("cmdname" :: args) fs_state driver_conf in
    return (Either.Left executions)
  | `NotBatch ->
    let open Core in
    D.drive core_file ("cmdname" :: args) fs_state driver_conf >>= function
      | (Vloaded (LVspecified (OVinteger ival)) :: _) ->
          (* TODO: yuck *)
          return (Either.Right begin try
            int_of_string (String_mem.string_pretty_of_integer_value ival)
          with | _ ->
            Debug_ocaml.warn [] (fun () -> "Return value was not a (simple) specified integer");
            0
          end)
      | (cval :: _) ->
          io.warn (fun () -> "HELLO> " ^ String_core.string_of_value cval) >>= fun () ->
          return (Either.Right 0)
      | [] ->
          io.warn (fun () -> "BACKEND FOUND EMPTY RESULT") >>= fun () ->
          return (Either.Right 0)

let read_core_object fname =
  let ic = open_in_bin fname in
  let core_file = Marshal.from_channel ic in
  close_in ic;
  core_file

let write_core_object core_file fname =
  let oc = open_out_bin fname in
  Marshal.to_channel oc core_file [Marshal.No_sharing; Marshal.Closures];
  close_out oc


(* FIXME: this is not working *)
let ocaml_backend (conf, io) ~filename ~ocaml_corestd core_file =
  (* the OCaml backend really needs things to have been sequentialised *)
  (fun (_, typed_core) ->
     if conf.sequentialise_core then typed_core
     else Core_sequentialise.sequentialise_file typed_core)
  <$> core_passes (conf, io) filename core_file
  >>= Codegen_ocaml.gen filename ocaml_corestd


