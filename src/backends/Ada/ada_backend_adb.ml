(********************************************************************)
(*                                                                  *)
(*  The LustreC compiler toolset   /  The LustreC Development Team  *)
(*  Copyright 2012 -    --   ONERA - CNRS - INPT - ISAE-SUPAERO     *)
(*                                                                  *)
(*  LustreC is free software, distributed WITHOUT ANY WARRANTY      *)
(*  under the terms of the GNU Lesser General Public License        *)
(*  version 2.1.                                                    *)
(*                                                                  *)
(********************************************************************)

open Format

open Machine_code_types
open Lustre_types
open Corelang
open Machine_code_common
open Ada_backend_common

(** Main module for generating packages bodies
 **)
module Main =
struct

  (* Printing functions for basic operations *)

  (** Printing function for expressions [v1 modulo v2]. Depends
      on option [integer_div_euclidean] to choose between mathematical
      modulo or remainder ([rem] in Ada).

      @param pp_val pretty printer for values
      @param v1 the first value in the expression
      @param v2 the second value in the expression
      @param fmt the formater to print on
   **)
  let pp_mod pp_val v1 v2 fmt =
    if !Options.integer_div_euclidean then
      (* (a rem b) + (a rem b < 0 ? abs(b) : 0) *)
      Format.fprintf fmt
        "((%a rem %a) + (if (%a rem %a) < 0 then abs(%a) else 0))"
        pp_val v1 pp_val v2
        pp_val v1 pp_val v2
        pp_val v2
    else (* Ada behavior for rem *)
      Format.fprintf fmt "(%a rem %a)" pp_val v1 pp_val v2

  (** Printing function for expressions [v1 div v2]. Depends on
      option [integer_div_euclidean] to choose between mathematic
      division or Ada division.

      @param pp_val pretty printer for values
      @param v1 the first value in the expression
      @param v2 the second value in the expression
      @param fmt the formater to print in
   **)
  let pp_div pp_val v1 v2 fmt =
    if !Options.integer_div_euclidean then
      (* (a - ((a rem b) + (if a rem b < 0 then abs (b) else 0))) / b) *)
      Format.fprintf fmt "(%a - %t) / %a"
        pp_val v1
        (pp_mod pp_val v1 v2)
        pp_val v2
    else (* Ada behovior for / *)
      Format.fprintf fmt "(%a / %a)" pp_val v1 pp_val v2

  (** Printing function for basic lib functions.

      @param is_int boolean to choose between integer
                    division (resp. remainder) or Ada division
                    (resp. remainder)
      @param i a string representing the function
      @param pp_val the pretty printer for values
      @param fmt the formater to print on
      @param vl the list of operands
   **)
  let pp_basic_lib_fun is_int i pp_val fmt vl =
    match i, vl with
    | "uminus", [v] -> Format.fprintf fmt "(- %a)" pp_val v
    | "not", [v] -> Format.fprintf fmt "(not %a)" pp_val v
    | "impl", [v1; v2] -> Format.fprintf fmt "(not %a or else %a)" pp_val v1 pp_val v2
    | "=", [v1; v2] -> Format.fprintf fmt "(%a = %a)" pp_val v1 pp_val v2
    | "mod", [v1; v2] ->
      if is_int then
        pp_mod pp_val v1 v2 fmt
      else
        Format.fprintf fmt "(%a rem %a)" pp_val v1 pp_val v2
    | "equi", [v1; v2] -> Format.fprintf fmt "((not %a) = (not %a))" pp_val v1 pp_val v2
    | "xor", [v1; v2] -> Format.fprintf fmt "((not %a) \\= (not %a))" pp_val v1 pp_val v2
    | "/", [v1; v2] ->
      if is_int then
        pp_div pp_val v1 v2 fmt
      else
        Format.fprintf fmt "(%a / %a)" pp_val v1 pp_val v2
    | _, [v1; v2] -> Format.fprintf fmt "(%a %s %a)" pp_val v1 i pp_val v2
    | _ -> (Format.eprintf "internal compilation error: basic function %s@." i; assert false)

  (** Printing function for basic assignement [var_name := value;].

      @param pp_var pretty printer for variables
      @param fmt the formater to print on
      @param var_name the name of the variable
      @param value the value to be assigned
   **)
  let pp_basic_assign pp_var fmt var_name value =
    fprintf fmt "%a := %a;"
      pp_var var_name
      pp_var value

  (** Printing function for assignement. For the moment, only use
      [pp_basic_assign] function.

      @param pp_var pretty printer for variables
      @param fmt the formater to print on
      @param var_name the name of the variable
      @param value the value to be assigned
   **)
  let pp_assign pp_var fmt var_name value = pp_basic_assign

  (** Printing function for instruction. See
      {!type:Machine_code_types.instr_t} for more details on
      machine types.

      @param machine the current machine
      @param fmt the formater to print on
      @param instr the instruction to print
   **)
  let pp_machine_instr machine fmt instr =
    match get_instr_desc instr with
    (* no reset *)
    | MNoReset _ -> ()
    (* reset  *)
    | MReset i ->
      (* pp_machine_reset m self fmt i *)
      fprintf fmt "MReset %s@ " i
    | MLocalAssign (i,v) ->
      fprintf fmt "MLocalAssign";
      (* pp_assign
       *   machine self (pp_c_var_read m) fmt
       *   i.var_type (mk_val (Var i) i.var_type) v *)
    | MStateAssign (i,v) ->
      fprintf fmt "MStateAssign"
    (* pp_assign
       *   m self (pp_c_var_read m) fmt
       *   i.var_type (mk_val (Var i) i.var_type) v *)
    | MStep ([i0], i, vl) when Basic_library.is_value_internal_fun
          (mk_val (Fun (i, vl)) i0.var_type)  ->
      fprintf fmt "MStep basic"
    (* pp_machine_instr dependencies m self fmt
     *   (update_instr_desc instr (MLocalAssign (i0, mk_val (Fun (i, vl)) i0.var_type))) *)
    | MStep (il, i, vl) -> fprintf fmt "MStep"

    (* pp_basic_instance_call m self fmt i vl il *)
    | MBranch (_, []) -> fprintf fmt "MBranch []"

    (* (Format.eprintf "internal error: C_backend_src.pp_machine_instr %a@." (pp_instr m) instr; assert false) *)
    | MBranch (g, hl) -> fprintf fmt "MBranch gen"
    (* if let t = fst (List.hd hl) in t = tag_true || t = tag_false
     * then (\* boolean case, needs special treatment in C because truth value is not unique *\)
     *   (\* may disappear if we optimize code by replacing last branch test with default *\)
     *   let tl = try List.assoc tag_true  hl with Not_found -> [] in
     *   let el = try List.assoc tag_false hl with Not_found -> [] in
     *   pp_conditional dependencies m self fmt g tl el
     * else (\* enum type case *\)
     *   (\*let g_typ = Typing.type_const Location.dummy_loc (Const_tag (fst (List.hd hl))) in*\)
     *   fprintf fmt "@[<v 2>switch(%a) {@,%a@,}@]"
     *     (pp_c_val m self (pp_c_var_read m)) g
     *     (Utils.fprintf_list ~sep:"@," (pp_machine_branch dependencies m self)) hl *)
    | MComment s  ->
      fprintf fmt "-- %s@ " s
    | _ -> fprintf fmt "Don't  know"


(** Keep only the MReset from an instruction list.
  @param list to filter
**)
let filter_reset instr_list = List.map
    (fun i -> match get_instr_desc i with MReset i -> i | _ -> assert false)
  instr_list

(** Print the definition of the init procedure from a machine.
   @param fmt the formater to print on
   @param machine the machine
**)
let pp_init_definition fmt m = pp_procedure_definition
      pp_init_procedure_name
      (pp_init_prototype m)
      (pp_machine_var_decl NoMode)
      (pp_machine_instr m)
      fmt
      ([], m.minit)

(** Print the definition of the step procedure from a machine.
   @param fmt the formater to print on
   @param machine the machine
**)
let pp_step_definition fmt m = pp_procedure_definition
      pp_step_procedure_name
      (pp_step_prototype m)
      (pp_machine_var_decl NoMode)
      (pp_machine_instr m)
      fmt
      (m.mstep.step_locals, m.mstep.step_instrs)

(** Print the definition of the reset procedure from a machine.
   @param fmt the formater to print on
   @param machine the machine
**)
let pp_reset_definition fmt m = pp_procedure_definition
      pp_reset_procedure_name
      (pp_reset_prototype m)
      (pp_machine_var_decl NoMode)
      (pp_machine_instr m)
      fmt
      ([], m.minit)

(** Print the definition of the clear procedure from a machine.
   @param fmt the formater to print on
   @param machine the machine
**)
let pp_clear_definition fmt m = pp_procedure_definition
      pp_clear_procedure_name
      (pp_clear_prototype m)
      (pp_machine_var_decl NoMode)
      (pp_machine_instr m)
      fmt
      ([], m.minit)

(** Print the package definition(adb) of a machine.
   @param fmt the formater to print on
   @param machine the machine
**)
let pp_file fmt machine =
  fprintf fmt "%a@,  @[<v>@,%a;@,@,%a;@,@,%a;@,@,%a;@,@]@,%a;@."
    (pp_begin_package true) machine (*Begin the package*)
    pp_init_definition machine (*Define the init procedure*)
    pp_step_definition machine (*Define the step procedure*)
    pp_reset_definition machine (*Define the reset procedure*)
    pp_clear_definition machine (*Define the clear procedure*)
    pp_end_package machine  (*End the package*)

end

(* Local Variables: *)
(* compile-command: "make -C ../../.." *)
(* End: *)
