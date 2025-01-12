open Cerb_backend.Pipeline

let impl_name = "gcc_4.9.0_x86_64-apple-darwin10.8.0"

let cpp_str =
    "cc -E -C -Werror -nostdinc -undef -D__cerb__"
    ^ " -I " ^ Cerb_runtime.in_runtime "libc/include"
    ^ " -I " ^ Cerb_runtime.in_runtime "libcore"
    ^ " -DDEBUG"

let with_cn_keywords str =
  let cn_keywords =
    [ "predicate"
    ; "pack"
    ; "unpack"
    ; "pack_struct"
    ; "unpack_struct"
    ; "have"
    ; "show" ] in
  List.fold_left (fun acc kw ->
    acc ^ " -D" ^ kw ^ "=__cerb_" ^ kw
  ) str cn_keywords


let conf (* cpp_str *) = 
  { debug_level = 0
  ; pprints = []
  ; astprints = []
  ; ppflags = []
  ; typecheck_core = true
  ; rewrite_core = true
  ; sequentialise_core = true
  ; cpp_cmd = with_cn_keywords cpp_str
  ; cpp_stderr = true
  }
