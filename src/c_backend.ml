(* ----------------------------------------------------------------------------
 * SchedMCore - A MultiCore Scheduling Framework
 * Copyright (C) 2009-2013, ONERA, Toulouse, FRANCE - LIFL, Lille, FRANCE
 * Copyright (C) 2012-2013, INPT, Toulouse, FRANCE
 *
 * This file is part of Prelude
 *
 * Prelude is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * as published by the Free Software Foundation ; either version 2 of
 * the License, or (at your option) any later version.
 *
 * Prelude is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY ; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program ; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307
 * USA
 *---------------------------------------------------------------------------- *)

(* This module is used for the lustre to C compiler *)

open Format
open LustreSpec
open Corelang
open Machine_code


(********************************************************************************************)
(*                     Basic      Printing functions                                        *)
(********************************************************************************************)

let print_version fmt =
  Format.fprintf fmt "/* @[<v>C code generated by %s@,SVN version number %s@,Code is %s compliant */@,@]@."
    (Filename.basename Sys.executable_name) Version.number (if !Options.ansi then "ANSI C90" else "C99")

let mk_self m =
  mk_new_name (m.mstep.step_inputs@m.mstep.step_outputs@m.mstep.step_locals@m.mmemory) "self"

let mk_call_var_decl loc id =
  { var_id = id;
    var_dec_type = mktyp Location.dummy_loc Tydec_any;
    var_dec_clock = mkclock Location.dummy_loc Ckdec_any;
    var_dec_const = false;
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
let pp_machine_memtype_name fmt id = fprintf fmt "struct %s_mem" id
let pp_machine_regtype_name fmt id = fprintf fmt "struct %s_reg" id
let pp_machine_alloc_name fmt id = fprintf fmt "%s_alloc" id
let pp_machine_static_declare_name fmt id = fprintf fmt "%s_DECLARE" id
let pp_machine_static_link_name fmt id = fprintf fmt "%s_LINK" id
let pp_machine_static_alloc_name fmt id = fprintf fmt "%s_ALLOC" id
let pp_machine_reset_name fmt id = fprintf fmt "%s_reset" id
let pp_machine_step_name fmt id = fprintf fmt "%s_step" id

let pp_c_dimension fmt d =
 fprintf fmt "%a" Dimension.pp_dimension d

let pp_c_type var fmt t =
  let rec aux t pp_suffix =
  match (Types.repr t).Types.tdesc with
  | Types.Tclock t'       -> aux t' pp_suffix
  | Types.Tbool           -> Format.fprintf fmt "_Bool %s%a" var pp_suffix ()
  | Types.Treal           -> Format.fprintf fmt "double %s%a" var pp_suffix ()
  | Types.Tint            -> Format.fprintf fmt "int %s%a" var pp_suffix ()
  | Types.Tarray (d, t')  ->
    let pp_suffix' fmt () = Format.fprintf fmt "%a[%a]" pp_suffix () pp_c_dimension d in
    aux t' pp_suffix'
  | Types.Tstatic (_, t') -> Format.fprintf fmt "const "; aux t' pp_suffix
  | Types.Tconst ty       -> Format.fprintf fmt "%s %s" ty var
  | Types.Tarrow (_, _)   -> Format.fprintf fmt "void (*%s)()" var
  | _                     -> Format.eprintf "internal error: pp_c_type %a@." Types.print_ty t; assert false
  in aux t (fun fmt () -> ())

let rec pp_c_initialize fmt t = 
  match (Types.repr t).Types.tdesc with
  | Types.Tint -> pp_print_string fmt "0"
  | Types.Tclock t' -> pp_c_initialize fmt t'
  | Types.Tbool -> pp_print_string fmt "0" 
  | Types.Treal -> pp_print_string fmt "0."
  | Types.Tarray (d, t') when Dimension.is_dimension_const d ->
    Format.fprintf fmt "{%a}"
      (Utils.fprintf_list ~sep:"," (fun fmt _ -> pp_c_initialize fmt t'))
      (Utils.duplicate 0 (Dimension.size_const_dimension d))
  | _ -> assert false

(* Declaration of an input variable:
   - if its type is array/matrix/etc, then declare it as a mere pointer,
     in order to cope with unknown/parametric array dimensions, 
     as it is the case for generics
*)
let pp_c_decl_input_var fmt id =
  if !Options.ansi && Types.is_array_type id.var_type
  then pp_c_type (sprintf "(*%s)" id.var_id) fmt (Types.array_base_type id.var_type)
  else pp_c_type id.var_id fmt id.var_type

(* Declaration of an output variable:
   - if its type is scalar, then pass its address
   - if its type is array/matrix/etc, then declare it as a mere pointer,
     in order to cope with unknown/parametric array dimensions, 
     as it is the case for generics
*)
let pp_c_decl_output_var fmt id =
  if (not !Options.ansi) && Types.is_array_type id.var_type
  then pp_c_type                  id.var_id  fmt id.var_type
  else pp_c_type (sprintf "(*%s)" id.var_id) fmt (Types.array_base_type id.var_type)

(* Declaration of a local/mem variable:
   - if it's an array/matrix/etc, its size(s) should be
     known in order to statically allocate memory, 
     so we print the full type
*)
let pp_c_decl_local_var fmt id =
  pp_c_type id.var_id fmt id.var_type

let pp_c_decl_array_mem self fmt id =
  Format.fprintf fmt "%a = (%a) (%s->_reg.%s)"
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

(* Access to the value of a variable:
   - if it's not a scalar output, then its name is enough
   - otherwise, dereference it (it has been declared as a pointer,
     despite its scalar Lustre type)
   - moreover, cast arrays variables into their original array type.
*)
let pp_c_var_read m fmt id =
  if Types.is_array_type id.var_type
  then
    Format.fprintf fmt "%s" id.var_id
  else
    if List.exists (fun o -> o.var_id = id.var_id) m.mstep.step_outputs (* id is output *)
    then Format.fprintf fmt "*%s" id.var_id
    else Format.fprintf fmt "%s" id.var_id

(* Addressable value of a variable, the one that is passed around in calls:
   - if it's not a scalar non-output, then its name is enough
   - otherwise, reference it (it must be passed as a pointer,
     despite its scalar Lustre type)
*)
let pp_c_var_write m fmt id =
  if Types.is_array_type id.var_type
  then
    Format.fprintf fmt "%s" id.var_id
  else
    if List.exists (fun o -> o.var_id = id.var_id) m.mstep.step_outputs (* id is output *)
    then
      Format.fprintf fmt "%s" id.var_id
    else
      Format.fprintf fmt "&%s" id.var_id

let pp_c_decl_instance_var fmt (name, (node, static)) = 
  Format.fprintf fmt "%a *%s" pp_machine_memtype_name (node_name node) name

let pp_c_tag fmt t =
 pp_print_string fmt (if t = tag_true then "1" else if t = tag_false then "0" else t)

(* Prints a constant value *)
let rec pp_c_const fmt c =
  match c with
    | Const_int i    -> pp_print_int fmt i
    | Const_real r   -> pp_print_string fmt r
    | Const_float r  -> pp_print_float fmt r
    | Const_tag t    -> pp_c_tag fmt t
    | Const_array ca -> Format.fprintf fmt "{%a}" (Utils.fprintf_list ~sep:"," pp_c_const) ca

(* Prints a value expression [v], with internal function calls only.
   [pp_var] is a printer for variables (typically [pp_c_var_read]),
   but an offset suffix may be added for array variables
*)
let rec pp_c_val self pp_var fmt v =
  match v with
    | Cst c         -> pp_c_const fmt c
    | Array vl      -> Format.fprintf fmt "{%a}" (Utils.fprintf_list ~sep:", " (pp_c_val self pp_var)) vl
    | Access (t, i) -> Format.fprintf fmt "%a[%a]" (pp_c_val self pp_var) t (pp_c_val self pp_var) i
    | Power (v, n)  -> assert false
    | LocalVar v    -> pp_var fmt v
    | StateVar v    ->
      if Types.is_array_type v.var_type
      then Format.fprintf fmt "*%a" pp_var v
      else Format.fprintf fmt "%s->_reg.%a" self pp_var v
    | Fun (n, vl)   -> Basic_library.pp_c n (pp_c_val self pp_var) fmt vl

let pp_c_checks self fmt m =
  Utils.fprintf_list ~sep:"" (fun fmt (loc, check) -> Format.fprintf fmt "@[<v>%a@,assert (%a);@]@," Location.pp_c_loc loc (pp_c_val self (pp_c_var_read m)) check) fmt m.mstep.step_checks


(********************************************************************************************)
(*                    Instruction Printing functions                                        *)
(********************************************************************************************)

(* Computes the depth to which multi-dimension array assignments should be expanded.
   It equals the maximum number of nested static array constructions accessible from root [v].
*)
let rec expansion_depth v =
 match v with
 | Cst (Const_array cl) -> 1 + List.fold_right (fun c -> max (expansion_depth (Cst c))) cl 0
 | Cst _
 | LocalVar _
 | StateVar _  -> 0
 | Fun (_, vl) -> List.fold_right (fun v -> max (expansion_depth v)) vl 0
 | Array vl    -> 1 + List.fold_right (fun v -> max (expansion_depth v)) vl 0
 | Access (v, i) -> max 0 (expansion_depth v - 1)
 | Power (v, n)  -> 0 (*1 + expansion_depth v*)

type loop_index = LVar of ident | LInt of int ref

(* Computes the list of nested loop variables together with their dimension bounds.
   - LInt r stands for loop expansion (no loop variable, but int loop index)
   - LVar v stands for loop variable v
*)
let rec mk_loop_variables m ty depth =
 match (Types.repr ty).Types.tdesc, depth with
 | Types.Tarray (d, ty'), 0       ->
   let v = mk_loop_var m () in
   (d, LVar v) :: mk_loop_variables m ty' 0
 | Types.Tarray (d, ty'), _       ->
   let r = ref (-1) in
   (d, LInt r) :: mk_loop_variables m ty' (depth - 1)
 | _                    , 0       -> []
 | _                              -> assert false

let reorder_loop_variables loop_vars =
  let (int_loops, var_loops) = List.partition (function (d, LInt _) -> true | _ -> false) loop_vars in
  var_loops @ int_loops

(* Prints a one loop variable suffix for arrays *)
let pp_loop_var fmt lv =
 match snd lv with
 | LVar v -> Format.fprintf fmt "[%s]" v
 | LInt r -> Format.fprintf fmt "[%d]" !r

(* Prints a suffix of loop variables for arrays *)
let pp_suffix fmt loop_vars =
 Utils.fprintf_list ~sep:"" pp_loop_var fmt loop_vars

(* Prints a [value] indexed by the suffix list [loop_vars] *)
let rec pp_value_suffix self loop_vars pp_value fmt value =
 match loop_vars, value with
 | (_, LInt r) :: q, Array vl     ->
   pp_value_suffix self q pp_value fmt (List.nth vl !r)
 | _           :: q, Power (v, n) ->
   pp_value_suffix self loop_vars pp_value fmt v
 | _               , Fun (n, vl)  ->
   Basic_library.pp_c n (pp_value_suffix self loop_vars pp_value) fmt vl
 | _               , _            ->
   let pp_var_suffix fmt v = Format.fprintf fmt "%a%a" pp_value v pp_suffix loop_vars in
   pp_c_val self pp_var_suffix fmt value

(* type_directed assignment: array vs. statically sized type
   - [var_type]: type of variable to be assigned
   - [var_name]: name of variable to be assigned
   - [value]: assigned value
   - [pp_var]: printer for variables
*)
let pp_assign m self pp_var fmt var_type var_name value =
  let depth = expansion_depth value in
(*Format.eprintf "pp_assign %a %a %d@." Types.print_ty var_type pp_val value depth;*)
  let loop_vars = mk_loop_variables m var_type depth in
  let reordered_loop_vars = reorder_loop_variables loop_vars in
  let rec aux fmt vars =
    match vars with
    | [] ->
      fprintf fmt "%a = %a;" (pp_value_suffix self loop_vars pp_var) var_name (pp_value_suffix self loop_vars pp_var) value
    | (d, LVar i) :: q ->
(*Format.eprintf "pp_aux %a %s@." Dimension.pp_dimension d i;*)
      Format.fprintf fmt "@[<v 2>{@,int %s;@,for(%s=0;%s<%a;%s++)@,%a @]@,}"
	i i i Dimension.pp_dimension d i
	aux q
    | (d, LInt r) :: q ->
(*Format.eprintf "pp_aux %a %d@." Dimension.pp_dimension d (!r);*)
      let szl = Utils.enumerate (Dimension.size_const_dimension d) in
      Format.fprintf fmt "@[<v 2>{@,%a@]@,}"
	(Utils.fprintf_list ~sep:"@," (fun fmt i -> r := i; aux fmt q)) szl
  in
  begin
    reset_loop_counter ();
    (*reset_addr_counter ();*)
    aux fmt reordered_loop_vars
  end

let pp_instance_call m self fmt i (inputs: value_t list) (outputs: var_decl list) =
 try (* stateful node instance *)
   let (n,_) = List.assoc i m.minstances in
   Format.fprintf fmt "%s_step (%a%t%a%t%s->%s);"
     (node_name n)
     (Utils.fprintf_list ~sep:", " (pp_c_val self (pp_c_var_read m))) inputs
     (Utils.pp_final_char_if_non_empty ", " inputs) 
     (Utils.fprintf_list ~sep:", " (pp_c_var_write m)) outputs
     (Utils.pp_final_char_if_non_empty ", " outputs)
     self
     i
 with Not_found -> (* stateless node instance *)
   let (n,_) = List.assoc i m.mcalls in
   Format.fprintf fmt "%s (%a%t%a);"
     (node_name n)
     (Utils.fprintf_list ~sep:", " (pp_c_val self (pp_c_var_read m))) inputs
     (Utils.pp_final_char_if_non_empty ", " inputs) 
     (Utils.fprintf_list ~sep:", " (pp_c_var_write m)) outputs 

let pp_machine_reset (m: machine_t) self fmt inst =
  let (node, static) = List.assoc inst m.minstances in
  fprintf fmt "%a(%a%t%s->%s);"
    pp_machine_reset_name (node_name node)
    (Utils.fprintf_list ~sep:", " Dimension.pp_dimension) static
    (Utils.pp_final_char_if_non_empty ", " static)
    self inst

let rec pp_conditional (m: machine_t) self fmt c tl el =
  fprintf fmt "@[<v 2>if (%a) {%t%a@]@,@[<v 2>} else {%t%a@]@,}"
    (pp_c_val self (pp_c_var_read m)) c
    (Utils.pp_newline_if_non_empty tl)
    (Utils.fprintf_list ~sep:"@," (pp_machine_instr m self)) tl
    (Utils.pp_newline_if_non_empty el)
    (Utils.fprintf_list ~sep:"@," (pp_machine_instr m self)) el

and pp_machine_instr (m: machine_t) self fmt instr =
  match instr with 
  | MReset i ->
    pp_machine_reset m self fmt i
  | MLocalAssign (i,v) ->
    pp_assign
      m self (pp_c_var_read m) fmt
      i.var_type (LocalVar i) v
  | MStateAssign (i,v) ->
    pp_assign
      m self (pp_c_var_read m) fmt
      i.var_type (StateVar i) v
  | MStep ([i0], i, vl) when Basic_library.is_internal_fun i  ->
    pp_machine_instr m self fmt (MLocalAssign (i0, Fun (i, vl)))
  | MStep (il, i, vl) ->
    pp_instance_call m self fmt i vl il
  | MBranch (g,hl) ->
    if hl <> [] && let t = fst (List.hd hl) in t = tag_true || t = tag_false
    then (* boolean case, needs special treatment in C because truth value is not unique *)
	 (* may disappear if we optimize code by replacing last branch test with default *)
      let tl = try List.assoc tag_true  hl with Not_found -> [] in
      let el = try List.assoc tag_false hl with Not_found -> [] in
      pp_conditional m self fmt g tl el
    else (* enum type case *)
      fprintf fmt "@[<v 2>switch(%a) {@,%a@,}@]"
	(pp_c_val self (pp_c_var_read m)) g
	(Utils.fprintf_list ~sep:"@," (pp_machine_branch m self)) hl

and pp_machine_branch m self fmt (t, h) =
  Format.fprintf fmt "@[<v 2>case %a:@,%a@,break;@]" pp_c_tag t (Utils.fprintf_list ~sep:"@," (pp_machine_instr m self)) h

(********************************************************************************************)
(*                      Prototype Printing functions                                        *)
(********************************************************************************************)

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

let print_stateless_prototype fmt (name, inputs, outputs) =
match outputs with
(* DOESN'T WORK FOR ARRAYS
  | [o] -> fprintf fmt "%a (@[<v>%a@])"
    (pp_c_type name) o.var_type
    (Utils.fprintf_list ~sep:",@ " pp_c_var) inputs
*)  
  | _ -> fprintf fmt "void %s (@[<v>@[%a%t@]@,@[%a@]@,@])"
    name
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

(********************************************************************************************)
(*                         Header Printing functions                                        *)
(********************************************************************************************)

let print_prototype fmt decl =
  match decl.top_decl_desc with
    | ImportedFun m -> (
        fprintf fmt "extern %a;@,"
	  print_stateless_prototype 
	  (m.fun_id, m.fun_inputs, m.fun_outputs)
    )
    | ImportedNode m -> (
      if m.nodei_stateless then (* It's a function not a node *)
        fprintf fmt "extern %a;@,"
	  print_stateless_prototype 
	  (m.nodei_id, m.nodei_inputs, m.nodei_outputs)
      else (
	let static = List.filter (fun v -> v.var_dec_const) m.nodei_inputs in
        fprintf fmt "extern %a;@,"
	  print_alloc_prototype (m.nodei_id, static);
	fprintf fmt "extern %a;@,"
	  (print_reset_prototype "self") (m.nodei_id, static);
	fprintf fmt "extern %a;@,"
	  (print_step_prototype "self") (m.nodei_id, m.nodei_inputs, m.nodei_outputs);
      )
    )
    | _ -> () (* We don't do anything here *)

let pp_registers_struct fmt m =
  if m.mmemory <> []
  then
    fprintf fmt "@[%a {@[%a; @]}@] _reg; "
      pp_machine_regtype_name m.mname.node_id
      (Utils.fprintf_list ~sep:"; " pp_c_decl_struct_var) m.mmemory
  else
    ()

let print_machine_struct fmt m =
  (* Define struct *)
  fprintf fmt "@[%a {@[%a%a%t@]};@]@."
    pp_machine_memtype_name m.mname.node_id
    pp_registers_struct m
    (Utils.fprintf_list ~sep:"; " pp_c_decl_instance_var) m.minstances
    (Utils.pp_final_char_if_non_empty "; " m.minstances) 
(*
let pp_static_array_instance fmt m (v, m) =
 fprintf fmt "%s" (mk_addr_var m v)
*)
let print_static_declare_instance fmt (i, (m, static)) =
  fprintf fmt "%a(%a%t%s)"
    pp_machine_static_declare_name (node_name m)
    (Utils.fprintf_list ~sep:", " Dimension.pp_dimension) static
    (Utils.pp_final_char_if_non_empty ", " static)
    i

let print_static_declare_macro fmt m =
  let array_mem = List.filter (fun v -> Types.is_array_type v.var_type) m.mmemory in
  fprintf fmt "@[<v 2>#define %a(%a%tinst)\\@,%a inst;\\@,%a%t%a;@,@]"
    pp_machine_static_declare_name m.mname.node_id
    (Utils.fprintf_list ~sep:", " (pp_c_var_read m)) m.mstatic
    (Utils.pp_final_char_if_non_empty ", " m.mstatic)
    pp_machine_memtype_name m.mname.node_id
    (Utils.fprintf_list ~sep:";\\@," pp_c_decl_local_var) array_mem
    (Utils.pp_final_char_if_non_empty ";\\@," array_mem)
    (Utils.fprintf_list ~sep:";\\@,"
       (fun fmt (i',m') ->
	 let path = sprintf "inst ## _%s" i' in
	 fprintf fmt "%a"
	   print_static_declare_instance (path,m')
       )) m.minstances

      
let print_static_link_instance fmt (i, (m, _)) =
 fprintf fmt "%a(%s)" pp_machine_static_link_name (node_name m) i

let print_static_link_macro fmt m =
  let array_mem = List.filter (fun v -> Types.is_array_type v.var_type) m.mmemory in
  fprintf fmt "@[<v>@[<v 2>#define %a(inst) do {\\@,%a%t%a;\\@]@,} while (0)@.@]"
    pp_machine_static_link_name m.mname.node_id
    (Utils.fprintf_list ~sep:";\\@,"
       (fun fmt v ->
	 fprintf fmt "inst.%s = &%s"
	   v.var_id
	   v.var_id
       )) array_mem
    (Utils.pp_final_char_if_non_empty ";\\@," array_mem)
    (Utils.fprintf_list ~sep:";\\@,"
       (fun fmt (i',m') ->
	 let path = sprintf "inst ## _%s" i' in
	 fprintf fmt "%a;\\@,inst.%s = &%s"
	   print_static_link_instance (path,m')
	   i'
	   path
       )) m.minstances
      
let print_static_alloc_macro fmt m =
  fprintf fmt "@[<v>@[<v 2>#define %a(%a%tinst)\\@,%a(%a%tinst);\\@,%a(inst);@]@,@]@."
    pp_machine_static_alloc_name m.mname.node_id
    (Utils.fprintf_list ~sep:", " (pp_c_var_read m)) m.mstatic
    (Utils.pp_final_char_if_non_empty ", " m.mstatic)
    pp_machine_static_declare_name m.mname.node_id
    (Utils.fprintf_list ~sep:", " (pp_c_var_read m)) m.mstatic
    (Utils.pp_final_char_if_non_empty ", " m.mstatic)
    pp_machine_static_link_name m.mname.node_id

let print_machine_decl fmt m =
  (* Static allocation *)
  if !Options.static_mem then (
  fprintf fmt "%a@.%a@.%a@."
    print_static_declare_macro m
    print_static_link_macro m
    print_static_alloc_macro m;
  )
  else ( 
    (* Dynamic allocation *)
    fprintf fmt "extern %a;@.@."
      print_alloc_prototype (m.mname.node_id, m.mstatic);
  );
  if m.mname.node_id = arrow_id then (
  (* Arrow will be defined by a #define macro because of polymorphism *)
    fprintf fmt "#define _arrow_step(x,y,output,self) ((self)->_reg._first?((self)->_reg._first=0,(*output = x)):(*output = y))@.@.";
    fprintf fmt "#define _arrow_reset(self) {(self)->_reg._first = 1;}@.@."
  )
  else (
    let self = mk_self m in
    fprintf fmt "extern %a;@.@."
      (print_reset_prototype self) (m.mname.node_id, m.mstatic);
    (* Print specification if any *)
    (match m.mspec with
      | None -> ()
      | Some spec -> 
	Printers.pp_acsl_spec m.mstep.step_outputs fmt spec
    );
    fprintf fmt "extern %a;@.@."
      (print_step_prototype self)
      (m.mname.node_id, m.mstep.step_inputs, m.mstep.step_outputs)
  )


(********************************************************************************************)
(*                         C file Printing functions                                        *)
(********************************************************************************************)

let print_const fmt cdecl =
  fprintf fmt "%a = %a;@." (pp_c_type cdecl.const_id) cdecl.const_type pp_c_const cdecl.const_value 

let print_alloc_instance fmt (i, (m, static)) =
  fprintf fmt "_alloc->%s = %a (%a);@,"
    i
    pp_machine_alloc_name (node_name m)
    (Utils.fprintf_list ~sep:", " Dimension.pp_dimension) static

let print_alloc_array fmt vdecl =
  let base_type = Types.array_base_type vdecl.var_type in
  let size_types = Types.array_type_multi_dimension vdecl.var_type in
  let size_type = Dimension.multi_dimension_product vdecl.var_loc size_types in
  fprintf fmt "_alloc->%s = (%a*) malloc((%a)*sizeof(%a));@,assert(_alloc->%s);@,"
    vdecl.var_id
    (pp_c_type "") base_type
    Dimension.pp_dimension size_type
    (pp_c_type "") base_type
    vdecl.var_id

let print_alloc_code fmt m =
  let array_mem = List.filter (fun v -> Types.is_array_type v.var_type) m.mmemory in
  fprintf fmt "%a *_alloc;@,_alloc = (%a *) malloc(sizeof(%a));@,assert(_alloc);@,%a%areturn _alloc;"
    pp_machine_memtype_name m.mname.node_id
    pp_machine_memtype_name m.mname.node_id
    pp_machine_memtype_name m.mname.node_id
    (Utils.fprintf_list ~sep:"" print_alloc_array) array_mem
    (Utils.fprintf_list ~sep:"" print_alloc_instance) m.minstances

let print_step_code fmt m self =
  if not (!Options.ansi && is_generic_node { top_decl_desc = Node m.mname; top_decl_loc = Location.dummy_loc })
  then
    (* C99 code *)
    let array_mems = List.filter (fun v -> Types.is_array_type v.var_type) m.mmemory in
    fprintf fmt "@[<v 2>%a {@,%a%t%a%t@,%a%a%t%t@]@,}@.@."
      (print_step_prototype self) (m.mname.node_id, m.mstep.step_inputs, m.mstep.step_outputs)
      (* locals *)
      (Utils.fprintf_list ~sep:";@," pp_c_decl_local_var) m.mstep.step_locals
      (Utils.pp_final_char_if_non_empty ";@," m.mstep.step_locals)
      (* array mems *)
      (Utils.fprintf_list ~sep:";@," (pp_c_decl_array_mem self)) array_mems
      (Utils.pp_final_char_if_non_empty ";@," array_mems)
      (* check assertions *)
      (pp_c_checks self) m
      (* instrs *)
      (Utils.fprintf_list ~sep:"@," (pp_machine_instr m self)) m.mstep.step_instrs
      (Utils.pp_newline_if_non_empty m.mstep.step_instrs)
      (fun fmt -> fprintf fmt "return;")
  else
    (* C90 code *)
    let (gen_locals, base_locals) = List.partition (fun v -> Types.is_generic_type v.var_type) m.mstep.step_locals in
    let gen_calls = List.map (fun e -> let (id, _, _) = call_of_expr e in mk_call_var_decl e.expr_loc id) m.mname.node_gencalls in
    fprintf fmt "@[<v 2>%a {@,%a%t@,%a%a%t%t@]@,}@.@."
      (print_step_prototype self) (m.mname.node_id, (m.mstep.step_inputs@gen_locals@gen_calls), m.mstep.step_outputs)
      (* locals *)
      (Utils.fprintf_list ~sep:";@," pp_c_decl_local_var) base_locals
      (Utils.pp_final_char_if_non_empty ";" base_locals)
      (* check assertions *)
      (pp_c_checks self) m
      (* instrs *)
      (Utils.fprintf_list ~sep:"@," (pp_machine_instr m self)) m.mstep.step_instrs
      (Utils.pp_newline_if_non_empty m.mstep.step_instrs)
      (fun fmt -> fprintf fmt "return;")

let print_machine fmt m =
  (* Alloc function, only if non static mode *)
  if (not !Options.static_mem) then  
    (
      fprintf fmt "@[<v 2>%a {@,%a@]@,}@.@."
	print_alloc_prototype (m.mname.node_id, m.mstatic)
	print_alloc_code m;
    );
  if m.mname.node_id = arrow_id then () else ( (* We don't print arrow function *)
    let self = mk_self m in
    (* Reset function *)
    fprintf fmt "@[<v 2>%a {@,%a%treturn;@]@,}@.@."
      (print_reset_prototype self) (m.mname.node_id, m.mstatic)
      (Utils.fprintf_list ~sep:"@," (pp_machine_instr m self)) m.minit
      (Utils.pp_newline_if_non_empty m.minit);
    (* Step function *)
    print_step_code fmt m self
  )

(********************************************************************************************)
(*                         Main related functions                                           *)
(********************************************************************************************)

let print_get_input fmt v =
  match v.var_type.Types.tdesc with
    | Types.Tint -> fprintf fmt "_get_int(\"%s\")" v.var_id
    | Types.Tbool -> fprintf fmt "_get_bool(\"%s\")" v.var_id
    | Types.Treal -> fprintf fmt "_get_double(\"%s\")" v.var_id
    | _ -> assert false

let print_put_outputs fmt ol = 
  let po fmt o =
    match o.var_type.Types.tdesc with
    | Types.Tint -> fprintf fmt "_put_int(\"%s\", %s)" o.var_id o.var_id
    | Types.Tbool -> fprintf fmt "_put_bool(\"%s\", %s)" o.var_id o.var_id
    | Types.Treal -> fprintf fmt "_put_double(\"%s\", %s)" o.var_id o.var_id
    | _ -> assert false
  in
  List.iter (fprintf fmt "@ %a;" po) ol

let print_main_fun machines m fmt =
  let mname = m.mname.node_id in
  let main_mem =
    if (!Options.static_mem && !Options.main_node <> "")
    then "&main_mem"
    else "main_mem" in
  fprintf fmt "@[<v 2>int main (int argc, char *argv[]) {@ ";
  fprintf fmt "/* Declaration of inputs/outputs variables */@ ";
  List.iter 
    (fun v -> fprintf fmt "%a = %a;@ " (pp_c_type v.var_id) v.var_type pp_c_initialize v.var_type
    ) m.mstep.step_inputs;
  List.iter 
    (fun v -> fprintf fmt "%a = %a;@ " (pp_c_type v.var_id) v.var_type pp_c_initialize v.var_type
    ) m.mstep.step_outputs;
  fprintf fmt "@ /* Main memory allocation */@ ";
  if (!Options.static_mem && !Options.main_node <> "")
  then (fprintf fmt "%a(main_mem);@ " pp_machine_static_alloc_name mname)
  else (fprintf fmt "%a *main_mem = %a();@ " pp_machine_memtype_name mname pp_machine_alloc_name mname);
  fprintf fmt "@ /* Initialize the main memory */@ ";
  fprintf fmt "%a(%s);@ " pp_machine_reset_name mname main_mem;
  fprintf fmt "@ ISATTY = isatty(0);@ ";
  fprintf fmt "@ /* Infinite loop */@ ";
  fprintf fmt "@[<v 2>while(1){@ ";
  fprintf fmt  "fflush(stdout);@ ";
  List.iter 
    (fun v -> fprintf fmt "%s = %a;@ "
      v.var_id
      print_get_input v
    ) m.mstep.step_inputs;
  (match m.mstep.step_outputs with
    (* | [] -> ( *)
    (*   fprintf fmt "%a(%a%t%s);@ "  *)
    (* 	pp_machine_step_name mname *)
    (* 	(Utils.fprintf_list ~sep:", " (fun fmt v -> pp_print_string fmt v.var_id)) m.mstep.step_inputs *)
    (* 	(pp_final_char_if_non_empty ", " m.mstep.step_inputs) *)
    (* 	main_mem *)
    (* ) *)
    (* | [o] -> ( *)
    (*   fprintf fmt "%s = %a(%a%t%a, %s);%a" *)
    (* 	o.var_id *)
    (* 	pp_machine_step_name mname *)
    (* 	(Utils.fprintf_list ~sep:", " (fun fmt v -> pp_print_string fmt v.var_id)) m.mstep.step_inputs *)
    (* 	(pp_final_char_if_non_empty ", " m.mstep.step_inputs) *)
    (* 	(Utils.fprintf_list ~sep:", " (fun fmt v -> fprintf fmt "&%s" v.var_id)) m.mstep.step_outputs *)
    (* 	main_mem *)
    (* 	print_put_outputs [o]) *)
    | _ -> (
      fprintf fmt "%a(%a%t%a, %s);%a"
	pp_machine_step_name mname
	(Utils.fprintf_list ~sep:", " (fun fmt v -> pp_print_string fmt v.var_id)) m.mstep.step_inputs
	(Utils.pp_final_char_if_non_empty ", " m.mstep.step_inputs)
	(Utils.fprintf_list ~sep:", " (fun fmt v -> fprintf fmt "&%s" v.var_id)) m.mstep.step_outputs
	main_mem
	print_put_outputs m.mstep.step_outputs)
  );
  fprintf fmt "@]@ }@ ";
  fprintf fmt "return 1;";
  fprintf fmt "@]@ }@."       

let print_main_header fmt =
  fprintf fmt "#include <stdio.h>@.#include <unistd.h>@.#include \"io_frontend.h\"@."

let rec pp_c_type_decl cpt var fmt tdecl =
  match tdecl with
  | Tydec_any           -> assert false
  | Tydec_int           -> fprintf fmt "int %s" var
  | Tydec_real          -> fprintf fmt "double %s" var
  | Tydec_float         -> fprintf fmt "float %s" var
  | Tydec_bool          -> fprintf fmt "_Bool %s" var
  | Tydec_clock ty      -> pp_c_type_decl cpt var fmt ty
  | Tydec_const c       -> fprintf fmt "%s %s" c var
  | Tydec_array (d, ty) -> fprintf fmt "%a[%a]" (pp_c_type_decl cpt var) ty pp_c_dimension d
  | Tydec_enum tl ->
    begin
      incr cpt;
      fprintf fmt "enum _enum_%d { %a } %s" !cpt (Utils.fprintf_list ~sep:", " pp_print_string) tl var
    end

let print_type_definitions fmt =
  let cpt_type = ref 0 in
  Hashtbl.iter (fun typ def ->
    match typ with
    | Tydec_const var ->
      fprintf fmt "typedef %a;@.@."
	(pp_c_type_decl cpt_type var) def
    | _        -> ()) type_table

(********************************************************************************************)
(*                         Translation function                                             *)
(********************************************************************************************)
    
let translate_to_c header_fmt source_fmt spec_fmt_opt basename prog machines =
  (* Generating H file *)

  (* Include once: start *)
  let baseNAME = String.uppercase basename in
  let baseNAME = Str.global_replace (Str.regexp "\\.\\|\\ ") "_" baseNAME in
  (* Print the svn version number and the supported C standard (C90 or C99) *)
  print_version header_fmt;
  fprintf header_fmt "#ifndef _%s@.#define _%s@." baseNAME baseNAME;
(*
  let machine_iter = compute_dep_machines machines in
*)
  (* Print the struct of all machines. This need to be done following the good
     order. *)
  fprintf header_fmt "/* Struct declarations */@.";
  List.iter (print_machine_struct header_fmt) machines;
  pp_print_newline header_fmt ();

  (* Print the prototypes of all machines *)
  fprintf header_fmt "/* Nodes declarations */@.";
  List.iter (print_machine_decl header_fmt) machines;
  pp_print_newline header_fmt ();
  (* Include once: end *)
  fprintf header_fmt "#endif@.";
  pp_print_newline header_fmt ();

  (* Generating C file *)
  
  (* If a main node is identified, generate a main function for it *)
  let main_include, main_print =
    match !Options.main_node with
      | "" -> (fun _ -> ()), (fun _ -> ())
      | main_node -> ( 
	let main_node_opt = 
	  List.fold_left 
	  (fun res m -> 
	    match res with 
	      | Some _ -> res 
	      | None -> if m.mname.node_id = main_node then Some m else None)
	  None machines
      in 
      match main_node_opt with
	| None -> eprintf "Unable to find a main node named %s@.@?" main_node; (fun _ -> ()), (fun _ -> ())
	| Some m -> print_main_header, print_main_fun machines m
    )
  in
  main_include source_fmt;
  fprintf source_fmt "#include <stdlib.h>@.#include <assert.h>@.#include \"%s\"@.@." (basename^".h");
  (* Print the svn version number and the supported C standard (C90 or C99) *)
  print_version source_fmt;
  (* Print the prototype of imported nodes *)
  fprintf source_fmt "/* Imported nodes declarations */@.";
  fprintf source_fmt "@[<v>";
  List.iter (print_prototype source_fmt) prog;
  fprintf source_fmt "@]@.";
  (* Print the type definitions from the type table *)
  print_type_definitions source_fmt;
  (* Print consts *)
  fprintf source_fmt "/* Global constants */@.";
  List.iter (fun c -> print_const source_fmt c) (get_consts prog); 
  pp_print_newline source_fmt ();
  (* Print nodes one by one (in the previous order) *)
  List.iter (print_machine source_fmt) machines;
  main_print source_fmt
  




(* Local Variables: *)
(* compile-command:"make -C .." *)
(* End: *)
