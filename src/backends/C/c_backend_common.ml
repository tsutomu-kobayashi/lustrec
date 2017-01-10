(********************************************************************)
(*                                                                  *)
(*  The LustreC compiler toolset   /  The LustreC Development Team  *)
(*  Copyright 2012 -    --   ONERA - CNRS - INPT                    *)
(*                                                                  *)
(*  LustreC is free software, distributed WITHOUT ANY WARRANTY      *)
(*  under the terms of the GNU Lesser General Public License        *)
(*  version 2.1.                                                    *)
(*                                                                  *)
(********************************************************************)

open Format
open LustreSpec
open Corelang
open Machine_code


let print_version fmt =
  Format.fprintf fmt 
    "/* @[<v>C code generated by %s@,Version number %s@,Code is %s compliant@,Using %s numbers */@,@]@."
    (Filename.basename Sys.executable_name) 
    Version.number 
    (if !Options.ansi then "ANSI C90" else "C99")
    (if !Options.mpfr then "MPFR multi-precision" else "(double) floating-point")

let file_to_module_name basename =
  let baseNAME = String.uppercase_ascii basename in
  let baseNAME = Str.global_replace (Str.regexp "\\.\\|\\ ") "_" baseNAME in
  baseNAME

(* Generation of a non-clashing name for the self memory variable (for step and reset functions) *)
let mk_self m =
  let used name =
       (List.exists (fun v -> v.var_id = name) m.mstep.step_inputs)
    || (List.exists (fun v -> v.var_id = name) m.mstep.step_outputs)
    || (List.exists (fun v -> v.var_id = name) m.mstep.step_locals)
    || (List.exists (fun v -> v.var_id = name) m.mmemory) in
  mk_new_name used "self"

(* Generation of a non-clashing name for the instance variable of static allocation macro *)
let mk_instance m =
  let used name =
       (List.exists (fun v -> v.var_id = name) m.mstep.step_inputs)
    || (List.exists (fun v -> v.var_id = name) m.mmemory) in
  mk_new_name used "inst"

(* Generation of a non-clashing name for the attribute variable of static allocation macro *)
let mk_attribute m =
  let used name =
       (List.exists (fun v -> v.var_id = name) m.mstep.step_inputs)
    || (List.exists (fun v -> v.var_id = name) m.mmemory) in
  mk_new_name used "attr"

let mk_call_var_decl loc id =
  { var_id = id;
    var_orig = false;
    var_dec_type = mktyp Location.dummy_loc Tydec_any;
    var_dec_clock = mkclock Location.dummy_loc Ckdec_any;
    var_dec_const = false;
    var_dec_value = None;
    var_type = Type_predef.type_arrow (Types.new_var ()) (Types.new_var ());
    var_clock = Clocks.new_var true;
    var_loc = loc }

(* counter for loop variable creation *)
let loop_cpt = ref (-1)

let reset_loop_counter () =
 loop_cpt := -1

let mk_loop_var m () =
  let vars = m.mstep.step_inputs@m.mstep.step_outputs@m.mstep.step_locals@m.mmemory in
  let rec aux () =
    incr loop_cpt;
    let s = Printf.sprintf "__%s_%d" "i" !loop_cpt in
    if List.exists (fun v -> v.var_id = s) vars then aux () else s
  in aux ()
(*
let addr_cpt = ref (-1)

let reset_addr_counter () =
 addr_cpt := -1

let mk_addr_var m var =
  let vars = m.mmemory in
  let rec aux () =
    incr addr_cpt;
    let s = Printf.sprintf "%s_%s_%d" var "addr" !addr_cpt in
    if List.exists (fun v -> v.var_id = s) vars then aux () else s
  in aux ()
*)
let pp_global_init_name fmt id = fprintf fmt "%s_INIT" id
let pp_global_clear_name fmt id = fprintf fmt "%s_CLEAR" id
let pp_machine_memtype_name fmt id = fprintf fmt "struct %s_mem" id
let pp_machine_regtype_name fmt id = fprintf fmt "struct %s_reg" id
let pp_machine_alloc_name fmt id = fprintf fmt "%s_alloc" id
let pp_machine_static_declare_name fmt id = fprintf fmt "%s_DECLARE" id
let pp_machine_static_link_name fmt id = fprintf fmt "%s_LINK" id
let pp_machine_static_alloc_name fmt id = fprintf fmt "%s_ALLOC" id
let pp_machine_reset_name fmt id = fprintf fmt "%s_reset" id
let pp_machine_init_name fmt id = fprintf fmt "%s_init" id
let pp_machine_clear_name fmt id = fprintf fmt "%s_clear" id
let pp_machine_step_name fmt id = fprintf fmt "%s_step" id

let rec pp_c_dimension fmt dim =
  match dim.Dimension.dim_desc with
  | Dimension.Dident id       ->
    fprintf fmt "%s" id
  | Dimension.Dint i          ->
    fprintf fmt "%d" i
  | Dimension.Dbool b         ->
    fprintf fmt "%B" b
  | Dimension.Dite (i, t, e)  ->
    fprintf fmt "((%a)?%a:%a)"
       pp_c_dimension i pp_c_dimension t pp_c_dimension e
 | Dimension.Dappl (f, args) ->
     fprintf fmt "%a" (Basic_library.pp_c f pp_c_dimension) args
 | Dimension.Dlink dim' -> fprintf fmt "%a" pp_c_dimension dim'
 | Dimension.Dvar       -> fprintf fmt "_%s" (Utils.name_of_dimension dim.Dimension.dim_id)
 | Dimension.Dunivar    -> fprintf fmt "'%s" (Utils.name_of_dimension dim.Dimension.dim_id)

let is_basic_c_type t =
  match (Types.repr t).Types.tdesc with
  | Types.Tbool | Types.Treal | Types.Tint  -> true
  | _                                       -> false

let pp_basic_c_type fmt t =
  match (Types.repr t).Types.tdesc with
  | Types.Tbool                    -> fprintf fmt "_Bool"
  | Types.Treal when !Options.mpfr -> fprintf fmt "%s" Mpfr.mpfr_t
  | Types.Treal                    -> fprintf fmt "double"
  | Types.Tint                     -> fprintf fmt "int"
  | _ -> assert false (* Not a basic C type. Do not handle arrays or pointers *)

let pp_c_type var fmt t =
  let rec aux t pp_suffix =
    match (Types.repr t).Types.tdesc with
    | Types.Tclock t'       -> aux t' pp_suffix
    | Types.Tbool | Types.Tint | Types.Treal
                            -> fprintf fmt "%a %s%a" pp_basic_c_type t var pp_suffix ()
    | Types.Tarray (d, t')  ->
      let pp_suffix' fmt () = fprintf fmt "%a[%a]" pp_suffix () pp_c_dimension d in
      aux t' pp_suffix'
    | Types.Tstatic (_, t') -> fprintf fmt "const "; aux t' pp_suffix
    | Types.Tconst ty       -> fprintf fmt "%s %s" ty var
    | Types.Tarrow (_, _)   -> fprintf fmt "void (*%s)()" var
    | _                     -> eprintf "internal error: C_backend_common.pp_c_type %a@." Types.print_ty t; assert false
  in aux t (fun fmt () -> ())
(*
let rec pp_c_initialize fmt t = 
  match (Types.repr t).Types.tdesc with
  | Types.Tint -> pp_print_string fmt "0"
  | Types.Tclock t' -> pp_c_initialize fmt t'
  | Types.Tbool -> pp_print_string fmt "0" 
  | Types.Treal when not !Options.mpfr -> pp_print_string fmt "0."
  | Types.Tarray (d, t') when Dimension.is_dimension_const d ->
    fprintf fmt "{%a}"
      (Utils.fprintf_list ~sep:"," (fun fmt _ -> pp_c_initialize fmt t'))
      (Utils.duplicate 0 (Dimension.size_const_dimension d))
  | _ -> assert false
 *)
let pp_c_tag fmt t =
 pp_print_string fmt (if t = tag_true then "1" else if t = tag_false then "0" else t)

(* Prints a constant value *)
let rec pp_c_const fmt c =
  match c with
    | Const_int i     -> pp_print_int fmt i
    | Const_real (c,e,s)-> pp_print_string fmt s (* Format.fprintf fmt "%ie%i" c e*)
    (* | Const_float r   -> pp_print_float fmt r *)
    | Const_tag t     -> pp_c_tag fmt t
    | Const_array ca  -> fprintf fmt "{%a }" (Utils.fprintf_list ~sep:", " pp_c_const) ca
    | Const_struct fl -> fprintf fmt "{%a }" (Utils.fprintf_list ~sep:", " (fun fmt (f, c) -> pp_c_const fmt c)) fl
    | Const_string _ -> assert false (* string occurs in annotations not in C *)

(* Prints a value expression [v], with internal function calls only.
   [pp_var] is a printer for variables (typically [pp_c_var_read]),
   but an offset suffix may be added for array variables
*)
let rec pp_c_val self pp_var fmt v =
  match v.value_desc with
  | Cst c         -> pp_c_const fmt c
  | Array vl      -> fprintf fmt "{%a}" (Utils.fprintf_list ~sep:", " (pp_c_val self pp_var)) vl
  | Access (t, i) -> fprintf fmt "%a[%a]" (pp_c_val self pp_var) t (pp_c_val self pp_var) i
  | Power (v, n)  -> (Format.eprintf "internal error: C_backend_common.pp_c_val %a@." pp_val v; assert false)
  | LocalVar v    -> pp_var fmt v
  | StateVar v    ->
    (* array memory vars are represented by an indirection to a local var with the right type,
       in order to avoid casting everywhere. *)
    if Types.is_array_type v.var_type && not (Types.is_real_type v.var_type && !Options.mpfr)
    then fprintf fmt "%a" pp_var v
    else fprintf fmt "%s->_reg.%a" self pp_var v
  | Fun (n, vl)   -> Basic_library.pp_c n (pp_c_val self pp_var) fmt vl

(* Access to the value of a variable:
   - if it's not a scalar output, then its name is enough
   - otherwise, dereference it (it has been declared as a pointer,
     despite its scalar Lustre type)
   - moreover, dereference memory array variables.
*)
let pp_c_var_read m fmt id =
  (* mpfr_t is a static array, not treated as general arrays *)
  if Types.is_address_type id.var_type
  then
    if is_memory m id && not (Types.is_real_type id.var_type && !Options.mpfr)
    then fprintf fmt "(*%s)" id.var_id
    else fprintf fmt "%s" id.var_id
  else
    if is_output m id
    then fprintf fmt "*%s" id.var_id
    else fprintf fmt "%s" id.var_id

(* Addressable value of a variable, the one that is passed around in calls:
   - if it's not a scalar non-output, then its name is enough
   - otherwise, reference it (it must be passed as a pointer,
     despite its scalar Lustre type)
*)
let pp_c_var_write m fmt id =
  if Types.is_address_type id.var_type
  then
    fprintf fmt "%s" id.var_id
  else
    if is_output m id
    then
      fprintf fmt "%s" id.var_id
    else
      fprintf fmt "&%s" id.var_id

(* Declaration of an input variable:
   - if its type is array/matrix/etc, then declare it as a mere pointer,
     in order to cope with unknown/parametric array dimensions, 
     as it is the case for generics
*)
let pp_c_decl_input_var fmt id =
  if !Options.ansi && Types.is_address_type id.var_type
  then pp_c_type (sprintf "(*%s)" id.var_id) fmt (Types.array_base_type id.var_type)
  else pp_c_type id.var_id fmt id.var_type

(* Declaration of an output variable:
   - if its type is scalar, then pass its address
   - if its type is array/matrix/struct/etc, then declare it as a mere pointer,
     in order to cope with unknown/parametric array dimensions, 
     as it is the case for generics
*)
let pp_c_decl_output_var fmt id =
  if (not !Options.ansi) && Types.is_address_type id.var_type
  then pp_c_type                  id.var_id  fmt id.var_type
  else pp_c_type (sprintf "(*%s)" id.var_id) fmt (Types.array_base_type id.var_type)

(* Declaration of a local/mem variable:
   - if it's an array/matrix/etc, its size(s) should be
     known in order to statically allocate memory, 
     so we print the full type
*)
let pp_c_decl_local_var m fmt id =
  if id.var_dec_const
  then
    Format.fprintf fmt "%a = %a"
      (pp_c_type id.var_id) id.var_type
      (pp_c_val "" (pp_c_var_read m)) (get_const_assign m id)
  else
    Format.fprintf fmt "%a"
      (pp_c_type id.var_id) id.var_type

let pp_c_decl_array_mem self fmt id =
  fprintf fmt "%a = (%a) (%s->_reg.%s)"
    (pp_c_type (sprintf "(*%s)" id.var_id)) id.var_type
    (pp_c_type "(*)") id.var_type
    self
    id.var_id

(* Declaration of a struct variable:
   - if it's an array/matrix/etc, we declare it as a pointer
*)
let pp_c_decl_struct_var fmt id =
  if Types.is_array_type id.var_type
  then pp_c_type (sprintf "(*%s)" id.var_id) fmt (Types.array_base_type id.var_type)
  else pp_c_type                  id.var_id  fmt id.var_type

let pp_c_decl_instance_var fmt (name, (node, static)) = 
  fprintf fmt "%a *%s" pp_machine_memtype_name (node_name node) name

let pp_c_checks self fmt m =
  Utils.fprintf_list ~sep:"" 
    (fun fmt (loc, check) -> 
      fprintf fmt 
	"@[<v>%a@,assert (%a);@]@," 
	Location.pp_c_loc loc
	(pp_c_val self (pp_c_var_read m)) check
    ) 
    fmt 
    m.mstep.step_checks

(********************************************************************************************)
(*                       Struct Printing functions                                          *)
(********************************************************************************************)

let pp_registers_struct fmt m =
  if m.mmemory <> []
  then
    fprintf fmt "@[%a {@[<v>%a;@ @]}@] _reg; "
      pp_machine_regtype_name m.mname.node_id
      (Utils.fprintf_list ~sep:";@ " pp_c_decl_struct_var) m.mmemory
  else
    ()

let print_machine_struct fmt m =
  if fst (get_stateless_status m) then
    begin
    end
  else
    begin
      (* Define struct *)
      fprintf fmt "@[%a {@[<v>%a%t%a%t@]};@]@."
	pp_machine_memtype_name m.mname.node_id
	pp_registers_struct m
	(Utils.pp_final_char_if_non_empty "@ " m.mmemory)
	(Utils.fprintf_list ~sep:";@ " pp_c_decl_instance_var) m.minstances
	(Utils.pp_final_char_if_non_empty ";@ " m.minstances)
    end

let print_machine_struct_from_header fmt inode =
  if inode.nodei_stateless then
    begin
    end
  else
    begin
      (* Declare struct *)
      fprintf fmt "@[%a;@]@."
	pp_machine_memtype_name inode.nodei_id
    end

(********************************************************************************************)
(*                      Prototype Printing functions                                        *)
(********************************************************************************************)

let print_global_init_prototype fmt baseNAME =
  fprintf fmt "void %a ()"
    pp_global_init_name baseNAME

let print_global_clear_prototype fmt baseNAME =
  fprintf fmt "void %a ()"
    pp_global_clear_name baseNAME

let print_alloc_prototype fmt (name, static) =
  fprintf fmt "%a * %a (%a)"
    pp_machine_memtype_name name
    pp_machine_alloc_name name
    (Utils.fprintf_list ~sep:",@ " pp_c_decl_input_var) static

let print_reset_prototype self fmt (name, static) =
  fprintf fmt "void %a (@[<v>%a%t%a *%s@])"
    pp_machine_reset_name name
    (Utils.fprintf_list ~sep:",@ " pp_c_decl_input_var) static
    (Utils.pp_final_char_if_non_empty ",@," static) 
    pp_machine_memtype_name name
    self

let print_init_prototype self fmt (name, static) =
  fprintf fmt "void %a (@[<v>%a%t%a *%s@])"
    pp_machine_init_name name
    (Utils.fprintf_list ~sep:",@ " pp_c_decl_input_var) static
    (Utils.pp_final_char_if_non_empty ",@," static) 
    pp_machine_memtype_name name
    self

let print_clear_prototype self fmt (name, static) =
  fprintf fmt "void %a (@[<v>%a%t%a *%s@])"
    pp_machine_clear_name name
    (Utils.fprintf_list ~sep:",@ " pp_c_decl_input_var) static
    (Utils.pp_final_char_if_non_empty ",@," static) 
    pp_machine_memtype_name name
    self

let print_stateless_prototype fmt (name, inputs, outputs) =
  fprintf fmt "void %a (@[<v>@[%a%t@]@,@[%a@]@,@])"
    pp_machine_step_name name
    (Utils.fprintf_list ~sep:",@ " pp_c_decl_input_var) inputs
    (Utils.pp_final_char_if_non_empty ",@ " inputs) 
    (Utils.fprintf_list ~sep:",@ " pp_c_decl_output_var) outputs

let print_step_prototype self fmt (name, inputs, outputs) =
  fprintf fmt "void %a (@[<v>@[%a%t@]@,@[%a@]%t@[%a *%s@]@])"
    pp_machine_step_name name
    (Utils.fprintf_list ~sep:",@ " pp_c_decl_input_var) inputs
    (Utils.pp_final_char_if_non_empty ",@ " inputs) 
    (Utils.fprintf_list ~sep:",@ " pp_c_decl_output_var) outputs
    (Utils.pp_final_char_if_non_empty ",@," outputs) 
    pp_machine_memtype_name name
    self

let print_stateless_C_prototype fmt (name, inputs, outputs) =
  let output = 
    match outputs with
    | [hd] -> hd
    | _ -> assert false
  in
  fprintf fmt "%a %s (@[<v>@[%a@]@,@])"
    pp_basic_c_type output.var_type
    name
    (Utils.fprintf_list ~sep:",@ " pp_c_decl_input_var) inputs
    
let print_import_init fmt (Dep (local, basename, _, _)) =
  if local then
    let baseNAME = file_to_module_name basename in
    fprintf fmt "%a();" pp_global_init_name baseNAME
  else ()

let print_import_clear fmt (Dep (local, basename, _, _)) =
  if local then
    let baseNAME = file_to_module_name basename in
    fprintf fmt "%a();" pp_global_clear_name baseNAME
  else ()

let print_import_prototype fmt (Dep (_, s, _, _)) =
  fprintf fmt "#include \"%s.h\"@," s

let print_import_alloc_prototype fmt (Dep (_, s, _, stateful)) =
  if stateful then
    fprintf fmt "#include \"%s_alloc.h\"@," s

let print_extern_alloc_prototypes fmt (Dep (_,_, header,_)) =
  List.iter (fun decl -> match decl.top_decl_desc with
  | ImportedNode ind when not ind.nodei_stateless ->
    let static = List.filter (fun v -> v.var_dec_const) ind.nodei_inputs
    in fprintf fmt "extern %a;@." print_alloc_prototype (ind.nodei_id, static)
  | _                -> ()
  ) header


let pp_c_main_var_input fmt id =  
  fprintf fmt "%s" id.var_id

let pp_c_main_var_output fmt id =
  if Types.is_address_type id.var_type
  then
    fprintf fmt "%s" id.var_id
  else
    fprintf fmt "&%s" id.var_id

let pp_main_call mname self fmt m (inputs: value_t list) (outputs: var_decl list) =
  if fst (get_stateless_status m)
  then
    fprintf fmt "%a (%a%t%a);"
      pp_machine_step_name mname
      (Utils.fprintf_list ~sep:", " (pp_c_val self pp_c_main_var_input)) inputs
      (Utils.pp_final_char_if_non_empty ", " inputs) 
      (Utils.fprintf_list ~sep:", " pp_c_main_var_output) outputs
  else
    fprintf fmt "%a (%a%t%a%t%s);"
      pp_machine_step_name mname
      (Utils.fprintf_list ~sep:", " (pp_c_val self pp_c_main_var_input)) inputs
      (Utils.pp_final_char_if_non_empty ", " inputs) 
      (Utils.fprintf_list ~sep:", " pp_c_main_var_output) outputs
      (Utils.pp_final_char_if_non_empty ", " outputs)
      self

let pp_c_var m self pp_var fmt var =
  if is_memory m var
  then
    pp_c_val self pp_var fmt (mk_val (StateVar var) var.var_type)
  else
    pp_c_val self pp_var fmt (mk_val (LocalVar var) var.var_type)

let pp_array_suffix fmt loop_vars =
  Utils.fprintf_list ~sep:"" (fun fmt v -> fprintf fmt "[%s]" v) fmt loop_vars

(* type directed initialization: useless wrt the lustre compilation model,
   except for MPFR injection, where values are dynamically allocated
*)
let pp_initialize m self pp_var fmt var =
  let rec aux indices fmt typ =
    if Types.is_array_type typ
    then
      let dim = Types.array_type_dimension typ in
      let idx = mk_loop_var m () in
      fprintf fmt "@[<v 2>{@,int %s;@,for(%s=0;%s<%a;%s++)@,%a @]@,}"
	idx idx idx pp_c_dimension dim idx
	(aux (idx::indices)) (Types.array_element_type typ)
    else
      let indices = List.rev indices in
      let pp_var_suffix fmt var =
	fprintf fmt "%a%a" (pp_c_var m self pp_var) var pp_array_suffix indices in
      Mpfr.pp_inject_init pp_var_suffix fmt var
  in
  if !Options.mpfr && Types.is_real_type (Types.array_base_type var.var_type)
  then
    begin
      reset_loop_counter ();
      aux [] fmt var.var_type
    end

let pp_const_initialize pp_var fmt const =
  let var = mk_val (LocalVar (Corelang.var_decl_of_const const)) const.const_type in
  let rec aux indices value fmt typ =
    if Types.is_array_type typ
    then
      let dim = Types.array_type_dimension typ in
      let szl = Utils.enumerate (Dimension.size_const_dimension dim) in
      let typ' = Types.array_element_type typ in
      let value = match value with
	| Const_array ca -> List.nth ca
	| _                      -> assert false in
      fprintf fmt "%a"
	(Utils.fprintf_list ~sep:"@," (fun fmt i -> aux (string_of_int i::indices) (value i) fmt typ')) szl
    else
      let indices = List.rev indices in
      let pp_var_suffix fmt var =
	fprintf fmt "%a%a" (pp_c_val "" pp_var) var pp_array_suffix indices in
      begin
	Mpfr.pp_inject_init pp_var_suffix fmt var;
	fprintf fmt "@,";
	Mpfr.pp_inject_real pp_var_suffix pp_c_const fmt var value
      end
  in
  if !Options.mpfr && Types.is_real_type (Types.array_base_type const.const_type)
  then
    begin
      reset_loop_counter ();
      aux [] const.const_value fmt const.const_type
    end

(* type directed clear: useless wrt the lustre compilation model,
   except for MPFR injection, where values are dynamically allocated
*)
let pp_clear m self pp_var fmt var =
  let rec aux indices fmt typ =
    if Types.is_array_type typ
    then
      let dim = Types.array_type_dimension typ in
      let idx = mk_loop_var m () in
      fprintf fmt "@[<v 2>{@,int %s;@,for(%s=0;%s<%a;%s++)@,%a @]@,}"
	idx idx idx pp_c_dimension dim idx
	(aux (idx::indices)) (Types.array_element_type typ)
    else
      let indices = List.rev indices in
      let pp_var_suffix fmt var =
	fprintf fmt "%a%a" (pp_c_var m self pp_var) var pp_array_suffix indices in
      Mpfr.pp_inject_clear pp_var_suffix fmt var
  in
  if !Options.mpfr && Types.is_real_type (Types.array_base_type var.var_type)
  then
    begin
      reset_loop_counter ();
      aux [] fmt var.var_type
    end

let pp_const_clear pp_var fmt const =
  let m = Machine_code.empty_machine in
  let var = Corelang.var_decl_of_const const in
  let rec aux indices fmt typ =
    if Types.is_array_type typ
    then
      let dim = Types.array_type_dimension typ in
      let idx = mk_loop_var m () in
      fprintf fmt "@[<v 2>{@,int %s;@,for(%s=0;%s<%a;%s++)@,%a @]@,}"
	idx idx idx pp_c_dimension dim idx
	(aux (idx::indices)) (Types.array_element_type typ)
    else
      let indices = List.rev indices in
      let pp_var_suffix fmt var =
	fprintf fmt "%a%a" (pp_c_var m "" pp_var) var pp_array_suffix indices in
      Mpfr.pp_inject_clear pp_var_suffix fmt var 
  in
  if !Options.mpfr && Types.is_real_type (Types.array_base_type var.var_type)
  then
    begin
      reset_loop_counter ();
      aux [] fmt var.var_type
    end

let pp_call m self pp_read pp_write fmt i (inputs: value_t list) (outputs: var_decl list) =
 try (* stateful node instance *)
   let (n,_) = List.assoc i m.minstances in
   fprintf fmt "%a (%a%t%a%t%s->%s);"
     pp_machine_step_name (node_name n)
     (Utils.fprintf_list ~sep:", " (pp_c_val self pp_read)) inputs
     (Utils.pp_final_char_if_non_empty ", " inputs) 
     (Utils.fprintf_list ~sep:", " pp_write) outputs
     (Utils.pp_final_char_if_non_empty ", " outputs)
     self
     i
 with Not_found -> (* stateless node instance *)
   let (n,_) = List.assoc i m.mcalls in
   fprintf fmt "%a (%a%t%a);"
     pp_machine_step_name (node_name n)
     (Utils.fprintf_list ~sep:", " (pp_c_val self pp_read)) inputs
     (Utils.pp_final_char_if_non_empty ", " inputs) 
     (Utils.fprintf_list ~sep:", " pp_write) outputs 

let pp_basic_instance_call m self fmt i (inputs: value_t list) (outputs: var_decl list) =
  pp_call m self (pp_c_var_read m) (pp_c_var_write m) fmt i inputs outputs
(*
 try (* stateful node instance *)
   let (n,_) = List.assoc i m.minstances in
   fprintf fmt "%a (%a%t%a%t%s->%s);"
     pp_machine_step_name (node_name n)
     (Utils.fprintf_list ~sep:", " (pp_c_val self (pp_c_var_read m))) inputs
     (Utils.pp_final_char_if_non_empty ", " inputs) 
     (Utils.fprintf_list ~sep:", " (pp_c_var_write m)) outputs
     (Utils.pp_final_char_if_non_empty ", " outputs)
     self
     i
 with Not_found -> (* stateless node instance *)
   let (n,_) = List.assoc i m.mcalls in
   fprintf fmt "%a (%a%t%a);"
     pp_machine_step_name (node_name n)
     (Utils.fprintf_list ~sep:", " (pp_c_val self (pp_c_var_read m))) inputs
     (Utils.pp_final_char_if_non_empty ", " inputs) 
     (Utils.fprintf_list ~sep:", " (pp_c_var_write m)) outputs 
*)

let pp_instance_call m self fmt i (inputs: value_t list) (outputs: var_decl list) =
  let pp_offset pp_var indices fmt var =
    match indices with
    | [] -> fprintf fmt "%a" pp_var var
    | _  -> fprintf fmt "%a[%a]" pp_var var (Utils.fprintf_list ~sep:"][" pp_print_string) indices in
  let rec aux indices fmt typ =
    if Types.is_array_type typ
    then
      let dim = Types.array_type_dimension typ in
      let idx = mk_loop_var m () in
      fprintf fmt "@[<v 2>{@,int %s;@,for(%s=0;%s<%a;%s++)@,%a @]@,}"
	idx idx idx pp_c_dimension dim idx
	(aux (idx::indices)) (Types.array_element_type typ)
    else
      let pp_read  = pp_offset (pp_c_var_read  m) indices in
      let pp_write = pp_offset (pp_c_var_write m) indices in
      pp_call m self pp_read pp_write fmt i inputs outputs
  in
  begin
    reset_loop_counter ();
    aux [] fmt (List.hd inputs).value_type
  end

(* Local Variables: *)
(* compile-command:"make -C ../../.." *)
(* End: *)
