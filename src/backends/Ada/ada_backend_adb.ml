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

  (** Printing function for basic assignement [var_name := value;].

      @param fmt the formater to print on
      @param var_name the name of the variable
      @param value the value to be assigned
   **)
  let pp_basic_assign m fmt var_name value =
    fprintf fmt "%a := %a"
      (pp_access_var m) var_name
      (pp_value m) value

  (** Printing function for assignement. For the moment, only use
      [pp_basic_assign] function.

      @param pp_var pretty printer for variables
      @param fmt the formater to print on
      @param var_name the name of the variable
      @param value the value to be assigned
   **)
  let pp_assign m pp_var fmt var_name value = pp_basic_assign m

  (* Printing function for reset function *)
  (* TODO: clean the call to extract_node *)
  (** Printing function for reset function name.

      @param machines list of all machines
      @param machine the current machine
      @param fmt the formater to use
      @param encapsulated_node the node encapsulated in a pair
             [(instance, (node, static))]
   **)
  let pp_machine_reset_name machines m fmt encapsulated_node =
    let submachine = get_machine machines encapsulated_node in
    let substitution = get_substitution m (fst encapsulated_node) submachine in
    fprintf fmt "%a.reset" (pp_package_name_with_polymorphic substitution) submachine

  (** Printing function for reset function.

      @param machines list of all machines
      @param machine the current machine
      @param fmt the formater to use
      @param instance the considered instance
   **)
  let pp_machine_reset machines (machine: machine_t) fmt instance =
    let node =
      try
        List.assoc instance machine.minstances
      with Not_found -> (Format.eprintf "internal error: pp_machine_reset %s %s:@." machine.mname.node_id instance; raise Not_found) in
    fprintf fmt "%a(%t.%s)"
      (pp_machine_reset_name machines machine) (instance, node)
      pp_state_name
      instance

  (** Printing function for instruction. See
      {!type:Machine_code_types.instr_t} for more details on
      machine types.

      @param machines list of all machines
      @param machine the current machine
      @param fmt the formater to print on
      @param instr the instruction to print
   **)
  let pp_machine_instr machines machine fmt instr =
    match get_instr_desc instr with
    (* no reset *)
    | MNoReset _ -> ()
    (* reset  *)
    | MReset ident ->
      pp_machine_reset machines machine fmt ident
    | MLocalAssign (ident, value) ->
      pp_basic_assign machine fmt ident value
    | MStateAssign (ident, value) ->
      pp_basic_assign machine fmt ident value
    | MStep ([i0], i, vl) when Basic_library.is_value_internal_fun
          (mk_val (Fun (i, vl)) i0.var_type)  ->
      fprintf fmt "Null"
    (* pp_machine_instr dependencies m self fmt
     *   (update_instr_desc instr (MLocalAssign (i0, mk_val (Fun (i, vl)) i0.var_type))) *)
    | MStep (il, i, vl) -> fprintf fmt "Null"

    (* pp_basic_instance_call m self fmt i vl il *)
    | MBranch (_, []) -> fprintf fmt "Null"

    (* (Format.eprintf "internal error: C_backend_src.pp_machine_instr %a@." (pp_instr m) instr; assert false) *)
    | MBranch (g, hl) -> fprintf fmt "Null"
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

(** Print the definition of the step procedure from a machine.

   @param machines list of all machines
   @param fmt the formater to print on
   @param machine the machine
**)
let pp_step_definition machines fmt m = pp_procedure_definition
      pp_step_procedure_name
      (pp_step_prototype m)
      (pp_machine_var_decl NoMode)
      (pp_machine_instr machines m)
      fmt
      (m.mstep.step_locals, m.mstep.step_instrs)

(** Print the definition of the reset procedure from a machine.

   @param machines list of all machines
   @param fmt the formater to print on
   @param machine the machine
**)
let pp_reset_definition machines fmt m = pp_procedure_definition
      pp_reset_procedure_name
      (pp_reset_prototype m)
      (pp_machine_var_decl NoMode)
      (pp_machine_instr machines m)
      fmt
      ([], m.minit)

(** Print the package definition(adb) of a machine.

   @param machines list of all machines
   @param fmt the formater to print on
   @param machine the machine
**)
let pp_file machines fmt machine =
  fprintf fmt "%a@,  @[<v>@,%a;@,@,%a;@,@]@,%a;@."
    (pp_begin_package true) machine (*Begin the package*)
    (pp_reset_definition machines) machine (*Define the reset procedure*)
    (pp_step_definition machines) machine (*Define the step procedure*)
    pp_end_package machine  (*End the package*)

end

(* Local Variables: *)
(* compile-command: "make -C ../../.." *)
(* End: *)
