
module Ast = Tiny.Ast

let gen_loc () = Tiny.Location.dummy ()
               
let lloc_to_tloc loc = Tiny.Location.location_of_positions loc.Location.loc_start loc.Location.loc_end
                     
let tloc_to_lloc loc = assert false (*Location.dummy_loc (*TODO*) *)

                     
let ltyp_to_ttyp t =
  if Types.is_real_type t then Tiny.Ast.RealT
  else if Types.is_int_type t then Tiny.Ast.IntT
  else if Types.is_bool_type t then Tiny.Ast.BoolT
  else assert false (* not covered yet *)

let cst_bool loc b =
  { Ast.expr_desc =
      if b then
        Ast.Cst(Q.of_int 1, "true")
      else
        Ast.Cst(Q.of_int 0, "false");
    expr_loc = loc;
    expr_type = Ast.BoolT }

let cst_num loc t q =
{ Ast.expr_desc =
    Ast.Cst(q, Q.to_string q);
  expr_loc = loc;
  expr_type = t }
  
let rec real_to_q man exp =
  if exp = 0 then
        Q.of_string (Num.string_of_num man)
  else
    if exp > 0 then Q.div (real_to_q man (exp-1)) (Q.of_int 10)
    else (* if exp<0 then *)
      Q.mul
        (real_to_q man (exp+1))
        (Q.of_int 10)

let instr_loc i =
  match i.Machine_code_types.lustre_eq with
  | None -> gen_loc ()
  | Some eq -> lloc_to_tloc eq.eq_loc
             
let rec lval_to_texpr loc _val =
  let build d v =
      Ast.{ expr_desc = d;
            expr_loc = gen_loc ();
            expr_type = v }
  in
  let new_desc =
    match _val.Machine_code_types.value_desc with
  | Machine_code_types.Cst cst -> (
    match cst with
      Lustre_types.Const_int n -> Ast.Cst (Q.of_int n, string_of_int n)
    | Const_real r -> Ast.Cst (Real.to_q r, Real.to_string r) 
      | _ -> assert false
  )
     
  | Var v -> Ast.Var (v.var_id)
  | Fun (op, vl) ->
     let t_arg = match vl with
       | hd::_ -> ltyp_to_ttyp hd.value_type
       | _ -> assert false
     in
     (
       match op, List.map (lval_to_texpr loc) vl with
       | "+", [v1;v2] -> Ast.Binop (Ast.Plus, v1, v2)
       | "-", [v1;v2] -> Ast.Binop (Ast.Minus, v1, v2)
       | "*", [v1;v2] -> Ast.Binop (Ast.Times, v1, v2)
       | "/", [v1;v2] -> Ast.Binop (Ast.Div, v1, v2)
       | "<", [v1;v2] ->
          Ast.Cond (build (Ast.Binop (Ast.Minus, v2, v1)) t_arg, Ast.Strict)
       | "<=", [v1;v2] ->
          Ast.Cond (build(Ast.Binop (Ast.Minus, v2, v1)) t_arg, Ast.Loose)
       | ">", [v1;v2] ->
          Ast.Cond (build(Ast.Binop (Ast.Minus, v1, v2)) t_arg, Ast.Strict)
       | ">=", [v1;v2] ->
          Ast.Cond (build (Ast.Binop (Ast.Minus, v1, v2)) t_arg, Ast.Loose)
       | "=", [v1;v2] ->
          Ast.Cond (build (Ast.Binop (Ast.Minus, v2, v1)) t_arg, Ast.Zero)
       | "!=", [v1;v2] ->
          Ast.Cond (build (Ast.Binop (Ast.Minus, v2, v1)) t_arg, Ast.NonZero)
       | "uminus", [v1] -> Ast.Binop (Ast.Minus, cst_num loc t_arg Q.zero, v1)
       | _ -> Format.eprintf "No tiny translation for operator %s@.@?" op; assert false    
  )
  | _ -> assert false (* no array. access or power *)
  in
  build new_desc (ltyp_to_ttyp _val.value_type)

  
let machine_body_to_ast init m =
  let init_var = ref None in
  let rec guarded_expr_to_stm loc te guarded_instrs =
    match guarded_instrs with
    | [] -> assert false
    | [_,il] -> instrl_to_stm il
    | (label, il)::tl ->
       let stmt = instrl_to_stm il in
       let guard= match label with
           "true" -> te
         | "false" -> Ast.neg_guard te
         | _ -> assert false (* TODO: don't deal with non boolean
                                guards. Could just treturn true and
                                over-approximate behavior *)
       in
       if (match !init_var, te.Ast.expr_desc with
           | Some v, Var v2 -> v = v2
           | _ -> false) then 
         instrl_to_stm (
             if init then
               (List.assoc "true" guarded_instrs)
             else
               (List.assoc "false" guarded_instrs)
           )
       else
         Ast.Ite (loc, guard, stmt, guarded_expr_to_stm loc te tl)
  and instr_to_stm i =
    let loc = instr_loc i in
    match i.instr_desc with
    | MLocalAssign (v, e) | MStateAssign (v, e) ->
       Ast.Asn (loc, v.var_id, (lval_to_texpr loc) e)
    | MBranch (e, guarded_instrs) -> (
      let te = lval_to_texpr loc e in
      guarded_expr_to_stm loc te guarded_instrs
    )
    | MStep (ol, id, args) ->
       if List.mem_assoc id m.Machine_code_types.minstances then
         let fun_name, _ = List.assoc id m.minstances in
         match Corelang.node_name fun_name, ol with
         | "_arrow", [o] -> (
           init_var := Some o.var_id;
           Ast.Nop (loc);
             (* Ast.Asn (loc, o.var_id, 
              *        { expr_desc =              if init then Ast.Cst(Q.of_int 1, "true") else Ast.Cst(Q.of_int 0, "false");
              *          expr_loc = loc;
              *          expr_type = Ast.BoolT }
              * ) *)
         )
         | name, _ -> 
            (
              Format.eprintf "No tiny translation for node call  %s@.@?" name;
              assert false
            )
       else (
         Format.eprintf "No tiny translation for node call  %s@.@?" id;
         assert false
       )
    | MReset id
      | MNoReset id -> assert false (* no more calls or functions, ie. no reset *)
    | MComment s 
      | MSpec s -> assert false
  and instrl_to_stm il =
    match il with
      [] -> assert false
    | [i] -> instr_to_stm i
    | i::il ->
       let i' = instr_to_stm i in
       Ast.Seq (gen_loc (), i', (instrl_to_stm il))
  in
  instrl_to_stm m.Machine_code_types.mstep.step_instrs 

let read_var bounds_opt v =
  let min, max =
    match bounds_opt with
      Some (min,max) -> min, max
    | None -> (Q.of_int (-1), "-1"), (Q.of_int 1, "1")
  in
  let range = {
      Ast.expr_desc = Ast.Rand (min,max);
      expr_loc = gen_loc ();
      expr_type = ltyp_to_ttyp (v.Lustre_types.var_type)
    }
  in
  Ast.Asn (gen_loc (), v.var_id, range)
  
let rec read_vars bounds_inputs vl =
  match vl with
    [] -> Ast.Nop (gen_loc ())
  | [v] -> read_var
             (if List.mem_assoc v.Lustre_types.var_id bounds_inputs then
                Some (List.assoc v.Lustre_types.var_id bounds_inputs)
              else
                None)
             v
  | v::tl ->
     Ast.Seq (gen_loc (),
              read_var
                (if List.mem_assoc v.Lustre_types.var_id bounds_inputs then
                   Some (List.assoc v.Lustre_types.var_id bounds_inputs)
                 else
                   None)
                v,
              read_vars bounds_inputs tl
       )
  
let machine_to_ast bounds_input m =
  let read_vars = read_vars bounds_input m.Machine_code_types.mstep.step_inputs in
  let ast_loop_first = machine_body_to_ast true m in
  let ast_loop_run = machine_body_to_ast false m in
  let ast_loop_body = Ast.Seq (gen_loc (), read_vars, ast_loop_run) in
  let loop = Ast.While(gen_loc (), cst_bool (gen_loc ()) true, ast_loop_body) in
  Ast.Seq (gen_loc (), read_vars, (Ast.Seq (gen_loc (), ast_loop_first, loop)))
  
let machine_to_env m =
  
    List.fold_left (fun accu v ->
      let typ =
        ltyp_to_ttyp (v.Lustre_types.var_type)
      in
      Ast.VarSet.add (v.var_id, typ) accu)
    Ast.VarSet.empty
    (Machine_code_common.machine_vars m)

